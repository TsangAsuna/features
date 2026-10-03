import 'dart:async';

import 'package:flutter/foundation.dart';

/// 大屏幕导航的按键重复节拍器。
///
/// 遥控器/键盘按住方向键时，系统会以约 30Hz 持续送出 [KeyRepeatEvent]。
/// 若每次重复都立即移动焦点，120–180ms 级的焦点高亮与滚动动画会被不断
/// 重置，快速连按时表现为高亮"爬行"、滚动永远追不上焦点。
///
/// [request] 把重复事件合并成固定节拍（默认 60ms）：距离上次移动不足
/// [minInterval] 时挂起一个尾随移动，节拍到期只执行最新一次方向，其余丢弃。
/// 首次请求（或距上次移动已超过节拍）则立即同步执行。
class NipaplayKeyRepeatCoalescer {
  NipaplayKeyRepeatCoalescer({
    this.minInterval = const Duration(milliseconds: 60),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 两次焦点移动之间的最小间隔。
  final Duration minInterval;

  final DateTime Function() _now;
  DateTime _lastMoveAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pendingTimer;
  VoidCallback? _pendingMove;

  /// 是否存在待执行的尾随移动（测试用）。
  @visibleForTesting
  bool get hasPendingMove => _pendingTimer != null;

  /// 提交一次移动请求。可能立即执行，也可能挂起到下一个节拍。
  void request(VoidCallback move) {
    final timestamp = _now();
    final elapsed = timestamp.difference(_lastMoveAt);
    if (elapsed >= minInterval) {
      _cancelPending();
      _lastMoveAt = timestamp;
      move();
      return;
    }
    // 节拍间隙内的重复事件：只保留最新方向，到期统一执行。
    _pendingMove = move;
    _pendingTimer ??= Timer(minInterval - elapsed, _flushPending);
  }

  /// 取消挂起的尾随移动（松开按键 / 收到新的 KeyDown 时调用），
  /// 避免"松手后又多走一步"。
  void cancel() {
    _pendingMove = null;
    _cancelPending();
  }

  void dispose() {
    cancel();
  }

  void _flushPending() {
    _pendingTimer = null;
    final move = _pendingMove;
    _pendingMove = null;
    if (move == null) {
      return;
    }
    _lastMoveAt = _now();
    move();
  }

  void _cancelPending() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
  }
}
