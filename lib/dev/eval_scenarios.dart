import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../utils/video_player_state.dart';

/// 开发期交付评估的自动化场景钩子（tools/perf/README.md）——不是用户功能。
///
/// 让 run_eval 能脚本化复现"挂载字幕""弹幕开关"等内存场景做 A/B：
///   NIPAPLAY_EVAL_SUBTITLE=<ass/srt 路径>   播放开始后自动挂载外挂字幕
///   NIPAPLAY_EVAL_SYNTH_DANMAKU=<条数>      注入指定数量的合成弹幕
///   NIPAPLAY_EVAL_DANMAKU_OFF_AT=<秒>       播放到该秒时关闭弹幕（模拟用户开关）
///   NIPAPLAY_EVAL_DANMAKU_ON_AT=<秒>        播放到该秒时重新打开弹幕
/// 仅在非 release 构建生效；未设置任何变量时不创建定时器、不驻留任何对象。
class EvalScenarios {
  EvalScenarios._();

  static bool get enabled {
    if (kIsWeb || kReleaseMode) return false;
    try {
      return _env('NIPAPLAY_EVAL_SUBTITLE') != null ||
          _intEnv('NIPAPLAY_EVAL_SYNTH_DANMAKU') > 0 ||
          _intEnv('NIPAPLAY_EVAL_DANMAKU_OFF_AT') > 0 ||
          _intEnv('NIPAPLAY_EVAL_DANMAKU_ON_AT') > 0;
    } catch (_) {
      return false;
    }
  }

  static String? _env(String name) {
    final value = Platform.environment[name];
    if (value == null || value.trim().isEmpty) return null;
    return value.trim();
  }

  static int _intEnv(String name) =>
      int.tryParse(_env(name) ?? '') ?? 0;

  static Timer? _timer;
  static bool _subtitleAttached = false;
  static bool _danmakuInjected = false;
  static bool _danmakuTurnedOff = false;
  static bool _danmakuTurnedOn = false;

  static void start(VideoPlayerState vs) {
    if (!enabled || _timer != null) return;
    debugPrint('[EvalScenarios] 场景钩子已启动: '
        'subtitle=${_env('NIPAPLAY_EVAL_SUBTITLE')} '
        'danmaku=${_intEnv('NIPAPLAY_EVAL_SYNTH_DANMAKU')} '
        'offAt=${_intEnv('NIPAPLAY_EVAL_DANMAKU_OFF_AT')} '
        'onAt=${_intEnv('NIPAPLAY_EVAL_DANMAKU_ON_AT')}');
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick(vs));
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static Future<void> _tick(VideoPlayerState vs) async {
    if (vs.isDisposed) {
      stop();
      return;
    }
    try {
      final subtitlePath = _env('NIPAPLAY_EVAL_SUBTITLE');
      if (!_subtitleAttached &&
          subtitlePath != null &&
          vs.currentVideoPath != null) {
        _subtitleAttached = true;
        debugPrint('[EvalScenarios] 挂载外挂字幕: $subtitlePath');
        await vs.addExternalSubtitleToStack(subtitlePath);
      }

      final danmakuCount = _intEnv('NIPAPLAY_EVAL_SYNTH_DANMAKU');
      if (!_danmakuInjected && danmakuCount > 0 && vs.position.inSeconds >= 2) {
        _danmakuInjected = true;
        debugPrint('[EvalScenarios] 注入合成弹幕 $danmakuCount 条');
        await vs.loadDanmakuFromLocal(_syntheticDanmaku(danmakuCount),
            trackName: 'eval-synth', setStatusMessage: false);
      }

      final offAt = _intEnv('NIPAPLAY_EVAL_DANMAKU_OFF_AT');
      if (!_danmakuTurnedOff && offAt > 0 && vs.position.inSeconds >= offAt) {
        _danmakuTurnedOff = true;
        debugPrint('[EvalScenarios] ${offAt}s 关闭弹幕');
        vs.setDanmakuVisible(false);
      }

      final onAt = _intEnv('NIPAPLAY_EVAL_DANMAKU_ON_AT');
      if (!_danmakuTurnedOn && onAt > 0 && vs.position.inSeconds >= onAt) {
        _danmakuTurnedOn = true;
        debugPrint('[EvalScenarios] ${onAt}s 重新打开弹幕');
        vs.setDanmakuVisible(true);
      }
    } catch (e) {
      debugPrint('[EvalScenarios] 场景执行失败: $e');
    }
  }

  /// dandanplay 标准格式（'p': 'time,mode,color,uid'），覆盖整个 90 分钟时间轴，
  /// 文本带中英文混合与 CJK 宽字符，贴近真实剧场版弹幕负载。
  static Map<String, dynamic> _syntheticDanmaku(int count) {
    final texts = <String>[
      '前方高能预警！！！',
      'This animation quality is incredible',
      '作画监督换人了吗，这幕画质绝了',
      '名场面来了 名场面来了 名场面来了',
      '泪目...二十年了还是会被这段感动',
      'ここだ、このシーンを待っていた',
      '经费在燃烧 经费在燃烧',
    ];
    final comments = List<Map<String, dynamic>>.generate(count, (i) {
      // 均匀铺满 90 分钟，mode 轮换 1(滚动)/4(底)/5(顶)，颜色轮换几种。
      final t = (i % 5400) + (i / 5400.0);
      final mode = i % 7 == 0 ? 5 : (i % 11 == 0 ? 4 : 1);
      final color = 0xFFFFFF & (0xF0F0F0 + (i % 16) * 0x010101);
      return <String, dynamic>{
        'cid': i + 1,
        'p': '$t,$mode,$color,eval-$i',
        'm': '${texts[i % texts.length]} #$i',
      };
    });
    return <String, dynamic>{
      'count': count,
      'comments': comments,
    };
  }
}
