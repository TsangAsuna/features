import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/utils/ass_margin_shift.dart';

const _standardAss = '''
[Script Info]
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Dial_CH,HYQiHei 65S,80,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2.25,0,2,15,15,53,1
Style: Dial_JP,FOT-TsukuGo Pro B,56,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2.1,0,2,15,15,8,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 5,0:05:11.33,0:05:15.79,Dial_JP,,0,0,0,,日本語
Dialogue: 6,0:05:11.33,0:05:15.79,Dial_CH,,0,0,0,,汉化
''';

String _styleMarginV(String text, String styleName) {
  final line = text
      .split('\n')
      .firstWhere((l) => l.startsWith('Style: $styleName'));
  final fields = line.substring(line.indexOf(':') + 1).split(',');
  return fields[21].trim(); // 标准格式 MarginV 是第 22 列
}

void main() {
  test('shifts every style MarginV additively, preserving authored gaps',
      () {
    final shifted = rewriteAssMarginV(_standardAss, 100)!;
    expect(_styleMarginV(shifted, 'Dial_CH'), '153'); // 53 + 100
    expect(_styleMarginV(shifted, 'Dial_JP'), '108'); // 8 + 100，差值仍为 45
    // 事件行（含 \pos/\move 注释）与脚本头原样保留。
    expect(shifted, contains('Dialogue: 5,0:05:11.33,0:05:15.79,Dial_JP'));
    expect(shifted, contains('Dialogue: 6,0:05:11.33,0:05:15.79,Dial_CH'));
    expect(shifted, contains('PlayResY: 1080'));
  });

  test('handles custom column order and CRLF line endings', () {
    final text = '[V4+ Styles]\r\n'
        'Format: MarginV, Name, Fontsize\r\n'
        'Style: 8, Dial_JP, 56\r\n'
        'Style: 53, Dial_CH, 80\r\n';
    final shifted = rewriteAssMarginV(text, 10)!;
    expect(shifted.contains('\r'), isTrue, reason: 'CRLF 必须原样保留');
    expect(shifted, contains('Style: 18, Dial_JP, 56'));
    expect(shifted, contains('Style: 63, Dial_CH, 80'));
  });

  test('clamps MarginV at 0 and skips malformed style rows', () {
    final text = '[V4+ Styles]\r\n'
        'Format: Name, MarginV, Fontsize\r\n'
        'Style: Dial_JP, 5, 56\r\n'
        'Style: Bad_Row, 1\r\n' // 列数不符 → 原样保留
        'Style: Not_A_Number, abc, 56\r\n'; // 非数字 → 原样保留
    final shifted = rewriteAssMarginV(text, -20)!;
    expect(shifted, contains('Style: Dial_JP, 0, 56'));
    expect(shifted, contains('Style: Bad_Row, 1'));
    expect(shifted, contains('Style: Not_A_Number, abc, 56'));
  });

  test('returns null when nothing can be shifted', () {
    expect(rewriteAssMarginV(_standardAss, 0), isNull);
    expect(rewriteAssMarginV('Style: A, B, 1\n', 10), isNull,
        reason: '无 Style 区/Format 行时不平移');
    final noMarginV = '[V4+ Styles]\n'
        'Format: Name, Fontname\n'
        'Style: Dial_CH, HYQiHei\n';
    expect(rewriteAssMarginV(noMarginV, 10), isNull);
  });

  test('leaves other sections untouched even with lookalike lines', () {
    final text = '[Events]\n'
        'Format: Layer, Text\n'
        'Dialogue: 0,Style: Fake, MarginV\n'
        '\n'
        '[V4+ Styles]\n'
        'Format: Name, MarginV\n'
        'Style: Dial_JP, 8\n';
    final shifted = rewriteAssMarginV(text, 5)!;
    expect(shifted, contains('Dialogue: 0,Style: Fake, MarginV'));
    expect(shifted, contains('Style: Dial_JP, 13'));
  });
}
