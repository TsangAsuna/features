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

  Map<String, String> liveProperties;
  final Map<String, String> writtenProperties = {};

  @override
  void setProperty(String key, String value) {
    writtenProperties[key] = value;
  }

  @override
  Future<String?> getLiveProperty(String name) async {
    return liveProperties[name];
  }

  // 外挂字幕选择/清除路径会触达这三个成员（守卫先于短路求值），
  // 未实现会让 setExternalSubtitle 整体中断、状态清不掉。
  @override
  bool get supportsExternalSubtitles => true;

  @override
  List<int> get activeSubtitleTracks => const [];

  @override
  void setMedia(String path, PlayerMediaType type) {}
}

Future<VideoPlayerState> _buildVideoPlayerState(
    AbstractPlayer delegate) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final videoState = VideoPlayerState();
  final player = Player.withDelegate(delegate);
  videoState.player = player;
  // 生产环境由 player_kernel_manager 在内核切换时同步给各 manager；
  // 测试里必须手动同步，否则 SubtitleManager 仍持有未物化的懒委托
  // （内核名"未知"，外挂 ASS 的内核轨判定会失效）。
  videoState.subtitleManager.updatePlayer(player);
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

  testWidgets('whole-block mode steps aside for kernel-rendered external ASS',
      (tester) async {
    final delegate = _FakeMediaKitDelegate(liveProperties: {
      'sub-text': '中文翻译行\n日本語原文行',
    });
    final videoState = await _buildVideoPlayerState(delegate);

    // 注入激活中的内核轨外挂 ASS：直接写轨道信息，不经文件系统/内核加载。
    const assPath = 'Z:/sample.chs.ass';
    videoState.setCurrentExternalSubtitlePath(assPath);
    videoState.updateDanmakuTrackInfo('external_subtitle', <String, dynamic>{
      'path': assPath,
      'title': '外挂ASS',
      'isActive': true,
      'isManualSet': true,
    });
    expect(videoState.isKernelRenderedExternalAssActive, isTrue);

    await videoState.setEmbeddedSubtitleOverlayMode(true);
    expect(
      delegate.writtenProperties['sub-visibility'],
      isNot('no'),
      reason: '外挂 ASS 必须保留 libass 脚本样式渲染，不得关 sub-visibility',
    );

    // 整块纯文本块必须整层退位：否则 \pos 定位/彩色注解被压成白色居中
    // 纯文本（实测 Medalist 第1集书上的小字翻译全部丢失样式）。
    videoState.debugSetEmbeddedSubtitleOverlayText('中文翻译行\n日本語原文行');
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 800,
        height: 600,
        child: EmbeddedSubtitleOverlay(),
      ),
      videoState,
    ));
    await tester.pump();
    expect(find.textContaining('中文翻译行'), findsNothing);

    // 轮询在外挂 ASS 激活期间不再填充整块文本，并清掉切换前残留。
    videoState.pollEmbeddedSubtitleOverlayText();
    await tester.pump();
    await tester.pump();
    expect(videoState.embeddedSubtitleOverlayText, isEmpty);

    // 取消外挂（切回内嵌轨）后，整块模式恢复接管：sub-visibility=no、
    // 纯文本块重新上屏。
    videoState.setExternalSubtitle('');
    expect(
      delegate.writtenProperties['sub-visibility'],
      'no',
      reason: '外挂取消后整块模式应恢复内核只解码不渲染',
    );
    videoState.debugSetEmbeddedSubtitleOverlayText('中文翻译行\n日本語原文行');
    await tester.pump();
    expect(find.textContaining('中文翻译行'), findsNWidgets(2)); // 描边层+填充层
  });

  testWidgets('external kernel ASS keeps script layout: no slider leaks',
      (tester) async {
    final delegate = _FakeMediaKitDelegate();
    final videoState = await _buildVideoPlayerState(delegate);

    // 注入激活中的内核轨外挂 ASS（不经文件系统/内核加载）。
    const assPath = 'Z:/sample.chs.ass';
    videoState.setCurrentExternalSubtitlePath(assPath);
    videoState.updateDanmakuTrackInfo('external_subtitle', <String, dynamic>{
      'path': assPath,
      'title': '外挂ASS',
      'isActive': true,
      'isManualSet': true,
    });

    // 用户在整块模式/内嵌轨上调过的滑块不得泄漏进外挂 ASS 内核渲染：
    // sub-pos 复位底部、override 固定 no（否则 libass 逐行插值收拢，
    // 双语两行挤在一起、字号被改写）。
    await videoState.setSubtitlePosition(50);
    await videoState.applySubtitleStylePreference();
    expect(delegate.writtenProperties['sub-pos'], '100',
        reason: '外挂 ASS 激活时 sub-pos 必须复位默认（视频底部）');
    expect(delegate.writtenProperties['sub-ass-override'], 'no');
    expect(delegate.writtenProperties['sub-ass-force-style'], '');

    // 取消外挂（切回内嵌轨）后恢复滑块语义：位置跟随滑块，
    // 偏离默认时 auto 模式的 override 升级规则照常生效。
    videoState.setExternalSubtitle('');
    await videoState.applySubtitleStylePreference();
    expect(delegate.writtenProperties['sub-pos'], '50');
    expect(delegate.writtenProperties['sub-ass-override'], 'yes');
  });

  testWidgets('bilingual line order auto-corrects: translation above, original below',
      (tester) async {
    final delegate = _FakeMediaKitDelegate(liveProperties: {
      // 内核事件排序把日文行放在前面（实测出现过的反序）
      'sub-text': '日本語原文行テスト\n中文翻译行',
    });
    final videoState = await _buildVideoPlayerState(delegate);
    await videoState.setEmbeddedSubtitleOverlayMode(true);
    videoState.pollEmbeddedSubtitleOverlayText();
    await tester.pump();
    await tester.pump();

    // 含假名的行判定为原文排下方，纯汉字行是汉化排上方——无需手动开关。
    expect(videoState.embeddedSubtitleOverlayDisplayText,
        '中文翻译行\n日本語原文行テスト');
    await tester.pumpWidget(_wrap(
      const SizedBox(
        width: 800,
        height: 600,
        child: EmbeddedSubtitleOverlay(),
      ),
      videoState,
    ));
    await tester.pump();
    expect(find.text('中文翻译行\n日本語原文行テスト'), findsNWidgets(2));

    // 内核本来就给正序时结果不变。（轮询有 120ms 真实时钟节流，测试里
    // 用 debug 注入口直接设文本。）
    videoState.debugSetEmbeddedSubtitleOverlayText('中文翻译行\n日本語原文行テスト');
    await tester.pump();
    expect(videoState.embeddedSubtitleOverlayDisplayText,
        '中文翻译行\n日本語原文行テスト');

    // 全带假名（纯日文多行）：无判别依据，保持内核原序。
    videoState.debugSetEmbeddedSubtitleOverlayText('日本語一行目\n日本語二行目');
    await tester.pump();
    expect(videoState.embeddedSubtitleOverlayDisplayText,
        '日本語一行目\n日本語二行目');
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
