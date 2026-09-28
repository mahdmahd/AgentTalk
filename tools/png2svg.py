#!/usr/bin/env python3
"""Trace a monochrome PNG into the SVG that `tools/svg2qml.py` turns into paths.

Flaticon serves the bar icon as an SVG, but it refuses automated downloads: the
icon page answers 403 and the asset CDN does not resolve from every network. A
copy of the icon can still be saved from the browser as a 512x512 bilevel PNG,
which is a flat silhouette of exactly the shapes the SVG draws — no colour, no
gradient, no stroke to lose. That is enough to recover the outlines.

This is potrace's job, done small: find the boundary between shape and
background, walk it, and simplify it. The boundary between two pixels is
resolved, so the trace follows the artwork's own edges instead of guessing
them, and every point after simplification is still on that boundary.

Usage:

    tools/png2svg.py artwork.png > assets/icon.svg

Then:

    tools/svg2qml.py --flatten assets/icon.svg > assets/icon.js

Options:

    --epsilon 0.6   how far a simplified point may stray from the real edge,
                    in pixels of the source image. Lower is truer and larger.
    --min-area 8    contours smaller than this many square pixels are noise.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from typing import Iterable

Point = tuple[int, int]


def read_mask(path: str, threshold: float = 50.0) -> tuple[bytearray, int, int]:
    """Return (mask, width, height) where mask[y * width + x] is 1 inside the shape.

    The shape is taken from the alpha channel: icon artwork is one colour on a
    transparent ground, and alpha is what separates the two no matter which
    colour was used.
    """
    raw = subprocess.run(
        [
            "magick", path,
            "-alpha", "extract",
            "-threshold", f"{threshold}%",
            "-depth", "8",
            "gray:-",
        ],
        capture_output=True,
        check=True,
    ).stdout

    geometry = subprocess.run(
        ["magick", "identify", "-format", "%w %h", path],
        capture_output=True,
        check=True,
        text=True,
    ).stdout.split()
    width, height = int(geometry[0]), int(geometry[1])
    if len(raw) != width * height:
        sys.exit(f"expected {width * height} mask bytes, got {len(raw)}")
    return bytearray(1 if value else 0 for value in raw), width, height


def boundary_edges(mask: bytearray, width: int, height: int) -> dict[Point, list[Point]]:
    """Every pixel edge that separates the shape from the background.

    Each edge is emitted in the direction that keeps the shape on its right, so
    a shape's outer ring and any hole inside it come out wound in opposite
    directions. That is what lets the fill rule be left alone later.
    """
    def filled(x: int, y: int) -> bool:
        return 0 <= x < width and 0 <= y < height and mask[y * width + x] == 1

    edges: dict[Point, list[Point]] = {}

    def add(start: Point, end: Point) -> None:
        edges.setdefault(start, []).append(end)

    for y in range(height):
        row = y * width
        for x in range(width):
            if not mask[row + x]:
                continue
            if not filled(x, y - 1):
                add((x, y), (x + 1, y))
            if not filled(x + 1, y):
                add((x + 1, y), (x + 1, y + 1))
            if not filled(x, y + 1):
                add((x + 1, y + 1), (x, y + 1))
            if not filled(x - 1, y):
                add((x, y + 1), (x, y))

    return edges


def trace_loops(edges: dict[Point, list[Point]]) -> list[list[Point]]:
    """Walk the boundary edges into closed loops.

    A point can carry two outgoing edges where the shape touches itself
    diagonally. Each is followed to its own end, so such a pinch becomes a
    contour that meets itself at a point rather than a single contour that has
    to guess which way round the corner is.
    """
    pending = {start: list(outs) for start, outs in edges.items()}
    loops: list[list[Point]] = []

    while pending:
        start = next(iter(pending))
        loop = [start]
        current = start
        while True:
            outs = pending.get(current)
            if not outs:
                break
            nxt = outs.pop()
            if not outs:
                del pending[current]
            if nxt == start:
                break
            loop.append(nxt)
            current = nxt
        if len(loop) > 2:
            loops.append(loop)

    return loops


def signed_area(loop: Iterable[Point]) -> float:
    """Twice the signed area: positive for a clockwise ring in screen coordinates."""
    points = list(loop)
    total = 0
    for (x0, y0), (x1, y1) in zip(points, points[1:] + points[:1]):
        total += x0 * y1 - x1 * y0
    return total / 2.0


def perpendicular_distance(point: Point, start: Point, end: Point) -> float:
    px, py = point
    ax, ay = start
    bx, by = end
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return ((px - ax) ** 2 + (py - ay) ** 2) ** 0.5
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return ((px - ax - t * dx) ** 2 + (py - ay - t * dy) ** 2) ** 0.5


def simplify(loop: list[Point], epsilon: float) -> list[Point]:
    """Ramer-Douglas-Peucker: drop points that do not change the shape.

    Endpoints are kept, so a contour is still closed and still passes through
    the corners the artwork actually has.
    """
    if len(loop) < 3:
        return loop

    keep = [False] * len(loop)
    keep[0] = keep[-1] = True
    stack = [(0, len(loop) - 1)]

    while stack:
        first, last = stack.pop()
        if last <= first + 1:
            continue
        worst_index = -1
        worst = 0.0
        for index in range(first + 1, last):
            distance = perpendicular_distance(loop[index], loop[first], loop[last])
            if distance > worst:
                worst = distance
                worst_index = index
        if worst > epsilon and worst_index > 0:
            keep[worst_index] = True
            stack.append((first, worst_index))
            stack.append((worst_index, last))

    return [point for point, wanted in zip(loop, keep) if wanted]


def format_path(loops: list[list[Point]], box: int) -> str:
    parts = []
    for loop in loops:
        points = " ".join(f"{x:g},{y:g}" for x, y in loop)
        parts.append(f"M{points}Z")
    return "".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("png", help="monochrome icon PNG")
    parser.add_argument("--epsilon", type=float, default=0.6,
                        help="simplification tolerance in source pixels")
    parser.add_argument("--min-area", type=float, default=8.0,
                        help="discard contours smaller than this many square pixels")
    args = parser.parse_args()

    mask, width, height = read_mask(args.png)
    filled_pixels = sum(mask)
    if filled_pixels == 0:
        sys.exit("the mask is empty: the image has no opaque shape to trace")

    loops = trace_loops(boundary_edges(mask, width, height))
    kept = [loop for loop in loops if abs(signed_area(loop)) >= args.min_area]
    simplified = [simplify(loop, args.epsilon) for loop in kept]

    box = max(width, height)
    # XML comments, not // ones: this file is parsed as XML. An XML comment
    # also may not contain a double hyphen anywhere, not even inside the
    # command that regenerates this file, or the document stops parsing.
    print(f"<!-- Traced from {args.png} by tools/png2svg.py.")
    print("     Flaticon serves this artwork as an SVG but blocks automated")
    print("     downloads, so the outlines were recovered from a saved PNG instead.")
    print("     Regenerate the bar icon data with tools/svg2qml.py in flatten mode. -->")
    print(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {box} {box}">')
    print(f'  <path d="{format_path(simplified, box)}"/>')
    print("</svg>")

    print(
        f"{filled_pixels} filled pixels, {len(loops)} contours, "
        f"{sum(len(loop) for loop in simplified)} points",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
