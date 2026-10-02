#!/usr/bin/env python3
"""Summarize one NipaPlay evaluation run (see tools/perf/README.md).

Reads the two JSONL streams written during a run —
  perf.jsonl     (external sampler: tools/perf/capture_perf.ps1)
  playback.jsonl (in-app logger:  lib/dev/perf_stats_logger.dart)
merges them on nearest timestamp, and prints a summary plus writes
summary.json next to the inputs.

Usage:
  python tools/perf/analyze_perf.py tools/perf/out/<run-dir>
"""

import json
import os
import statistics
import sys
from datetime import datetime

MB = 1024 * 1024


def parse_ts(raw):
    return datetime.fromisoformat(raw.replace("Z", "+00:00"))


def load_jsonl(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def percentile(values, pct):
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, max(0, round(pct / 100.0 * (len(ordered) - 1))))
    return ordered[idx]


def fmt_pct(value):
    return f"{value:.1f}%"


def fmt_mb(value_bytes):
    return f"{value_bytes / MB:.0f} MB"


def find_mpv_props(snap):
    info = (snap or {}).get("info") or {}
    props = info.get("mpvProperties")
    if isinstance(props, dict):
        return info, props
    return info, {}


def summarize_run(run_dir):
    perf_rows = load_jsonl(os.path.join(run_dir, "perf.jsonl"))
    play_rows = load_jsonl(os.path.join(run_dir, "playback.jsonl"))

    summary = {"run_dir": os.path.abspath(run_dir)}

    # ---- external (system) side -------------------------------------------------
    if perf_rows:
        # Group by timestamp: several processes may share one sample.
        by_ts = {}
        for row in perf_rows:
            by_ts.setdefault(row["t"], []).append(row)
        cpu, ws, pb, dedicated, shared = [], [], [], [], []
        decode_util, render_util = [], []
        for rows in by_ts.values():
            cpu.append(sum(r.get("cpuPct", 0.0) for r in rows))
            ws.append(sum(r.get("workingSet", 0.0) for r in rows))
            pb.append(sum(r.get("privateBytes", 0.0) for r in rows))
            dedicated.append(sum(r.get("gpuDedicated", 0.0) for r in rows))
            shared.append(sum(r.get("gpuShared", 0.0) for r in rows))
            engines = {}
            for r in rows:
                for eng, val in (r.get("gpuEngines") or {}).items():
                    engines[eng.lower()] = engines.get(eng.lower(), 0.0) + val
            decode_util.append(engines.get("videodecode", 0.0))
            render_util.append(engines.get("3d", 0.0))
        pids = sorted({str(r.get("pid")) for r in perf_rows})
        summary["system"] = {
            "pids": pids,
            "samples": len(by_ts),
            "cpuPct": {
                "avg": round(statistics.mean(cpu), 1),
                "p95": round(percentile(cpu, 95), 1),
                "peak": round(max(cpu), 1),
            },
            "workingSet": {
                "avg": round(statistics.mean(ws)),
                "peak": round(max(ws)),
            },
            "privateBytes": {
                "avg": round(statistics.mean(pb)),
                "peak": round(max(pb)),
            },
            "gpuDedicated": {
                "avg": round(statistics.mean(dedicated)),
                "peak": round(max(dedicated)),
            },
            "gpuShared": {
                "avg": round(statistics.mean(shared)),
                "peak": round(max(shared)),
            },
            "gpuVideoDecodeUtilPct": {
                "avg": round(statistics.mean(decode_util), 1),
                "p95": round(percentile(decode_util, 95), 1),
                "peak": round(max(decode_util), 1),
            },
            "gpu3DUtilPct": {
                "avg": round(statistics.mean(render_util), 1),
                "p95": round(percentile(render_util, 95), 1),
                "peak": round(max(render_util), 1),
            },
        }

    # ---- in-app (kernel) side ---------------------------------------------------
    snaps = [
        r for r in play_rows
        if isinstance(r.get("snap"), dict) and "error" not in r["snap"]
    ]
    if snaps:
        kernels = sorted({s["snap"].get("kernel", "?") for s in snaps})
        ready = [s for s in snaps if s["snap"].get("mediaReady")]
        playing = [s for s in snaps if (s.get("positionDeltaMs") or 0) > 500]
        deltas = [s["positionDeltaMs"] for s in snaps if "positionDeltaMs" in s]
        dropped_first, dropped_last = None, None
        fps_est, fps_container = [], []
        hwdec_values = {}
        decode_mismatches = []
        stall_samples = 0
        hwdec_samples = 0
        for s in ready:
            snap = s["snap"]
            info, props = find_mpv_props(snap)
            hwdec = props.get("hwdec-current")
            if hwdec not in (None, ""):
                hwdec_samples += 1
                hwdec_values[str(hwdec)] = hwdec_values.get(str(hwdec), 0) + 1
                if str(hwdec).lower() in ("no", "auto", ""):
                    decode_mismatches.append(s["t"])
            dropped = props.get("dropped-frame-count")
            if isinstance(dropped, (int, float)):
                if dropped_first is None:
                    dropped_first = dropped
                dropped_last = dropped
            fps = props.get("estimated-vf-fps")
            if isinstance(fps, (int, float)):
                fps_est.append(fps)
            fps_c = props.get("container-fps")
            if isinstance(fps_c, (int, float)):
                fps_container.append(fps_c)
            if props.get("paused-for-cache") in (True, "true", 1):
                stall_samples += 1
        video_info = {}
        info0 = (ready[0]["snap"].get("info") or {}) if ready else {}
        for key in ("videoFormat", "duration", "video", "kernel"):
            if key in info0:
                video_info[key] = info0[key]
        mdk_video = info0.get("video") or []
        if mdk_video and isinstance(mdk_video, list):
            first = mdk_video[0] or {}
            video_info["codecName"] = first.get("codecName")
            video_info["width"] = first.get("width")
            video_info["height"] = first.get("height")
        summary["playback"] = {
            "kernels": kernels,
            "samples": len(play_rows),
            "ready_samples": len(ready),
            "playing_samples": len(playing),
            "position_delta_ms": {
                "min": min(deltas) if deltas else None,
                "max": max(deltas) if deltas else None,
            },
            "hwdec": {
                "observed_values": hwdec_values,
                "active_samples": sum(
                    1 for v in hwdec_values
                    if v.lower() not in ("no", "auto", "false")
                ),
                "samples_with_value": hwdec_samples,
                "fallback_or_auto_samples": len(decode_mismatches),
            },
            "dropped_frames": {
                "count": (dropped_last or 0) - (dropped_first or 0)
                if dropped_first is not None else None,
            },
            "estimated_vf_fps": {
                "avg": round(statistics.mean(fps_est), 2) if fps_est else None,
                "min": round(min(fps_est), 2) if fps_est else None,
            },
            "container_fps": {
                "avg": round(statistics.mean(fps_container), 2)
                if fps_container else None,
            },
            "paused_for_cache_samples": stall_samples,
            "media": video_info,
        }

    out_path = os.path.join(run_dir, "summary.json")
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2, ensure_ascii=False)
    return summary, out_path


def print_summary(summary):
    sys_info = summary.get("system")
    play_info = summary.get("playback")

    print("=" * 62)
    print(f"NipaPlay evaluation summary — {summary['run_dir']}")
    print("=" * 62)

    if play_info:
        print("\n[playback / kernel]")
        print(f"  kernels:                {', '.join(play_info['kernels'])}")
        media = play_info.get("media", {})
        if media:
            dim = (f"{media.get('width')}x{media.get('height')}"
                   if media.get("width") else "n/a")
            print(f"  media:                  {media.get('codecName') or media.get('videoFormat') or '?'} {dim}")
        hw = play_info.get("hwdec", {})
        values = hw.get("observed_values") or {}
        print(f"  hwdec-current:          {values or 'n/a (kernel does not expose it)'}")
        print(f"  dropped frames:         {play_info['dropped_frames'].get('count')}")
        est = play_info["estimated_vf_fps"].get("avg")
        con = play_info["container_fps"].get("avg")
        print(f"  rendered fps (est):     {est}  vs container {con}")
        print(f"  paused-for-cache:       {play_info['paused_for_cache_samples']} samples")
        print(f"  playing samples:        {play_info['playing_samples']}/"
              f"{play_info['ready_samples'] or play_info['playing_samples']} ready")

    if sys_info:
        print("\n[system / process]")
        cpu = sys_info["cpuPct"]
        print(f"  CPU:                    avg {fmt_pct(cpu['avg'])}  "
              f"p95 {fmt_pct(cpu['p95'])}  peak {fmt_pct(cpu['peak'])}")
        ws = sys_info["workingSet"]
        pb = sys_info["privateBytes"]
        print(f"  working set:            avg {fmt_mb(ws['avg'])}  peak {fmt_mb(ws['peak'])}")
        print(f"  private bytes:          avg {fmt_mb(pb['avg'])}  peak {fmt_mb(pb['peak'])}")
        dec = sys_info["gpuVideoDecodeUtilPct"]
        eng3d = sys_info["gpu3DUtilPct"]
        print(f"  GPU VideoDecode util:   avg {fmt_pct(dec['avg'])}  "
              f"p95 {fmt_pct(dec['p95'])}  peak {fmt_pct(dec['peak'])}")
        print(f"  GPU 3D util:            avg {fmt_pct(eng3d['avg'])}  "
              f"p95 {fmt_pct(eng3d['p95'])}  peak {fmt_pct(eng3d['peak'])}")
        ded = sys_info["gpuDedicated"]
        sha = sys_info["gpuShared"]
        print(f"  GPU dedicated VRAM:     avg {fmt_mb(ded['avg'])}  peak {fmt_mb(ded['peak'])}")
        print(f"  GPU shared VRAM:        avg {fmt_mb(sha['avg'])}  peak {fmt_mb(sha['peak'])}")

    print("\n" + ("PASS data collected — compare against the baseline run "
                   "and thresholds in tools/perf/README.md"))


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    run_dir = sys.argv[1]
    if not os.path.isdir(run_dir):
        print(f"not a directory: {run_dir}")
        return 2
    summary, out_path = summarize_run(run_dir)
    print_summary(summary)
    print(f"\nwritten: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
