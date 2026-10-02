import 'package:flutter/material.dart';
import 'package:nipaplay/utils/video_player_state.dart';
import 'package:provider/provider.dart';

/// 内嵌字幕整块移动模式的渲染层。
///
/// 内核只解码不渲染（sub-visibility=no），App 按 sub-text 轮询取文本整
/// 块渲染：双语两行是一个 Widget——位置滑块移动整块、行距永不随 libass
/// 的逐行插值收拢；水平边距按屏幕像素生效（与 ASS PlayRes 坐标系无关）。
/// 全局字幕设置（大小/位置/边距/对齐/透明度/描边/阴影/粗斜体/颜色）
/// 在此模式下全部直接作用于这块文本。
class EmbeddedSubtitleOverlay extends StatelessWidget {
  const EmbeddedSubtitleOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<VideoPlayerState>(
      builder: (context, videoState, _) {
        if (!videoState.embeddedSubtitleOverlayMode) {
          return const SizedBox.shrink();
        }
        if (videoState.shouldHideSubtitlesForScreenshot) {
          // 截图「隐藏字幕」：仅在截图帧合成期间隐藏，不影响观看。
          return const SizedBox.shrink();
        }
        final text = videoState.embeddedSubtitleOverlayText;
        if (text.trim().isEmpty || videoState.hasVideo == false) {
          return const SizedBox.shrink();
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.of(context).size.width;
            final baseFontSize = (width * 0.03).clamp(18.0, 42.0).toDouble();
            final fontSize =
                (baseFontSize * videoState.subtitleScale).clamp(14.0, 72.0);

            final shadowOffset = videoState.subtitleShadowOffset;
            final fillStyle = TextStyle(
              fontSize: fontSize,
              fontWeight:
                  videoState.subtitleBold ? FontWeight.bold : FontWeight.w500,
              fontStyle:
                  videoState.subtitleItalic ? FontStyle.italic : FontStyle.normal,
              color: videoState.subtitleColor,
              height: 1.3,
              shadows: shadowOffset > 0
                  ? [
                      Shadow(
                        color: videoState.subtitleShadowColor,
                        offset: Offset(0, shadowOffset),
                        blurRadius: shadowOffset * 2,
                      ),
                    ]
                  : null,
            );

            final borderSize = videoState.subtitleBorderSize;
            final Widget textBlock = borderSize > 0
                ? Stack(
                    alignment: Alignment.center,
                    children: [
                      Text(
                        text,
                        textAlign: _resolveTextAlign(videoState.subtitleAlignX),
                        softWrap: true,
                        style: fillStyle.copyWith(
                          foreground: Paint()
                            ..style = PaintingStyle.stroke
                            ..strokeJoin = StrokeJoin.round
                            ..strokeWidth = borderSize.clamp(0.0, 8.0)
                            ..color = videoState.subtitleBorderColor,
                          color: null,
                          shadows: null,
                        ),
                      ),
                      Text(
                        text,
                        textAlign: _resolveTextAlign(videoState.subtitleAlignX),
                        softWrap: true,
                        style: fillStyle,
                      ),
                    ],
                  )
                : Text(
                    text,
                    textAlign: _resolveTextAlign(videoState.subtitleAlignX),
                    softWrap: true,
                    style: fillStyle,
                  );

            return Opacity(
              opacity: videoState.subtitleOpacity.clamp(0.0, 1.0),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: Align(
                  alignment: Alignment(
                    _resolveHorizontalAlignment(videoState.subtitleAlignX),
                    _resolveVerticalAlignment(videoState.subtitlePosition),
                  ),
                  child: Transform.translate(
                    offset: Offset(videoState.subtitleMarginX, 0),
                    child: textBlock,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  double _resolveHorizontalAlignment(SubtitleAlignX alignX) {
    switch (alignX) {
      case SubtitleAlignX.left:
        return -1;
      case SubtitleAlignX.center:
        return 0;
      case SubtitleAlignX.right:
        return 1;
    }
  }

  TextAlign _resolveTextAlign(SubtitleAlignX alignX) {
    switch (alignX) {
      case SubtitleAlignX.left:
        return TextAlign.left;
      case SubtitleAlignX.center:
        return TextAlign.center;
      case SubtitleAlignX.right:
        return TextAlign.right;
    }
  }

  /// 0=屏幕顶 100=屏幕底（与外挂叠层同一映射，整块移动、行距不收拢）。
  double _resolveVerticalAlignment(double subtitlePosition) {
    final normalized = subtitlePosition.clamp(
      VideoPlayerState.minSubtitlePosition,
      VideoPlayerState.maxSubtitlePosition,
    );
    return (normalized / 100) * 2.0 - 1.0;
  }
}
