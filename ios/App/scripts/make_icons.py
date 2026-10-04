#!/usr/bin/env python3
"""Renders the app icon in each theme color (Resources/Assets.xcassets).

The design: a soft vertical gradient in the theme color, a frosted circle,
and the two white four-point stars. AppIcon is the default theme (洋红);
AppIcon-<key> are the alternate icons that follow the theme picked in
设置 → 主题色. Keep the colors in sync with Sources/Support/Theme.swift.

    python3 ios/App/scripts/make_icons.py
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

# key: light-mode theme color (Theme.swift)
THEMES = {
    "magenta": "#D156A7",
    "orchid": "#A84FD0",
    "rose": "#DE4A7C",
    "berry": "#A3307F",
    "blue": "#2F6FE0",
    "violet": "#6E4BD8",
    "teal": "#0F8F84",
    "orange": "#EC7355",
    "graphite": "#4A5260",
}
DEFAULT = "magenta"
SIZE, SS = 1024, 4  # supersampled for smooth edges
ASSETS = os.path.join(os.path.dirname(__file__), "..", "Resources", "Assets.xcassets")


def rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def star(cx, cy, r, waist):
    return [(cx, cy - r), (cx + waist, cy - waist), (cx + r, cy), (cx + waist, cy + waist),
            (cx, cy + r), (cx - waist, cy + waist), (cx - r, cy), (cx - waist, cy - waist)]


def render(color):
    n = SIZE * SS
    base = rgb(color)
    top, bottom = mix(base, (255, 255, 255), 0.30), mix(base, (0, 0, 0), 0.06)
    img = Image.new("RGB", (n, n))
    px = ImageDraw.Draw(img)
    for y in range(n):
        px.line([(0, y), (n, y)], fill=mix(top, bottom, y / (n - 1)))
    s = lambda v: v * SS
    # soft shadow ring, then the frosted circle
    shade = Image.new("L", (n, n), 0)
    ImageDraw.Draw(shade).ellipse([s(212), s(212), s(812), s(812)], fill=60)
    shade = shade.filter(ImageFilter.GaussianBlur(s(6)))
    img.paste(mix(base, (0, 0, 0), 0.25), mask=shade)
    glass = Image.new("L", (n, n), 0)
    ImageDraw.Draw(glass).ellipse([s(216), s(216), s(808), s(808)], fill=78)
    glass = glass.filter(ImageFilter.GaussianBlur(s(3)))
    img.paste((255, 255, 255), mask=glass)
    d = ImageDraw.Draw(img)
    d.polygon([(s(x), s(y)) for x, y in star(512, 520, 251, 45)], fill=(255, 255, 255))
    d.polygon([(s(x), s(y)) for x, y in star(720, 330, 91, 16)], fill=(255, 255, 255))
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def write_set(name, color):
    folder = os.path.join(ASSETS, f"{name}.appiconset")
    os.makedirs(folder, exist_ok=True)
    render(color).save(os.path.join(folder, "icon-1024.png"))
    contents = {
        "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)


if __name__ == "__main__":
    write_set("AppIcon", THEMES[DEFAULT])
    for key, color in THEMES.items():
        if key != DEFAULT:
            write_set(f"AppIcon-{key}", color)
    print("wrote", len(THEMES), "icon sets")
