# 交付前性能评估（Performance Eye）

这是**开发流程**，不是用户功能：每次发布候选构建（RC / feature 分支收尾）之前，
用这套工具在真实播放中采集播放信息、内存、硬件解码与硬件开销，判断是否达到交付
标准。全部工具为开发机专用，不进入 release 产物（应用内的记录器仅在 profile/debug
构建且设置了环境变量时激活）。

## 组成

| 文件 | 作用 |
| --- | --- |
| `lib/dev/perf_stats_logger.dart` | 应用内记录器（内核侧）。`NIPAPLAY_PERF_LOG=<jsonl>` 时每秒写一条：内核名、hwdec、掉帧、fps、码率、缓冲、进程 RSS。 |
| `run_eval.ps1` | 编排一次评估：启动 app（带 fixture）→ 外部采样 → 关闭 → 写 run 元数据。 |
| `capture_perf.ps1` | 外部采样器（系统侧）。每秒对 nipaplay 进程采 CPU、工作集、私有内存、GPU 各引擎利用率、GPU 专用/共享显存（走 `Get-Counter` 的 `\GPU Engine`/`\GPU Process Memory`；本机 WMI formatted 类 cooked 值恒为 0，不可用）。 |
| `analyze_perf.py` | 合并两条 JSONL 流，输出均值/p95/峰值摘要 + `summary.json`。 |
| `make_fixtures.ps1` | 生成确定性测试视频（testsrc2，H.264 High，1080p60 与 4K30）。 |
| `fixtures/` | 测试视频（约 230MB，**不要提交到 git**）。 |

## 交付前标准流程

1. 构建候选版本：
   ```
   flutter build windows --profile
   ```
2. 逐个内核跑基线（可选 `-Kernel`，见下；不传则用用户当前设置）：
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File tools/perf/run_eval.ps1 -Kernel mdk -Seconds 60
   powershell -NoProfile -ExecutionPolicy Bypass -File tools/perf/run_eval.ps1 -Kernel mediaKit -Seconds 60
   ```
   脚本会启动 app 播放 fixture、采样 60 秒、自动关闭，输出到
   `tools/perf/out/<时间戳>-<内核>/`。
3. 换重负载 fixture 再跑一轮（检验 4K 与高码率开销）：
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File tools/perf/run_eval.ps1 -Fixture <repo>\tools\perf\fixtures\sample_4k30_h264.mp4 -Kernel mdk -Seconds 60
   ```
4. 出摘要并对比：
   ```
   python tools/perf/analyze_perf.py tools/perf/out/<run目录>
   ```

## 首次基线（2026-10-02，本机 GTX 1060 3GB / Win10 19045，1080p60 H.264 fixture，45s 采样）

| 指标 | mediaKit（d3d11va-copy 硬解） | MDK（本机为软解） |
| --- | --- | --- |
| CPU 均值 / p95 | 19.7% / — | 16.6% / — |
| GPU VideoDecode | 9.7% | **0%** |
| 专用显存峰值 | 516 MB | 325 MB |
| 工作集均值 / 峰值 | 502 / 522 MB | 435 / 447 MB |

（10min fixture、归零 seek、全程播放的干净数据；MDK 软解下 CPU 反而与
mediaKit 硬解相近，因为 d3d11va-copy 的拷贝开销抵消了硬解收益。）

## 内存评估结论（2026-10-02 优化会话）

1. **渲染路径双态是最大变量**：同一二进制、同一场景，不同启动之间工作集
   在 ~430MB（shared 显存 20-27MB）与 ~1.1-1.2GB（shared 显存 620-708MB）
   之间摆动。共享显存由系统 RAM 支撑、直接计入 WS。本机有多块虚拟显示
   适配器（Sunshine/Oray/MuMu），疑似 mpv D3D11 设备与 Flutter(ANGLE)
   落在不同适配器时走跨适配器共享内存。**后续优化方向：渲染端 LUID/适配
   器匹配**。单次 A/B 结论必须先看 `gpuShared` 是否同态。
2. **MDK 硬解全线失效**（fvp 0.33.1 捆绑的 mdk-sdk）：MFT:d3d=11 / D3D11 /
   DXVA 显式指定均静默回退 FFmpeg（`decoder.video` 属性证实），VideoDecode
   引擎 0%。修复需查 fvp/mdk-sdk 侧（解码器注册或 D3D11 互操作），适配器
   配置层无解。
3. **开关弹幕内存几乎不变是正常的**：10k 条弹幕的数据量 ~15-20MB（轨道源
   数据 + 显示层拷贝），释放后淹没在 WS 噪声（±30MB）里。组内实测关闭后
   Δ−5MB（mediaKit）/ +1MB（MDK），对照漂移 ±12MB。真正会累积的是跨集
   缓存（已修，见下），单次开关本来就没有大块内存。
4. **已修复的驻留点**（本次优化代码）：
   - `DanmakuCacheManager` 内存缓存层移除（原 `_rememberInMemoryCache`
     自递归 bug 使其从未生效；磁盘缓存是唯一层，重读 <50ms）。
   - 关弹幕即释放显示层 + controller 数据；Erika 内核同步
     `clearNativeDanmaku()` 释放原生 JSON 缓冲。重开从轨道源数据重建，
     无需网络/磁盘重读（`_updateMergedDanmakuList` 隐藏态守卫）。
   - `DanmakuContainer` 补 dispose：GPU 渲染器独占的 2048px 字体图集
     （ui.Image）此前从不释放，随 overlay 重建累积；含 create/dispose
     异步竞态修复。
   - `SubtitleManager`：移除/清空外挂字幕即逐出解析缓存（此前永不淘汰，
     剧场版字幕解析后 0.5-2MB/份），并加 8 份 LRU 上限。
5. **播完不释放**：播放到片尾后 WS 停在高位不回落（短 fixture 实验观察）。
   长视频看完整部后的内存水位与播放中一致，属待优化项。

## 已知发现（首次交付评估）

MDK（fvp）内核在本机 Windows 上 1080p60 H.264 走软解（VideoDecode 引擎
0%）；MDK 的 `getDetailedMediaInfo` 不暴露 mpv 式属性，`hwdec` 一栏对 MDK
判空，判定以 GPU `VideoDecode` 引擎利用率为准。

## 交付门槛（本机基线 GTX 1060 3GB / Win10，按此解释数据）

- **硬件解码生效**：mediaKit 看 `hwdec` 的 `observed_values` 必须是
  `d3d11va*`/`dxva2*`/`nvdec` 之类且无 `no`/`auto` 样本；任何内核都可用
  GPU `VideoDecode` 引擎利用率作统一判据（1080p60 硬解应 > 0，软解 ≈ 0）。
- **CPU**：1080p60 硬解播放进程整体均值 ≤ 15%，p95 ≤ 30%（软解不设门槛，
  但要记录，防止内核默默回退——首次评估即发现 MDK 软解，见上表）。
- **内存**：工作集峰值 ≤ 1.5 GB（含解码器/着色器）；记录器可见 RSS 无持续
  增长趋势（采样 60s 内增量 > 100 MB 视为可疑，需延长采样复查）。
- **GPU 开销**：`VideoDecode` + `3D` p95 合计 ≤ 60%（danmaku/字幕渲染落在 3D
  引擎）；专用显存峰值 ≤ 800 MB（3GB 卡要给系统留余量）。
- **流畅度**：`rendered fps`（estimated-vf-fps）≈ `container fps`（±5%），
  `dropped frames` = 0，`paused-for-cache` = 0（本地播放）。

任一条不满足即不交付：先查内核回退（decoder_manager 日志），再查新引入的
每帧分配/拷贝（对照上次 `summary.json` 基线 diff）。

## 评估专用环境变量（仅非 release 生效）

- `NIPAPLAY_PERF_LOG=<jsonl 路径>`：开启应用内记录。
- `NIPAPLAY_FORCE_KERNEL=mdk|mediaKit|videoPlayer|erika`：本次运行固定内核，
  覆盖用户设置，保证跨运行可比。（`PlayerFactory.initialize` 读取。）
- `NIPAPLAY_AUTOPLAY_FILE=<视频路径>`：既有启动参数，`run_eval.ps1` 用命令行
  参数代替。
- 场景钩子（`lib/dev/eval_scenarios.dart`，`run_eval.ps1` 对应参数自动传入）：
  - `NIPAPLAY_EVAL_SEEK_ZERO=1`：覆盖自动续播，归零后播放（A/B 可比的前提；
    run_eval.ps1 默认开启）。
  - `NIPAPLAY_EVAL_SUBTITLE=<路径>`：播放开始后自动挂载外挂字幕。
  - `NIPAPLAY_EVAL_SYNTH_DANMAKU=<条数>`：注入合成弹幕（铺满时间轴，贴近真实负载）。
  - `NIPAPLAY_EVAL_DANMAKU_OFF_AT=<秒>` / `ON_AT=<秒>`：模拟用户开关弹幕。
  - `NIPAPLAY_EVAL_DECODERS=D3D11,FFmpeg,...`：覆写解码器顺序（定位内核静默回退）。

## 测量注意事项（踩过的坑）

- **自动续播会毁掉 A/B**：app 会从上次中断处续播。90s 的短 fixture 在
  "启动(5s)+settle(10s)+采样" 的时间线上会中途播完，之后采到的全是"片尾
  挂机"状态（WS 高位不释放、vdec=0），数字完全失真。用 10min fixture
  （`sample_1080p60_10min.mp4`）+ `NIPAPLAY_EVAL_SEEK_ZERO`。
- **播完不释放是真实存在的行为**：短 fixture 实验里，播放到 89.9s 结束后
  WS 停在 1.2GB 不回落——这也是内存优化要覆盖的场景（长视频看片尾）。
- 本机 WMI `Win32_Perf*GPUPerformanceCounters` cooked 值恒 0，必须用
  Get-Counter；全通配 `\GPU Engine(*)` 枚举约 4 秒，采样器已合并为单次
  调用并按实际耗时归一化 CPU%（raw 行里的 `sampleSec` 可核查）。

## 本机构建注意事项（2026-10 记录）

GitHub 直连下载在本机不稳定（mpv/ANGLE/SDL3 归档下载会 MD5 失败）。已做的
机器本地处置：

- `build/windows/x64/` 下的 `mpv-dev-*.7z` 与 `ANGLE.7z` 由兄弟 checkout
  （NipaPlay-Reload）的好副本拷贝而来；MD5 与 CMakeLists 固定值一致。
- pub 缓存里 universal_gamepad 的 windows/CMakeLists.txt 的 SDL3 URL 被改为
  `http://127.0.0.1:8899/SDL3-3.2.8.zip`（zip 缓存在 `C:\Users\SAOAsuna\.cache\`）。
  全新 configure 时需先起服务器：
  ```
  python -m http.server 8899 --directory C:/Users/SAOAsuna/.cache --bind 127.0.0.1
  ```
  已构建过的目录走增量编译不触发重新下载，无需服务器。

## 输出示例

```
[playback / kernel]
  kernels:                MDK
  hwdec-current:          {'d3d11va': 58}
  dropped frames:         0
  rendered fps (est):     59.9  vs container 60.0
[system / process]
  CPU:                    avg 8.2%  p95 14.0%  peak 21.5%
  working set:            avg 612 MB  peak 705 MB
  GPU VideoDecode util:   avg 18.0%  p95 24.0%  peak 31.0%
  GPU dedicated VRAM:     avg 410 MB  peak 462 MB
```
