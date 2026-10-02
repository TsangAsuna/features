#!/usr/bin/env python3
"""Generate a heavy theatrical-cut-style ASS subtitle fixture for the
tools/perf evaluation rig: ~90 minutes of dialogue with dense per-line style
overrides (\\pos, \\fad, \\t transforms, blur, borders) similar to typeset
fansubs, so libass/MDK subtitle memory and CPU cost is representative.

Usage: python tools/perf/make_heavy_subtitle.py [out.ass]
"""
import sys

DIALOGUE_SKELETONS = [
    r"Dialogue: 0,{t}:30.00,{t}:35.00,Title,,0,0,0,,{{\\pos(960,1200)\\fad(300,300)\\blur{b}}}剧场版测试字幕第 {i} 行 — 远离尘嚣的山丘上",
    r"Dialogue: 0,{t}:40.00,{t}:45.00,OP,,0,0,0,,{{\\move(192,1080,1728,200,0,2000)\\fad(200,200)}}Moving typeset line {i} with motion",
    r"Dialogue: 0,{t}:50.00,{t}:55.00,Main,,0,0,0,,{{\\c&H{c}&\\3c&H{c}&\\t(0,2000,\\fscx110\\fscy110)}}这里只有一句普普通通的对白，但样式很重 #{i}",
    r"Dialogue: 0,{t}:55.00,{t}:59.00,Sign,,0,0,0,,{{\\an7\\pos(100,100)\\t(0,1500,\\frz360)\\p1}}m 0 0 l 200 0 200 100 0 100{{\\p0}}",
    r"Dialogue: 0,{t}:10.00,{t}:20.00,Main,,0,0,0,,Mixed CJK + Latin dialogue line {i}: the quick brown fox jumps over 懒狗 0123456789",
]


def main(out):
    lines = []
    lines.append("[Script Info]")
    lines.append("ScriptType: v4.00+")
    lines.append("PlayResX: 1920")
    lines.append("PlayResY: 1080")
    lines.append("ScaledBorderAndShadow: yes")
    lines.append("")
    lines.append("[V4+ Styles]")
    lines.append("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding")
    lines.append("Style: Main,Subfont,60,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,2,2,60,60,30,1")
    lines.append("Style: Title,Subfont,72,&H0000FFFF,&H000000FF,&H00101010,&H80000000,-1,0,0,0,100,100,0,0,1,3,1,8,60,60,30,1")
    lines.append("Style: OP,Subfont,55,&H00FFFFFF,&H000000FF,&H00202020,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,60,60,30,1")
    lines.append("Style: Sign,Subfont,45,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,7,60,60,30,1")
    lines.append("")
    lines.append("[Events]")
    lines.append("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text")

    count = 0
    # 90 minutes, one line every 2 seconds -> 2700 lines of heavy typesetting.
    for minute in range(90):
        for k, skel in enumerate(DIALOGUE_SKELETONS):
            t = f"{minute:02d}"
            c = f"{0x101010 + (minute * 7 + k * 31) % 0xEFEFEF:06X}"
            b = 0.5 + (minute % 5) * 0.5
            lines.append(skel.format(t=t, i=count, c=c, b=b))
            count += 1

    with open(out, "w", encoding="utf-8-sig") as fh:  # BOM like real fansubs
        fh.write("\n".join(lines) + "\n")
    print(f"written {out}: {count} dialogue lines")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else
         "tools/perf/fixtures/heavy_theatrical.ass")
