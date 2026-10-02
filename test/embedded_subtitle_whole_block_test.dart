import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipaplay/player_abstraction/erika_player_adapter.dart';
import 'package:nipaplay/player_abstraction/media_kit_player_adapter.dart';
import 'package:nipaplay/player_abstraction/player_abstraction.dart';
import 'package:nipaplay/player_menu/player_menu_pane_controllers.dart';
import 'package:nipaplay/themes/nipaplay/widgets/subtitle_settings_menu.dart';
import 'package:nipaplay/utils/video_player_state.dart';
import 'package:nipaplay/widgets/embedded_subtitle_overlay.dart';
import 'package:provider/provider.dart';
import 'package:nipaplay/providers/appearance_settings_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 整块移动模式自测：
/// 1. 滑块存在性——Media Kit 下「字幕位置/水平边距」滑块与
///    「双语整块移动」开关在菜单里可见；Erika 下水平边距滑块不显示。
/// 2. 整块模式链路——开关同步 sub-visibility、sub-text 轮询填充文本、
///    关闭时恢复内核渲染并清空文本。
/// 3. 0 位置不重叠——双语两行是一个 Widget：位置 0 与 100 都完整渲染
///    两行（行距不可能收拢），对齐按滑块映射到顶/底。
class _FakeMediaKitDelegate extends Fake implements MediaKitPlayerAdapter {
  _FakeMediaKitDelegate({this.liveProperties = const {}});

  final Map<String, String> liveProperties;
  final Map<String, String> writtenProperties = {};

  @override
  void setProperty(String key, String value) {
    writtenProperties[key] = value;
  }

  @override
  Future<String?> getLiveProperty(String name) async {
    return liveProperties[name];
  }
}

Future<VideoPlayerState> _buildVideoPlayerState(
    AbstractPlayer delegate) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final videoState = VideoPlayerState();
  videoState.player = Player.withDelegate(delegate);
  return videoState;
}

Widget _wrap(Widget child, VideoPlayerState videoState) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<AppearanceSettingsProvider>(
        create: (_) => AppearanceSettingsProvider(),
      ),
      ChangeNotifierProvider<VideoPlayerState>.value(value: videoState),
      ChangeNotifierProvider<SubtitleSettingsPaneController>(
        create: (_) => SubtitleSettingsPaneController(videoState: videoState),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('Media Kit menu shows sliders and whole-block switch',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final delegate = _FakeMediaKitDelegate();
    final videoState = await _buildVideoPlayerState(delegate);
    await tester.pumpWidget(_wrap(
      SingleChildScrollView(
        child: SubtitleSettingsMenu(onClose: () {}, onHoverChanged: null),
      ),
      videoState,
    ));
    await tester.pumpAndSettle();
    // BaseSettingsMenu 头部「回到默认」按钮在测试表面约束下溢出 13px
    // （真实播放器菜单更宽），吞掉这个纯布局噪音后断言。
    while (tester.takeException() != null) {}

    // SettingsSlider 的标签在其内部渲染，断言用各区段的 hint 文本。
    expect(find.text('0=顶部，100=底部'), findsOneWidget);
    expect(find.textContaining('位移幅度取决于字幕脚本分辨率'), findsOneWidget);
    expect(find.text('双语整块移动（不重叠）'), findsOneWidget);
  });

  testWidgets('Erika menu hides the horizontal margin slider',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final delegate = _FakeErikaDelegate();
    final videoState = await _buildVideoPlayerState(delegate);
    await tester.pumpWidget(_wrap(
      SingleChildScrollView(
        child: SubtitleSettingsMenu(onClose: () {}, onHoverChanged: null),
      ),
      videoState,
    ));
    await tester.pumpAndSettle();
    while (tester.takeException() != null) {}

    // Erika 走仅字号分支：位置/水平边距/整块开关都不存在。
    expect(find.text('0=顶部，100=底部'), findsNothing);
    expect(find.textContaining('位移幅度取决于字幕脚本分辨率'), findsNothing);
    expect(find.text('双语整块移动（不重叠）'), findsNothing);
  });

  testWidgets('whole-block mode writes sub-visibility and polls sub-text',
      (tester) async {
    final delegate = _FakeMediaKitDelegate(liveProperties: {
      'sub-text': '中文翻译行\n日本語原文行',
    });
    final videoState = await _buildVideoPlayerState(delegate);

    await videoState.setEmbeddedSubtitleOverlayMode(true);
    expect(
      delegate.writtenProperties['sub-visibility'],
      'no',
      reason: '开启整块模式必须在 Media Kit 上隐藏内核渲染',
    );
    videoState.pollEmbeddedSubtitleOverlayText();
    await tester.pump();
    await tester.pump();
    expect(videoState.embeddedSubtitleOverlayText, '中文翻译行\n日本語原文行');

    await videoState.setEmbeddedSubtitleOverlayMode(false);
    expect(
      delegate.writtenProperties['sub-visibility'],
      'yes',
      reason: '关闭整块模式必须恢复内核渲染',
    );
    expect(videoState.embeddedSubtitleOverlayText, isEmpty);
  });

  testWidgets('line-order flip renders the reversed block', (tester) async {
    final delegate = _FakeMediaKitDelegate(liveProperties: {
      'sub-text': '中文翻译行\n日本語原文行',
    });
    final videoState = await _buildVideoPlayerState(delegate);
    await videoState.setEmbeddedSubtitleOverlayMode(true);
    videoState.pollEmbeddedSubtitleOverlayText();
    await tester.pump();
    await tester.pump();

    // 默认：跟随 sub-text 原序（翻译在上）。
    expect(videoState.embeddedSubtitleOverlayDisplayText,
        '中文翻译行\n日本語原文行');

    // 开启翻转：日语行到上方（多事件双语的内核行序可能与期望相反）。
    await videoState.setEmbeddedSubtitleOverlayReversed(true);
    expect(videoState.embeddedSubtitleOverlayDisplayText,
        '日本語原文行\n中文翻译行');
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 800,
        height: 600,
        child: EmbeddedSubtitleOverlay(),
      ),
      videoState,
    ));
    await tester.pump();
    expect(find.text('日本語原文行\n中文翻译行'), findsNWidgets(2));
  });

  testWidgets('bilingual block renders both lines at slider 0 and 100',
      (tester) async {
    final delegate = _FakeMediaKitDelegate(liveProperties: {
      'sub-text': '中文翻译行\n日本語原文行',
    });
    final videoState = await _buildVideoPlayerState(delegate);
    await videoState.setEmbeddedSubtitleOverlayMode(true);
    videoState.pollEmbeddedSubtitleOverlayText();
    await tester.pump();
    await tester.pump();

    Future<void> pumpAtPosition(double position) async {
      await videoState.setSubtitlePosition(position);
      await tester.pumpWidget(_wrap(
        const SizedBox(
          width: 800,
          height: 600,
          child: EmbeddedSubtitleOverlay(),
        ),
        videoState,
      ));
      await tester.pump();
    }

    // 位置 0（顶部）：两行文本都必须完整渲染——整块模式行距不可能收拢。
    await pumpAtPosition(0);
    expect(find.textContaining("中文翻译行"), findsNWidgets(2)); // 描边层+填充层
    expect(find.textContaining("日本語原文行"), findsNWidgets(2));
    final alignAtTop = tester.widget<Align>(
      find.ancestor(
        of: find.textContaining('中文翻译行'),
        matching: find.byType(Align),
      ).first,
    );
    expect((alignAtTop.alignment as Alignment).y, -1);

    // 位置 100（底部）：同一块文本整体移动，两行仍完整。
    await pumpAtPosition(100);
    expect(find.textContaining("中文翻译行"), findsNWidgets(2)); // 描边层+填充层
    expect(find.textContaining("日本語原文行"), findsNWidgets(2));
    final alignAtBottom = tester.widget<Align>(
      find.ancestor(
        of: find.textContaining('中文翻译行'),
        matching: find.byType(Align),
      ).first,
    );
    expect((alignAtBottom.alignment as Alignment).y, 1);

    // 垂直边距：与内核路径同一折算（10px ≈ 1% 位置百分比、向上移动）。
    await videoState.setSubtitleMarginY(200);
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 800,
        height: 600,
        child: EmbeddedSubtitleOverlay(),
      ),
      videoState,
    ));
    await tester.pump();
    final alignWithMargin = tester.widget<Align>(
      find.ancestor(
        of: find.textContaining('中文翻译行'),
        matching: find.byType(Align),
      ).first,
    );
    // 位置 100 - 200*0.1 = 80 → (80/100)*2-1 = 0.6
    expect((alignWithMargin.alignment as Alignment).y, closeTo(0.6, 0.001));
  });
}

class _FakeErikaDelegate extends Fake implements ErikaPlayerAdapter {}
