/// ASS/SSA MarginV 整体平移：外挂 ASS 位置滑块的唯一保排版通道。
///
/// mpv 没有任何能保持多事件相对边距的整体平移原语：
/// - `sub-pos` 按比例插值每个事件到底边的距离——双语两行（不同 MarginV）
///   随滑块趋顶按比例收拢，0 处完全重合；
/// - `sub-ass-force-style=MarginV` 是单值覆盖——双语两行通常是不同
///   Layer + 不同 MarginV 的两个事件（libass 跨层不做碰撞堆叠），单值
///   直接把两行钉在同一位置；
/// - 加性通道 `sub-margin-y` 在 media-kit 裁剪版 libmpv 中不存在。
///
/// 只有逐样式加性平移（作者 MarginV + Δ）能在移动整块的同时保留作者
/// 排版：两行各自边距差不变，\pos/\move 定位的彩色注释事件不使用
/// MarginV，完全不受影响。
///
/// 返回平移后的完整脚本文本；解析不出 Style 区/MarginV 列（或没有任何
/// Style 行被改写）时返回 null，调用方据此跳过重载。
String? rewriteAssMarginV(String text, int deltaY) {
  if (deltaY == 0) return null;
  final lines = text.split('\n');
  var inStyleSection = false;
  int? marginVIndex;
  var styleColumnCount = 0;
  var changed = false;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final stripped = line.trim();
    if (stripped.startsWith('[') && stripped.endsWith(']')) {
      final header = stripped.substring(1, stripped.length - 1).toLowerCase();
      inStyleSection = header.contains('v4') && header.contains('style');
      if (!inStyleSection) {
        marginVIndex = null;
        styleColumnCount = 0;
      }
      continue;
    }
    if (!inStyleSection) continue;

    final lower = stripped.toLowerCase();
    if (marginVIndex == null && lower.startsWith('format:')) {
      final columns =
          stripped.substring(stripped.indexOf(':') + 1).split(',');
      for (var c = 0; c < columns.length; c++) {
        if (columns[c].trim().toLowerCase() == 'marginv') {
          marginVIndex = c;
          break;
        }
      }
      if (marginVIndex != null) styleColumnCount = columns.length;
      continue;
    }
    if (marginVIndex == null || !lower.startsWith('style:')) continue;

    final body = line.substring(line.indexOf(':') + 1);
    final fields = body.split(',');
    // 列数不符（字体名带逗号等异常）时整行保持原样，宁可不平移也不错位。
    if (styleColumnCount != 0 && fields.length != styleColumnCount) continue;
    if (marginVIndex >= fields.length) continue;

    final raw = fields[marginVIndex].trim();
    final value = int.tryParse(raw);
    if (value == null) continue;
    final shifted = (value + deltaY).clamp(0, 2147483647);
    if (shifted == value) continue;
    final leadingSpace = fields[marginVIndex].startsWith(' ') ? ' ' : '';
    fields[marginVIndex] = '$leadingSpace$shifted';
    lines[i] = '${line.substring(0, line.indexOf(':') + 1)}${fields.join(',')}';
    changed = true;
  }

  // 以"实际改写过的行"为准——marginVIndex 在离开 Style 区时会被复位，
  // 不能用循环结束后的残留状态判定。
  return changed ? lines.join('\n') : null;
}
