import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:nipaplay/themes/nipaplay/widgets/large_screen_key_repeat_coalescer.dart';

typedef NipaplayFocusBoundaryCallback = void Function(
    TraversalDirection direction);

class NipaplayDirectionalFocusScope extends StatefulWidget {
  const NipaplayDirectionalFocusScope({
    super.key,
    required this.child,
    this.onBoundaryReached,
  });

  final Widget child;
  final NipaplayFocusBoundaryCallback? onBoundaryReached;

  @override
  State<NipaplayDirectionalFocusScope> createState() =>
      _NipaplayDirectionalFocusScopeState();
}

class _NipaplayDirectionalFocusScopeState
    extends State<NipaplayDirectionalFocusScope> {
  static final Set<LogicalKeyboardKey> _arrowKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };

  final NipaplayKeyRepeatCoalescer _repeatCoalescer =
      NipaplayKeyRepeatCoalescer();

  @override
  void dispose() {
    _repeatCoalescer.dispose();
    super.dispose();
  }

  /// 方向键统一移动入口：KeyDown（Shortcuts 触发）与 KeyRepeat（节拍器
  /// 触发）共用，保证边界回调行为一致。
  void _moveFocus(TraversalDirection direction) {
    final primaryFocus = FocusManager.instance.primaryFocus;
    bool moved = false;
    if (primaryFocus != null) {
      moved = primaryFocus.focusInDirection(direction);
    } else {
      moved = FocusScope.of(context).nextFocus();
    }
    if (!moved &&
        (direction == TraversalDirection.up ||
            direction == TraversalDirection.down)) {
      widget.onBoundaryReached?.call(direction);
    }
  }

  /// KeyRepeat 不再交给 Shortcuts（includeRepeats: false），在这里按
  /// 固定节拍合并移动，避免按住方向键时高亮/滚动动画被逐事件重置。
  KeyEventResult _handleRepeatKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      if (_arrowKeys.contains(event.logicalKey)) {
        _repeatCoalescer.cancel();
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final TraversalDirection? direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    if (direction == null) {
      return KeyEventResult.ignored;
    }
    _repeatCoalescer.request(() {
      if (!mounted) {
        return;
      }
      _moveFocus(direction);
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleRepeatKeyEvent,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowUp, includeRepeats: false):
              DirectionalFocusIntent(TraversalDirection.up),
          SingleActivator(
                  LogicalKeyboardKey.arrowDown, includeRepeats: false):
              DirectionalFocusIntent(TraversalDirection.down),
          SingleActivator(
                  LogicalKeyboardKey.arrowLeft, includeRepeats: false):
              DirectionalFocusIntent(TraversalDirection.left),
          SingleActivator(
                  LogicalKeyboardKey.arrowRight, includeRepeats: false):
              DirectionalFocusIntent(TraversalDirection.right),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
              onInvoke: (intent) {
                _moveFocus(intent.direction);
                return null;
              },
            ),
          },
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: FocusScope(
              autofocus: true,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
