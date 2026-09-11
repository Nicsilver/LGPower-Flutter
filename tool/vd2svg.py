#!/usr/bin/env python
"""Converts Android VectorDrawable XML (res/drawable/ic_*.xml) to SVG.

VectorDrawable pathData is already SVG-path-data compatible, so this only
remaps the surrounding attribute names/namespaces and expands Android's
ARGB colour format (SVG has no #AARRGGBB; alpha becomes fill-/stroke-opacity).

Usage: python tool/vd2svg.py <src-drawable-dir> <dst-icons-dir>
"""

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ANDROID_NS = "http://schemas.android.com/apk/res/android"

# Not a real vector (a <shape> solid fill) — nothing to convert.
SKIP = {"ic_launcher_background.xml"}
# Kept for the adaptive-icon foreground layer, not a UI icon like the rest.
RENAME = {"ic_launcher_foreground.xml": "launcher_foreground.svg"}


def a(el: ET.Element, name: str) -> str | None:
    return el.get(f"{{{ANDROID_NS}}}{name}")


def fnum(v: float) -> str:
    if v == int(v):
        return str(int(v))
    return f"{v:.6f}".rstrip("0").rstrip(".")


def convert_color(value: str | None) -> tuple[str | None, float | None]:
    """Returns (svg color-or-None, opacity-or-None)."""
    if value is None:
        return None, None
    v = value.strip()
    if v.startswith("@"):
        # This icon set only ever references @android:color/transparent; any
        # other resource/theme reference has no static SVG equivalent, so it
        # is left themeable via currentColor instead.
        return ("none", None) if v.endswith("transparent") else ("currentColor", None)
    if v.startswith("?"):
        return "currentColor", None
    if v.startswith("#"):
        hex_part = v[1:]
        if len(hex_part) == 3:
            hex_part = "".join(ch * 2 for ch in hex_part)
        if len(hex_part) == 8:
            alpha = int(hex_part[0:2], 16)
            rgb = hex_part[2:]
            return f"#{rgb}", (None if alpha == 255 else round(alpha / 255, 3))
        return f"#{hex_part}", None
    return v, None


def convert_path(el: ET.Element) -> str:
    # Multi-line pathData (used for readability in the source XML) is still
    # valid SVG, but collapse it so the output isn't full of raw newlines.
    path_data = " ".join((a(el, "pathData") or "").split())
    attrs = {"d": path_data}

    fill, fill_op = convert_color(a(el, "fillColor"))
    # Android draws no fill at all when fillColor is omitted.
    attrs["fill"] = fill or "none"
    if fill_op is not None:
        attrs["fill-opacity"] = fnum(fill_op)

    stroke, stroke_op = convert_color(a(el, "strokeColor"))
    if stroke is not None:
        attrs["stroke"] = stroke
        if stroke_op is not None:
            attrs["stroke-opacity"] = fnum(stroke_op)

    width = a(el, "strokeWidth")
    if width is not None:
        attrs["stroke-width"] = width
    cap = a(el, "strokeLineCap")
    if cap is not None:
        attrs["stroke-linecap"] = cap
    join = a(el, "strokeLineJoin")
    if join is not None:
        attrs["stroke-linejoin"] = join
    fill_type = a(el, "fillType")
    if fill_type is not None:
        attrs["fill-rule"] = fill_type.lower()

    attr_str = " ".join(f'{k}="{v}"' for k, v in attrs.items())
    return f"<path {attr_str} />"


def group_transform(el: ET.Element) -> str | None:
    def f(name: str, default: float) -> float:
        v = a(el, name)
        return float(v) if v is not None else default

    rotation = f("rotation", 0.0)
    pivot_x, pivot_y = f("pivotX", 0.0), f("pivotY", 0.0)
    translate_x, translate_y = f("translateX", 0.0), f("translateY", 0.0)
    scale_x, scale_y = f("scaleX", 1.0), f("scaleY", 1.0)

    # Mirrors VGroup.updateLocalMatrix: translate(-pivot) -> scale -> rotate
    # -> translate(pivot + translate), read right-to-left as SVG transform lists.
    parts = []
    tx, ty = pivot_x + translate_x, pivot_y + translate_y
    if tx or ty:
        parts.append(f"translate({fnum(tx)},{fnum(ty)})")
    if rotation:
        parts.append(f"rotate({fnum(rotation)})")
    if scale_x != 1 or scale_y != 1:
        parts.append(f"scale({fnum(scale_x)},{fnum(scale_y)})")
    if pivot_x or pivot_y:
        parts.append(f"translate({fnum(-pivot_x)},{fnum(-pivot_y)})")
    return " ".join(parts) if parts else None


def convert_children(el: ET.Element, indent: str) -> list[str]:
    lines = []
    for child in el:
        tag = child.tag.rsplit("}", 1)[-1]
        if tag == "path":
            lines.append(indent + convert_path(child))
        elif tag == "group":
            transform = group_transform(child)
            open_tag = f'<g transform="{transform}">' if transform else "<g>"
            lines.append(indent + open_tag)
            lines.extend(convert_children(child, indent + "  "))
            lines.append(indent + "</g>")
    return lines


def convert(src: Path) -> str:
    root = ET.parse(src).getroot()
    width = (a(root, "width") or "24dp").removesuffix("dp")
    height = (a(root, "height") or "24dp").removesuffix("dp")
    vp_w = a(root, "viewportWidth") or width
    vp_h = a(root, "viewportHeight") or height
    body = "\n".join(convert_children(root, "  "))
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {vp_w} {vp_h}">\n{body}\n</svg>\n'
    )


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: vd2svg.py <src-drawable-dir> <dst-icons-dir>")
        raise SystemExit(1)
    src_dir, dst_dir = Path(sys.argv[1]), Path(sys.argv[2])
    dst_dir.mkdir(parents=True, exist_ok=True)
    for src in sorted(src_dir.glob("ic_*.xml")):
        if src.name in SKIP:
            continue
        dst_name = RENAME.get(src.name, src.stem + ".svg")
        (dst_dir / dst_name).write_text(convert(src), encoding="utf-8", newline="\n")
        print(f"{src.name} -> {dst_name}")


if __name__ == "__main__":
    main()
