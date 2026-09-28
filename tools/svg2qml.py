#!/usr/bin/env python3
"""Turn a downloaded SVG into the data AgentTalk's bar icon renders from.

The icon in the bar has to look like every other icon in the bar: one flat
colour, the colour the theme is currently using. Rasterising an SVG and
tinting it with a shader gets close but never exact, and a shader per bar
widget is a lot of machinery for one glyph. Qt can already fill an SVG path,
so this script lifts the path data out of the file once and QML fills it with
the bar's own colour. That is the same guarantee a Nerd Font glyph has.

Usage:

    tools/svg2qml.py assets/icon.svg > assets/icon.js

Output is a plain JS module: the viewBox size plus one entry per path. Paths
that are drawn with a `transform` are kept as they are, because QML's PathSvg
does not read SVG transforms; `tools/svg2qml.py --flatten` bakes the common
translate/scale/matrix cases into the path data instead.
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET

SVG_NS = "{http://www.w3.org/2000/svg}"


def parse_transform(value: str) -> tuple[float, float, float, float, float, float]:
    """Return the affine matrix (a b c d e f) of an SVG transform attribute."""
    matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
    for name, args in re.findall(r"(\w+)\s*\(([^)]*)\)", value or ""):
        numbers = [float(n) for n in re.findall(r"-?\d*\.?\d+(?:e[-+]?\d+)?", args)]
        if name == "translate":
            tx = numbers[0] if numbers else 0.0
            ty = numbers[1] if len(numbers) > 1 else 0.0
            matrix = multiply([1, 0, 0, 1, tx, ty], matrix)
        elif name == "scale":
            sx = numbers[0] if numbers else 1.0
            sy = numbers[1] if len(numbers) > 1 else sx
            matrix = multiply([sx, 0, 0, sy, 0, 0], matrix)
        elif name == "matrix" and len(numbers) == 6:
            matrix = multiply(numbers, matrix)
    return tuple(matrix)


def multiply(outer: list[float], inner: tuple[float, ...]) -> list[float]:
    a1, b1, c1, d1, e1, f1 = outer
    a2, b2, c2, d2, e2, f2 = inner
    return [
        a1 * a2 + c1 * b2,
        b1 * a2 + d1 * b2,
        a1 * c2 + c1 * d2,
        b1 * c2 + d1 * d2,
        a1 * e2 + c1 * f2 + e1,
        b1 * e2 + d1 * f2 + f1,
    ]


NUMBER = re.compile(r"-?\d*\.?\d+(?:[eE][-+]?\d+)?")


def apply_matrix_to_path(data: str, m: tuple[float, ...]) -> str:
    """Bake an affine matrix into path data.

    Only absolute commands are handled, which is all icon files use: the
    command letter is kept and every coordinate pair is rewritten. Anything
    relative or arc-based is left untouched rather than silently corrupted,
    and the caller is told about it through the return value being equal to the
    input.
    """
    a, b, c, d, e, f = m
    if (a, b, c, d, e, f) == (1.0, 0.0, 0.0, 1.0, 0.0, 0.0):
        return data

    tokens = re.findall(r"[AaCcHhLlMmQqSsTtVvZz]|[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?", data)
    out: list[str] = []
    command = ""
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if re.match(r"[A-Za-z]", token):
            command = token
            out.append(token)
            index += 1
            continue
        # Absolute moveto/lineto/curveto/quadratic: rewrite coordinate pairs.
        if command in ("M", "L", "T"):
            x, y = float(tokens[index]), float(tokens[index + 1])
            out.extend([fmt(a * x + c * y + e), fmt(b * x + d * y + f)])
            index += 2
        elif command in ("C", "S", "Q"):
            values = [float(v) for v in tokens[index : index + 6]]
            pairs = [(values[0], values[1]), (values[2], values[3]), (values[4], values[5])]
            for x, y in pairs:
                out.extend([fmt(a * x + c * y + e), fmt(b * x + d * y + f)])
            index += 6
        elif command == "H":
            x = float(tokens[index])
            out.append(fmt(a * x + e))
            index += 1
        elif command == "V":
            y = float(tokens[index])
            out.append(fmt(d * y + f))
            index += 1
        else:
            out.append(token)
            index += 1
    return " ".join(out)


def fmt(value: float) -> str:
    rounded = round(value, 3)
    if rounded == int(rounded):
        return str(int(rounded))
    return str(rounded)


def collect_paths(node: ET.Element, inherited: tuple[float, ...], flatten: bool, skipped: list[str]) -> list[dict]:
    matrix = inherited
    transform = node.get("transform")
    if transform:
        matrix = multiply(list(parse_transform(transform)), list(inherited))

    paths: list[dict] = []
    for child in node:
        tag = child.tag.replace(SVG_NS, "")
        if tag == "g":
            paths.extend(collect_paths(child, matrix, flatten, skipped))
        elif tag == "path":
            data = (child.get("d") or "").strip()
            if not data:
                continue
            if flatten and matrix != (1.0, 0.0, 0.0, 1.0, 0.0, 0.0):
                if re.search(r"[AaRrSsQqTt]", data):
                    skipped.append("relative or arc/quadratic commands")
                data = apply_matrix_to_path(data, matrix)
            elif matrix != (1.0, 0.0, 0.0, 1.0, 0.0, 0.0):
                skipped.append("a transform that needs --flatten")
            paths.append({"d": data})
        elif tag in ("circle", "rect", "polygon", "line"):
            data = primitive_to_path(child)
            if data:
                if flatten and matrix != (1.0, 0.0, 0.0, 1.0, 0.0, 0.0):
                    data = apply_matrix_to_path(data, matrix)
                paths.append({"d": data})
    return paths


def primitive_to_path(node: ET.Element) -> str:
    def num(name: str, fallback: float = 0.0) -> float:
        raw = node.get(name)
        return float(raw) if raw not in (None, "") else fallback

    tag = node.tag.replace(SVG_NS, "")
    if tag == "circle":
        cx, cy, r = num("cx"), num("cy"), num("r")
        return (
            f"M {fmt(cx - r)} {fmt(cy)} a {fmt(r)} {fmt(r)} 0 1 0 {fmt(2 * r)} 0 "
            f"a {fmt(r)} {fmt(r)} 0 1 0 {fmt(-2 * r)} 0 Z"
        )
    if tag == "rect":
        x, y, w, h = num("x"), num("y"), num("width"), num("height")
        return f"M {fmt(x)} {fmt(y)} H {fmt(x + w)} V {fmt(y + h)} H {fmt(x)} Z"
    if tag == "line":
        return f"M {fmt(num('x1'))} {fmt(num('y1'))} L {fmt(num('x2'))} {fmt(num('y2'))}"
    if tag == "polygon":
        points = [float(n) for n in NUMBER.findall(node.get("points") or "")]
        pairs = " ".join(f"{fmt(points[i])},{fmt(points[i + 1])}" for i in range(0, len(points) - 1, 2))
        return f"M {pairs} Z"
    return ""


def viewbox_size(root: ET.Element) -> float:
    raw = root.get("viewBox")
    if raw:
        numbers = [float(n) for n in NUMBER.findall(raw)]
        if len(numbers) == 4:
            return max(numbers[2], numbers[3])
    for name in ("width", "height"):
        if root.get(name):
            return float(NUMBER.findall(root.get(name))[0])
    return 512.0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("svg", type=argparse.FileType("r", encoding="utf-8"))
    parser.add_argument(
        "--flatten",
        action="store_true",
        help="bake group transforms into the path data",
    )
    args = parser.parse_args()

    root = ET.parse(args.svg).getroot()
    skipped: list[str] = []
    paths = collect_paths(root, (1.0, 0.0, 0.0, 1.0, 0.0, 0.0), args.flatten, skipped)

    if not paths:
        print("no <path> data found in that SVG", file=sys.stderr)
        return 1
    for reason in sorted(set(skipped)):
        print(f"warning: {reason} was not transformed", file=sys.stderr)

    print("// Generated by tools/svg2qml.py from the icon artwork. Do not edit by hand.")
    print(f"var box = {fmt(viewbox_size(root))}")
    print("var paths = [")
    for path in paths:
        print(f'  {{d: {json_string(path["d"])}}},')
    print("]")
    return 0


def json_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


if __name__ == "__main__":
    raise SystemExit(main())
