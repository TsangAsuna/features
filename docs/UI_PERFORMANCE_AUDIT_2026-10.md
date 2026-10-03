# UI 前端性能全量审计与优化（2026-10）

> 目标：UI 达到足够原生的流畅度，满足鸿蒙（HarmonyOS/OpenHarmony）平台审核的性能与稳定性要求为小目标；
> 同时重点优化遥控端快速按键选择时的平滑过渡动画。
> 审计方式：静态全量排查（three-pass：焦点导航链路 / 反模式扫描 / 平台现状），配合 `tools/perf/` 采集体系。

---

## 1. 鸿蒙审核性能要求 → 本项目的映射

鸿蒙应用审核关注启动时延、页面响应时延、滑动/渲染流畅度（掉帧）、稳定性（无崩溃/ANR）、内存与功耗。
对照本项目现状：

| 审核维度 | 现状 | 结论 |
| --- | --- | --- |
| 渲染流畅度 | ohos 走 OpenHarmony fork（Flutter 3.35.8-ohos），**Impeller 已开启**（`ohos/entry/src/main/resources/rawfile/buildinfo.json5`）；弹幕 Next++ 管线按 Impeller 做了规避 | 基础路径良好；剩余风险是逐帧 blur 与 rebuild 风暴（见 §2） |
| 响应时延 | 遥控焦点链路无节流，按住方向键每秒约 30 次全链路移动 | 本次已修（§3.1） |
| 稳定性 | `webdav_browser_page.dart` 26 处 setState 仅 4 处 `!mounted` 守卫（慢 NAS 链路下有崩云风险） | 待办（§4） |
| 启动时延 | `fa775d98` 已做过启动路径优化 | 已达标，无需再动 |
| 内存 | tools/perf 已有基线流程与门槛（WS ≤1.5GB、无 >100MB/60s 增长） | 已达标；图片缓存本次按平台分档（§3.3） |

ohos 平台定位注意：`module.json5` 声明 `deviceTypes: [phone, tablet]`，`globals.isTelevision` 不含 ohos——
ohos 上大屏模式是**手动开关**（`_useLargeScreenLayout`，默认 `globals.isTelevision`=false）。仓库目前没有
ohos 专项性能门槛文档，本文件补充第 5 节的验收方式。

## 2. 全量排查结论（按影响排序）

前一轮优化已经消掉大部分常见问题（网格全部 builder 化、海报解码宽度有上限、TV 弹幕阴影关闭、
播放位置走 ValueNotifier 不触发 ChangeNotifier）。以下是存活的热点：

1. **ohos/TV 模糊防护缺口（最大 GPU 风险）**：仓库已有 `TvSafeBackdropFilter`（TV 上跳过 blur），
   但全仓 81 处 blur 大多裸用 `BackdropFilter`：设置卡片 σ25、箭头菜单、BlurButton/BlurSnackbar σ16、
   主页 hero 两处 σ25、播放页大屏顶栏/控制条 σ24（在视频上方，逐帧重捕获无法缓存）、
   全窗口 `GlassmorphicContainer` 底层。TV/低端 GPU 上这些是纯填充率开销，直接决定滑动流畅度评分。
2. **遥控焦点链路无节流**：`NipaplayLargeScreenInputControls.fromKeyEvent` 接受 `KeyRepeatEvent`，
   方向键按住时每次重复都执行 `focusInDirection` + post-frame `Scrollable.ensureVisible`（140–160ms 动画
   被逐事件重置）+ `playFocusChange()` 音效；侧栏焦点索引走 scaffold 级 `setState`（连带重建整棵 Stack，
   面板重建 ×2）；设置面板更叠加"逐键重建整个设置内容页"（entries 每次 build 重新构造，KeyedSubtree
   的 child 实例恒为新）。
3. **播放页巨型 Consumer**：`play_video_page.dart:505` 与 `video_player_ui.dart:1132` 的
   `Consumer<VideoPlayerState>` 包住整个播放舞台；`VideoPlayerState` 播放中按 120ms 节流通知 → 全舞台
   子树每秒 diff 约 8.3 次。位置文本已走 `playbackTimeMs` ValueListenable（好），但布局级字段未拆 Selector。
4. **弹幕 overlay 外层 Consumer**：`danmaku_overlay.dart:45` 的 Consumer 在每次 notify 时重建内核
   widget 链（configure 有 identity 守卫，实际开销中等）。Next++ atlas 绘制路径本身健康
   （sprite blit、LRU 缓存、opacity 1.0 时跳过 saveLayer）。
5. **图片缓存全局 32MB**：桌面/ohos 长滚动海报墙会反复重解码。
6. **遗留 rebuild 热点**：`library_management_tab.dart`（6,562 行）隐式 listen 四个 provider，其中
   WatchHistoryProvider 播放中每 3 秒通知 → 播放时整 tab 重建；`anime_detail_page.dart` hover setState
   全页重建；大屏详情页剧集网格逐键 setState（1,321 行整页）；`dashboard_home_page.dart` 的
   `Consumer2<Jellyfin, Emby>` 包住整个滚动视图；弹幕/字幕列表菜单 500ms Timer 全量 setState。

## 3. 本次已实施

### 3.1 遥控端快速按键的平滑过渡（核心需求）
- 新增 `lib/themes/nipaplay/widgets/large_screen_key_repeat_coalescer.dart`：
  把系统级 KeyRepeat（约 30Hz）合并为 **60ms 固定节拍**——首次立即移动，节拍间隙内的重复只保留
  最新方向，到期执行尾随移动；`cancel()` 在松键/新 KeyDown 时丢弃尾随，避免"松手多走一步"。
- 接入四个入口（KeyDown 即时、KeyRepeat 节拍、KeyUp 取消）：
  - `large_screen_scaffold_layout.dart`（内容区 + 左侧 tab 菜单 + 设置面板命令）；
  - `directional_focus_scope.dart`（主页/内容页，SingleActivator 改 `includeRepeats: false`，
    KeyRepeat 由外层 Focus 处理并消费，不回落到 scaffold 造成双移动）；
  - `large_screen_player_menu_panel.dart`（标签列/内容区）；
  - `large_screen_anime_detail_page.dart`（剧集网格，early key handler）。
- 瞬时命令（开/关菜单、返回、确认）只响应 KeyDown，重复事件直接消费——按住 Esc 不再闪烁菜单、
  按住确认不会重复激活。
- 播放器快捷键路径保持原速：控制栏隐藏时左右=逐级 seek、上下=音量，这些是有意的连续动作，不节流。
- 侧栏焦点索引 `ValueNotifier` 化：scaffold 不再因方向键 setState；tab 面板与设置面板通过
  `focusedIndexListenable` + `ValueListenableBuilder` 局部重建高亮。
- 设置面板 entries 移到 `didChangeDependencies`/`didUpdateWidget` 构造：菜单移动时 KeyedSubtree
  的 child 实例不变，**设置内容页不再逐键重建**（换页仅在真正切换选中项时发生）。
- 列表边界回弹从瞬时 `jumpTo` 改为 180ms `easeOutCubic`（scaffold / 设置面板 / 内容页三处一致）。
- 效果：按住方向键时焦点高亮（120–180ms 动画）与滚动动画能完整推进，每步 rebuild 范围从
  "scaffold+面板×2+设置整页"缩小到"面板菜单区"，音效节奏稳定不爆破。

### 3.2 TV 安全模糊通道全覆盖（TV/低端 GPU 帧成本）
以下裸 `BackdropFilter` 全部接入 `TvSafeBackdropFilter`（桌面行为不变，TV 上自动降级为半透明色块）：
`settings_card.dart`（σ25）、`arrow_menu_container.dart`、`blur_button.dart`、`blur_snackbar.dart`（σ16）、
`play_video_page.dart` 大屏顶栏+控制条（σ24，视频上方逐帧模糊）、`dashboard_home_page_build_hero.dart`
两处（σ25）。`background_with_blur.dart` 的全窗口 `GlassmorphicContainer`（渐变全透明、只贡献 blur）
在 TV 上直接替换为空壳。

### 3.3 图片缓存分档（`main.dart`）
Android/Web/TV 维持 32MB/200（对齐 `docs/LOW_END_DEVICE_PERFORMANCE.md` 预算），
桌面/ohos 提到 64MB/400，长滚动海报墙减少重解码抖动。

### 3.4 验证
- `flutter analyze`（改动文件）：0 error（存量 info/warning 未引入新增）。
- 测试：`large_screen_*` 全套 + `android_tv_remote_key_scope` + `tvos_large_screen_adaptation_policy`
  + `nipaplay_main_tab_bar_material` + 新增 `test/large_screen_key_repeat_coalescer_test.dart`
  （41 例全过）。
- `android_tv_platform_policy_test` / `television_media_library_test` 各有 1 例失败，**已用 stash 验证
  在 HEAD 上同样失败，属存量问题**（前者断言 player_factory 源码含固定字符串，后者为分区排序恢复），
  与本次改动无关。

### 3.5 第二轮：rebuild 风暴收尾与重新评估（2026-10-03 下午）

已实施：
- **library_management_tab**（播放期间每 3 秒整 tab 重建的主因）：
  WatchHistoryProvider 读取改 `listen:false`（只用于条目副标题的进度文本；退出播放时祖先响应
  hasVideo 变化会带动本页重建）；外观 provider 改 `context.select` 只订阅 `enableWidgetBlurEffect`。
  ScanService/SharedRemoteLibraryProvider 保留监听（驱动扫描进度与连接列表显示）。
- **subtitle_list_menu**：内嵌字幕分支每 500ms 无条件 setState（即使台词未变）→ 台词不变时直接返回。
  其余三个列表菜单（danmaku_list_menu、cupertino 两 pane）核查后确认已有 diff 守卫，无需改动。
- **torrent_download_page**：5 秒静默刷新加 `_tasksEquivalent` 逐字段 diff（进度/速度/状态/文件开关），
  任务无变化时跳过 setState 与摘要批量加载（顺带消掉批量加载器每 5 秒的无条件 setState）；
  自动扫描检查保留（内部按任务键去重）。
- **anime_detail_page**：剧集 tile/观看按钮两个 hover 状态从整页 setState 改为 `ValueNotifier` +
  局部 `ValueListenableBuilder`——桌面端鼠标扫过剧集列表从"每次进出重建 4,200 行页面"变为
  "每次 hover 重建一个 Text / 一个按钮"。
- **webdav_browser_page**：添加服务器流程 post-await setState 补 `!mounted` 守卫（其余 setState
  逐一核查后确认在同步回调内，安全）。

重新评估后**不改**的两项（修正第一轮报告的预估）：
- **播放页/播放器 UI 的巨型 Consumer**（8.3Hz 整舞台 diff）：核实后成本低于预估——弹幕链路的
  `DanmakuAtlasPainter.shouldRepaint` 按配置字段比较而非实例身份，120ms 重建不会触发弹幕层重绘；
  弹幕 overlay 是 `ValueListenableBuilder` 的缓存 child 不随通知重建；进度条直接读
  `videoState.position`，说明节流心跳是承载性的（不能降频）。手工拆分需枚举数十个被读字段，
  漏一个就是静默 UI 过期，回归风险大于每秒 ~8 次轻量 diff 的收益。保留现状，留待引入
  widget rebuild 计数工具（如 rebuild_stats）后用数据决策。
- **danmaku_overlay 外层 Consumer / dashboard Consumer2**：danmaku 内核 widget 每 120ms 重建
  只是 ~20 个参数的对象创建 + State.didUpdateWidget no-op（painter 守卫如上）；
  Jellyfin/Emby provider 全仓仅 3 处 notifyListeners，非高频。两者收窄的收益不可测，staleness
  风险实在，均保留。

## 4. 后续路线图（按收益/风险排序，含落点）

1. ~~播放页 Consumer 拆分~~ → 已重新评估，结论见 §3.5（painter 守卫 + 缓存 child 使实际成本
   低于预估；拆分风险大于收益）。
2. ~~library_management_tab provider 读取 listen:false 化~~ → 已完成（§3.5）。
3. **大屏详情页网格选中状态下沉**：`_selectedEpisodeIndex`（`large_screen_anime_detail_page.dart`）
   改 ValueNotifier + 逐卡 ValueListenableBuilder，消除逐键整页 setState（已节流，未下沉）。
4. ~~dashboard `Consumer2` 收窄~~ → 已重新评估保留（§3.5）；~~hover 状态局部化~~ → 已完成（§3.5）。
5. ~~弹幕/字幕列表菜单的 500ms Timer~~ → 核查完成：仅 subtitle_list_menu 一处无守卫，已修（§3.5）。
6. ~~webdav_browser_page 补 `!mounted` 守卫~~ → 核查完成：仅 1 处 post-await 风险，已修（§3.5）。
7. **ohos 定向**：发布 HAP 前用真机跑一轮 `tools/perf` 等价物（ohos 无 Get-Counter，需 hdc + profiler
   替代）；如审核滑动项不过，评估给 ohos 增加"模糊强度上限"设置（而非一刀切跳过）。
8. 存量测试修复：`android_tv_platform_policy_test` 的源码断言已过时，应改断言新事实。
9. 引入 rebuild 计数手段（widget rebuild stats 或 profile 内埋点）后，用数据复核播放页
   Consumer 的真实 diff 成本再决定是否拆分。

## 5. 交付前验收方式（对齐 tools/perf 流程）

Windows 基线沿用 `tools/perf/README.md` 门槛（hwdec 生效、CPU 1080p60 均值 ≤15%、0 掉帧、
RSS 无增长）。遥控专项验收：按住方向键横穿主页海报墙与设置菜单，观察高亮/滚动是否连续推进、
松手是否立即停住；长按 Esc 菜单只开合一次。
