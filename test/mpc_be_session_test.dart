import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay_core/models/external_player_session/mpc_be_session.dart';

/// #1023: MPC-BE 外部播放器适配。
/// 命令行参数拼装是 MPC-BE 会话唯一可脱离进程验证的行为面:
/// /new 强制新实例、/startpos 起播位置(百分之一秒)、/sub 注入弹幕 ASS。
void main() {
  test('启动参数按 /new /startpos /sub 顺序拼装并追加调用方参数', () {
    final args = MpcBeSession.buildLaunchArgs(
      const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 400),
      const <String>['--my-flag'],
      r'C:\tmp\nipaplay_danmaku\mpcbe_x.ass',
    );
    expect(args, <String>[
      '/new',
      '/startpos=01:02:03.40',
      r'/sub=C:\tmp\nipaplay_danmaku\mpcbe_x.ass',
      '--my-flag',
    ]);
  });

  test('零起点不携带 /startpos', () {
    final args = MpcBeSession.buildLaunchArgs(
      Duration.zero,
      const <String>[],
      'danmaku.ass',
    );
    expect(args, <String>['/new', '/sub=danmaku.ass']);
  });

  test('格式化不足两位的时间分量补零', () {
    final args = MpcBeSession.buildLaunchArgs(
      const Duration(seconds: 5, milliseconds: 70),
      const <String>[],
      'a.ass',
    );
    expect(args[1], '/startpos=00:00:05.07');
  });
}
