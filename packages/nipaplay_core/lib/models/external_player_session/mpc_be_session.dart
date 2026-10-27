// lib/models/external_player_session/mpc_be_session.dart
// Windows MPC-BE 外部播放器会话

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:nipaplay_core/constants/media_extensions.dart';
import 'package:nipaplay_core/models/danmaku/danmaku_item.dart';
import 'package:nipaplay_core/models/danmaku/style.dart';
import 'package:nipaplay_core/models/external_player_session/other_session.dart';
import 'package:nipaplay_core/models/external_player_session/session.dart';
import 'package:nipaplay_core/utils/danmaku_ass_converter.dart';
import 'package:nipaplay_core/utils/external_player_danmaku_ass.dart';


/// MPC-BE 没有公开的运行时控制接口(无 IPC / 窗口消息文档),
/// 弹幕以 ASS 字幕文件在启动时经 `/sub` 注入, 起播位置用 `/startpos`.
/// 进程生命周期管理复用 [OtherSession] 的轮询逻辑.
class MpcBeSession extends OtherSession {
  factory MpcBeSession({
    required String playerPath,
    required String mediaPath,
    required Duration duration,
    Duration position = Duration.zero,
    List<String> extraArgs = const <String>[],
    DanmakuItemSet? initialDanmakuSet,
  }) {
    return MpcBeSession._(
      playerPath: playerPath,
      mediaPath: mediaPath,
      duration: duration,
      initialPosition: position,
      extraArgs: extraArgs,
      assFilePath: _createAssFilePath(),
      initialDanmakuSet: initialDanmakuSet,
    );
  }

  MpcBeSession._({
    required super.playerPath,
    required super.mediaPath,
    required super.duration,
    required Duration initialPosition,
    required List<String> extraArgs,
    required String assFilePath,
    required DanmakuItemSet? initialDanmakuSet,
  })  : _assFilePath = assFilePath,
        _initialDanmakuSet = initialDanmakuSet,
        super(
          type: ExternalPlayerType.mpcBe,
          position: initialPosition,
          extraArgs: buildLaunchArgs(initialPosition, extraArgs, assFilePath),
        );

  final String _assFilePath;
  final DanmakuItemSet? _initialDanmakuSet;

  /// MPC-BE 启动参数: 强制新实例、起播位置、外挂弹幕 ASS, 再追加调用方参数.
  static List<String> buildLaunchArgs(
    Duration position,
    List<String> extraArgs,
    String assFilePath,
  ) =>
      <String>[
        '/new',
        if (position > Duration.zero)
          '/startpos=${_formatStartPos(position)}',
        '/sub=$assFilePath',
        ...extraArgs,
      ];

  /// MPC-BE 接受 `hh:mm:ss.ff`(百分之一秒)形式的起播位置.
  static String _formatStartPos(Duration position) {
    final centiseconds =
        (position.inMilliseconds ~/ 10).clamp(0, 35999999);
    final hours = centiseconds ~/ (Duration.millisecondsPerHour ~/ 10);
    final minutes =
        (centiseconds ~/ (Duration.millisecondsPerMinute ~/ 10)) % 60;
    final seconds =
        (centiseconds ~/ (Duration.millisecondsPerSecond ~/ 10)) % 60;
    final fraction = centiseconds % 100;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(hours)}:${two(minutes)}:${two(seconds)}.${two(fraction)}';
  }

  static String _createAssFilePath() {
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final path = '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'nipaplay_danmaku${Platform.pathSeparator}mpcbe_$timestamp.ass';
    return path;
  }

  @override
  Future<void> launch() async {
    if (isClosed) throw StateError('MpcBeSession 已关闭');
    try {
      final initialDanmakuSet = _initialDanmakuSet;
      if (initialDanmakuSet != null && initialDanmakuSet.isNotEmpty) {
        await _writeDanmakuAss(initialDanmakuSet, DanmakuStyle());
      } else {
        await File(_assFilePath).create(recursive: true);
      }
      await super.launch();
    } catch (_) {
      _deleteAssFile();
      rethrow;
    }
  }

  Future<void> _writeDanmakuAss(
    DanmakuItemSet danmakuSet,
    DanmakuStyle style,
  ) async {
    final settings = AssExportSettings(
      fontSize: style.danmakuFontSize,
      opacity: style.opacity,
      timeOffsetSeconds: style.danmakuOffset,
      allowStacking: style.danmakuAllowStacking,
      outlineStyle:
          style.outlineEnabled ? AssOutlineStyle.uniform : AssOutlineStyle.none,
      outlineWidth: style.outlineWidth,
    );
    final ass = await generateExternalPlayerDanmakuAss(
      danmakuSet.toList(growable: false),
      settings,
    );
    final directory = File(_assFilePath).parent;
    await directory.create(recursive: true);
    final temporaryFile = File('$_assFilePath.nipaplay.tmp');
    try {
      await temporaryFile.writeAsString(ass, flush: true);
      await temporaryFile.rename(_assFilePath);
    } finally {
      if (temporaryFile.existsSync()) await temporaryFile.delete();
    }
  }

  void _deleteAssFile() {
    for (final path in [_assFilePath, '$_assFilePath.nipaplay.tmp']) {
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException catch (error) {
        debugPrint('[MpcBeSession] 删除临时弹幕失败: $error');
      }
    }
  }

  @override
  void dispose() {
    _deleteAssFile();
    super.dispose();
  }
}
