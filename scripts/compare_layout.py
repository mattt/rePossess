# /// script
# requires-python = ">=3.10"
# ///
"""Compare rePossess's text layout with the tablet's own PDF export of the same page.

Usage:
    repossess layout <id> <page> > layout.json
    uv run scripts/compare_layout.py layout.json tablet.pdf <pdf-page> [--show-text]

The tablet's lines come from `mutool draw -F stext` (MuPDF, from Homebrew):
each line's text, the x of its first character, and its baseline,
converted to tablet pixels at 72/227 points per pixel.
rePossess's lines come from `repossess layout`.
Lines are matched by their text, in order, with difflib.

The script prints counts and distances only, never text, unless --show-text is given,
so that it can run on private pages.
Stroke groups are compared by their bounds: for each group that rePossess places,
the tablet's vector paths within 15 px of the group are joined,
and the script prints the distance between the edges of the two bounds.
The tablet draws each stroke as an outline, so its bounds are wider by about half a stroke.
That match is a heuristic; check the images by eye as well.
"""

from __future__ import annotations

import difflib
import json
import re
import statistics
import subprocess
import sys

SCALE = 72 / 227  # points per tablet pixel on the Paper Pure's PDF export
BULLETS = {"•", "◦", "&#x2022;", "&#x25e6;"}


def unescape(text: str) -> str:
    text = re.sub(r"&#x([0-9a-fA-F]+);", lambda m: chr(int(m.group(1), 16)), text)
    return text.replace("&quot;", '"').replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")


def tablet_lines(pdf: str, page: str) -> list[dict]:
    out = subprocess.run(
        ["mutool", "draw", "-F", "stext", "-o", "-", pdf, page], capture_output=True, text=True, check=True
    ).stdout
    lines = []
    pattern = (
        r'<line bbox="[^"]+"[^>]*text="([^"]*)">\s*<font name="[^"]+" size="([^"]+)">'
        r'\s*<char c="[^"]*" quad="[^"]*" x="([^"]+)" y="([^"]+)"'
    )
    for m in re.finditer(pattern, out):
        text, size, x, y = m.groups()
        text = unescape(text)
        if text.strip() in BULLETS:
            continue
        lines.append({"text": text, "x": float(x) / SCALE, "baseline": float(y) / SCALE, "size": float(size) / SCALE})
    return lines


def tablet_paths(pdf: str, page: str) -> list[tuple[float, float, float, float]]:
    out = subprocess.run(
        ["mutool", "draw", "-F", "trace", "-o", "-", pdf, page], capture_output=True, text=True, check=True
    ).stdout
    boxes = []
    for block in re.finditer(r"<(stroke_path|fill_path)([^>]*)>(.*?)</\1>", out, re.S):
        transform = re.search(r'transform="([^"]+)"', block.group(2))
        a, b, c, d, e, f = (float(v) for v in transform.group(1).split()) if transform else (1, 0, 0, 1, 0, 0)
        points = [(float(px), float(py)) for px, py in re.findall(r'x="([-\d.]+)" y="([-\d.]+)"', block.group(3))]
        if len(points) < 4:
            continue
        # Apply the path's transform, then convert points to tablet pixels (y down from the top).
        xs = [(a * px + c * py + e) / SCALE for px, py in points]
        ys = [(b * px + d * py + f) / SCALE for px, py in points]
        boxes.append((min(xs), min(ys), max(xs), max(ys)))
    return boxes


def normalize(text: str) -> str:
    # mutool writes U+FFFD for ligature glyphs, such as "fi", that it cannot map to text.
    text = re.sub("ffi|ffl|ff|fi|fl", "\ufffd", text)
    return " ".join(text.split())


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    show = "--show-text" in sys.argv
    if len(args) != 3:
        sys.exit(__doc__)
    layout = json.load(open(args[0]))
    ours = [line for line in layout["lines"] if line["text"].strip()]
    theirs = tablet_lines(args[1], args[2])

    a = [normalize(line["text"]) for line in theirs]
    b = [normalize(line["text"]) for line in ours]
    matcher = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    pairs = []
    for block in matcher.get_matching_blocks():
        for k in range(block.size):
            pairs.append((theirs[block.a + k], ours[block.b + k]))

    print(f"tablet lines: {len(theirs)}")
    print(f"rePossess lines: {len(ours)}")
    print(f"lines with the same text: {len(pairs)}")
    if pairs:
        dy = [o["baseline"] - t["baseline"] for t, o in pairs]
        dx = [o["x"] - t["x"] for t, o in pairs]
        print(f"baseline difference, px: mean {statistics.mean(dy):+.1f}, mean absolute "
              f"{statistics.mean(abs(v) for v in dy):.1f}, largest absolute {max(abs(v) for v in dy):.1f}")
        print(f"x difference, px: mean absolute {statistics.mean(abs(v) for v in dx):.1f}, "
              f"largest absolute {max(abs(v) for v in dx):.1f}")
    if theirs:
        print(f"tablet text bottom: {max(t['baseline'] for t in theirs):.0f} px; "
              f"rePossess: {max((o['baseline'] for o in ours), default=0):.0f} px")
    if "--detail" in sys.argv:
        # For each tablet line: its font size, the style and step of the matching line, without text.
        mine = {id(t): o for t, o in pairs}
        previous_t = previous_o = None
        for t in theirs:
            o = mine.get(id(t))
            step_t = t["baseline"] - previous_t if previous_t is not None else 0
            if o is not None:
                step_o = o["baseline"] - previous_o if previous_o is not None else 0
                print(f"  size {t['size']:4.0f} {o['style']:16} tablet step {step_t:6.1f} rePossess step {step_o:6.1f}"
                      f" offset {o['baseline'] - t['baseline']:+6.1f}")
                previous_o = o["baseline"]
            else:
                print(f"  size {t['size']:4.0f} {'(no match)':16} tablet step {step_t:6.1f}")
            previous_t = t["baseline"]
    if show:
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag != "equal":
                print(f"{tag}: tablet {a[i1:i2]} rePossess {b[j1:j2]}")

    groups = layout.get("groups", [])
    if groups:
        paths = tablet_paths(args[1], args[2])
        print(f"stroke groups: {len(groups)}, of which anchored: {sum(1 for g in groups if g['anchored'])}; "
              f"tablet vector paths: {len(paths)}")
        for i, g in enumerate(groups):
            x0, y0 = g["x"] - 15, g["y"] - 15
            x1, y1 = g["x"] + g["width"] + 15, g["y"] + g["height"] + 15
            near = [p for p in paths if p[0] < x1 and p[2] > x0 and p[1] < y1 and p[3] > y0]
            label = f"  group {i + 1} ({'anchored' if g['anchored'] else 'free'}, {g['strokes']} strokes)"
            if not near:
                print(f"{label}: no tablet path within 15 px of it")
                continue
            left, top = min(p[0] for p in near), min(p[1] for p in near)
            right, bottom = max(p[2] for p in near), max(p[3] for p in near)
            print(f"{label}: left {g['x'] - left:+.0f}, top {g['y'] - top:+.0f}, "
                  f"right {g['x'] + g['width'] - right:+.0f}, bottom {g['y'] + g['height'] - bottom:+.0f} px "
                  f"from the {len(near)} tablet paths near it")


if __name__ == "__main__":
    main()
