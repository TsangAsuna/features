import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/utils/subtitle_parser.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('subtitle_tags_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<SubtitleParseResult> parseContent(String content,
      {String fileName = 'sample.srt'}) async {
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsString(content);
    return SubtitleParser.parseSubtitleFile(file.path);
  }

  test('strips SSA override tags like {\\an8} from SRT text', () async {
    final result = await parseContent(
      '1\n00:00:00,000 --> 00:00:01,000\n{\\an8}顶部居中的一句话\n\n'
      '2\n00:00:01,000 --> 00:00:02,000\n{\\an8\\pos(960,40)}带定位的特效\n\n'
      '3\n00:00:02,000 --> 00:00:03,000\n普通台词 {\\i1}斜体{\\i0} 结束\n',
    );

    expect(result.format, SubtitleFormat.srt);
    expect(result.entries, hasLength(3));
    expect(result.entries[0].content, '顶部居中的一句话');
    expect(result.entries[1].content, '带定位的特效');
    expect(result.entries[2].content, '普通台词 斜体 结束');
  });

  test('drops SRT cues that contain nothing but override tags', () async {
    final result = await parseContent(
      '1\n00:00:00,000 --> 00:00:01,000\n{\\an8}\n\n'
      '2\n00:00:01,000 --> 00:00:02,000\n保留的台词\n',
    );

    expect(result.entries, hasLength(1));
    expect(result.entries.single.content, '保留的台词');
  });

  test('keeps plain curly-brace text that is not an override tag', () async {
    final result = await parseContent(
      '1\n00:00:00,000 --> 00:00:01,000\n{笑}这样的台词不能被吃掉\n',
    );

    expect(result.entries.single.content, '{笑}这样的台词不能被吃掉');
  });

  test('leaves ASS entries to the kernel-facing cleanup untouched', () async {
    final result = await parseContent(
      '[Script Info]\nScriptType: v4.00+\n\n'
      '[Events]\n'
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
      'Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,{\\an8}ASS 台词\n',
      fileName: 'sample.ass',
    );

    expect(result.format, SubtitleFormat.ass);
    // ASS 由 _cleanAssText 处理标记，解析出的文本不含裸标记即可
    expect(result.entries.single.content, isNot(contains('\\an8')));
  });
}
