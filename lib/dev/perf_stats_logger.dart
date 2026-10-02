import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 开发期性能评估遥测——不是面向用户的功能。
///
/// tools/perf/ 的交付前评估流程（见 tools/perf/README.md）用它在真实播放中
/// 采集内核侧指标（hwdec、掉帧、缓冲、码率），与外部采集的系统侧指标
/// （CPU/内存/GPU）按时间戳对齐。仅在非 release 构建且以
/// NIPAPLAY_PERF_LOG=<jsonl 路径> 启动时激活；普通启动路径下不创建任何
/// 对象、不启动定时器，保持零开销。
class DevPerfStatsLogger {
  DevPerfStatsLogger._();

  static final DevPerfStatsLogger instance = DevPerfStatsLogger._();

  static bool get enabled {
    if (kIsWeb || kReleaseMode) return false;
    try {
      return (Platform.environment['NIPAPLAY_PERF_LOG'] ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static const Duration _sampleInterval = Duration(seconds: 1);

  IOSink? _sink;
  Timer? _timer;
  bool _sampling = false;
  int _sampleIndex = 0;
  Duration? _lastPosition;
  Future<Map<String, dynamic>?> Function()? _snapshot;

  /// [snapshot] 每秒调用一次，返回当前的播放状态快照；返回 null 表示
  /// 当前没有可采集的播放器实例，该秒只记录进程级信息。
  void start(Future<Map<String, dynamic>?> Function() snapshot) {
    if (!enabled || _timer != null) return;
    final path = Platform.environment['NIPAPLAY_PERF_LOG']!;
    _snapshot = snapshot;
    try {
      File(path).parent.createSync(recursive: true);
      _sink = File(path).openWrite(mode: FileMode.append);
    } catch (e) {
      debugPrint('[DevPerfStatsLogger] 无法打开 $path: $e');
      _snapshot = null;
      return;
    }
    _emit(<String, dynamic>{
      'event': 'logger-start',
      'kernelEnv': Platform.environment['NIPAPLAY_FORCE_KERNEL'],
    });
    _timer = Timer.periodic(_sampleInterval, (_) => _sample());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _snapshot = null;
    final sink = _sink;
    _sink = null;
    await _emit(<String, dynamic>{'event': 'logger-stop'});
    try {
      await sink?.flush();
      await sink?.close();
    } catch (_) {}
  }

  Future<void> _sample() async {
    if (_sampling || _sink == null) return;
    _sampling = true;
    try {
      final snapshot = _snapshot;
      Map<String, dynamic>? snap;
      if (snapshot != null) {
        try {
          snap = await snapshot();
        } catch (e) {
          snap = <String, dynamic>{'error': '$e'};
        }
      }
      final record = <String, dynamic>{
        't': DateTime.now().toUtc().toIso8601String(),
        'i': _sampleIndex++,
        'rss': ProcessInfo.currentRss,
        'snap': snap,
      };
      final positionMs = snap?['positionMs'];
      if (positionMs is int) {
        final current = Duration(milliseconds: positionMs);
        record['positionDeltaMs'] = _lastPosition == null
            ? 0
            : current.inMilliseconds - _lastPosition!.inMilliseconds;
        _lastPosition = current;
      }
      await _emit(record);
    } finally {
      _sampling = false;
    }
  }

  Future<void> _emit(Map<String, dynamic> record) async {
    final sink = _sink;
    if (sink == null) return;
    sink.writeln(jsonEncode(record));
    try {
      await sink.flush();
    } catch (_) {}
  }
}
