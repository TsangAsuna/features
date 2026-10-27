import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/player_abstraction/player_abstraction.dart';
import 'package:nipaplay/utils/video_player_state.dart';

/// #967: 时间轴截图预览在预览播放器纹理不可用时, snapshot 的渲染回调
/// 永远不会送达, 无界等待曾把串行队列和 hover 调用永久挂死(窗口未响应)。
/// snapshotPlayerFrameBounded 必须把任何 snapshot 等待变成有界等待。
class _HangingSnapshotPlayer extends Fake implements AbstractPlayer {
  @override
  Future<PlayerFrame?> snapshot({int width = 0, int height = 0}) =>
      Completer<PlayerFrame?>().future;
}

class _InstantSnapshotPlayer extends Fake implements AbstractPlayer {
  @override
  Future<PlayerFrame?> snapshot({int width = 0, int height = 0}) async =>
      PlayerFrame(
        width: width,
        height: height,
        bytes: Uint8List.fromList(const [1, 2, 3, 4]),
      );
}

class _ThrowingSnapshotPlayer extends Fake implements AbstractPlayer {
  @override
  Future<PlayerFrame?> snapshot({int width = 0, int height = 0}) async =>
      throw StateError('kernel snapshot failed');
}

void main() {
  test('snapshot 永不完成时按超时返回 null, 调用方不再挂死', () async {
    final frame = await snapshotPlayerFrameBounded(
      _HangingSnapshotPlayer(),
      width: 320,
      height: 180,
      timeout: const Duration(milliseconds: 50),
    );
    expect(frame, isNull);
  });

  test('snapshot 正常完成时返回帧', () async {
    final frame = await snapshotPlayerFrameBounded(
      _InstantSnapshotPlayer(),
      width: 320,
      height: 180,
      timeout: const Duration(milliseconds: 200),
    );
    expect(frame, isNotNull);
    expect(frame!.bytes, const [1, 2, 3, 4]);
  });

  test('snapshot 抛错原样透出, 由调用方捕获', () async {
    await expectLater(
      snapshotPlayerFrameBounded(
        _ThrowingSnapshotPlayer(),
        width: 320,
        height: 180,
        timeout: const Duration(milliseconds: 200),
      ),
      throwsStateError,
    );
  });
}
