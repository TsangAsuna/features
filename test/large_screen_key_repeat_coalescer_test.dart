import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/themes/nipaplay/widgets/large_screen_key_repeat_coalescer.dart';

void main() {
  test('first request executes immediately', () {
    final coalescer = NipaplayKeyRepeatCoalescer();
    var moves = 0;
    coalescer.request(() => moves++);
    expect(moves, 1);
    coalescer.dispose();
  });

  test('rapid requests inside the interval coalesce into one trailing move',
      () async {
    var now = DateTime(2026, 10, 3);
    final coalescer = NipaplayKeyRepeatCoalescer(
      minInterval: const Duration(milliseconds: 60),
      now: () => now,
    );
    var moves = 0;
    var lastDirection = 0;

    // 首次立即移动。
    coalescer.request(() {
      moves++;
      lastDirection = 1;
    });
    expect(moves, 1);

    // 30ms 后的重复事件：进入节拍间隙，只挂起尾随移动。
    now = now.add(const Duration(milliseconds: 30));
    coalescer.request(() {
      moves++;
      lastDirection = 2;
    });
    expect(moves, 1);
    expect(coalescer.hasPendingMove, isTrue);

    // 又一个重复事件：更新尾随方向，不再叠加定时器。
    coalescer.request(() {
      moves++;
      lastDirection = 3;
    });
    expect(moves, 1);

    // 节拍到期：只执行最新一次方向。
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(moves, 2);
    expect(lastDirection, 3);
    expect(coalescer.hasPendingMove, isFalse);
    coalescer.dispose();
  });

  test('cancel drops the pending trailing move', () async {
    var now = DateTime(2026, 10, 3);
    final coalescer = NipaplayKeyRepeatCoalescer(
      minInterval: const Duration(milliseconds: 60),
      now: () => now,
    );
    var moves = 0;
    coalescer.request(() => moves++);
    now = now.add(const Duration(milliseconds: 10));
    coalescer.request(() => moves++);
    expect(coalescer.hasPendingMove, isTrue);

    coalescer.cancel();
    expect(coalescer.hasPendingMove, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(moves, 1);
    coalescer.dispose();
  });

  test('requests spaced beyond the interval execute immediately', () {
    var now = DateTime(2026, 10, 3);
    final coalescer = NipaplayKeyRepeatCoalescer(
      minInterval: const Duration(milliseconds: 60),
      now: () => now,
    );
    var moves = 0;
    coalescer.request(() => moves++);
    now = now.add(const Duration(milliseconds: 60));
    coalescer.request(() => moves++);
    now = now.add(const Duration(milliseconds: 60));
    coalescer.request(() => moves++);
    expect(moves, 3);
    expect(coalescer.hasPendingMove, isFalse);
    coalescer.dispose();
  });

  test('Timer-based cadence matches the configured interval', () async {
    final coalescer = NipaplayKeyRepeatCoalescer(
      minInterval: const Duration(milliseconds: 50),
    );
    var moves = 0;
    coalescer.request(() => moves++);
    // 模拟按住方向键的系统重复（间隔 16ms）。
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      coalescer.request(() => moves++);
    }
    // 6 次 16ms 重复（96ms 窗口）最多推进到 2 个节拍：
    // 首次立即 + 至多 2 次节拍移动，而不是每次重复都移动。
    expect(moves, lessThanOrEqualTo(3));
    expect(moves, greaterThanOrEqualTo(2));
    coalescer.dispose();
  });
}
