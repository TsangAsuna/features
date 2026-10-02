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

| 指标 | mediaKit（dxva2-copy 硬解） | MDK（本机为软解） |
| --- | --- | --- |
| CPU 均值 / p95 | 10.1% / 22.4% | 22.3% / 28.4% |
| GPU VideoDecode | 4.3%（p95 10.9%） | **0%** |
| GPU 3D | 28.5%（p95 47.2%） | 30.2% |
| 专用显存峰值 | 1141 MB | 894 MB |
| 工作集峰值 | 1215 MB | 1201 MB |

**已知发现（记录于首次交付评估）**：MDK（fvp）内核在本机 Windows 上 1080p60
H.264 走软解（VideoDecode 引擎 0%、CPU 约为 mediaKit 硬解的 2 倍）；MDK 的
`getDetailedMediaInfo` 不暴露 mpv 式属性，`hwdec` 一栏对 MDK 判空，判定以
GPU `VideoDecode` 引擎利用率为准。若后续 MDK 交付前评估出现 VideoDecode>0
且 CPU 显著下降，说明硬解路径已打通。

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
