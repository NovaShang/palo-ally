#!/usr/bin/env python3
"""Inline site/index.html's assets into one file, site/preview.html.

Used to preview the page as a single self-contained HTML file (e.g. a private
claude.ai Artifact). The published site uses index.html + assets/ as is.
"""
import base64
import pathlib
import re

here = pathlib.Path(__file__).parent
html = (here / "index.html").read_text(encoding="utf-8")


def asset(name: str) -> str:
    return (here / "assets" / name).read_text(encoding="utf-8")


svg = base64.b64encode((here / "assets" / "favicon.svg").read_bytes()).decode()
favicon = f"data:image/svg+xml;base64,{svg}"

css = asset("site.css").replace("url(favicon.svg)", f'url("{favicon}")')
html = html.replace('<link rel="stylesheet" href="assets/site.css">', f"<style>\n{css}\n</style>")
for js in ("drops.js", "site.js"):
    code = asset(js).replace("</", "<\\/")
    html = html.replace(f'<script src="assets/{js}"></script>', f"<script>\n{code}\n</script>")
html = html.replace('href="assets/favicon.svg"', f'href="{favicon}"')
html = html.replace('src="assets/favicon.svg"', f'src="{favicon}"')

leftover = re.findall(r'(?:src|href)="assets/[^"]+"', html)
assert not leftover, leftover
(here / "preview.html").write_text(html, encoding="utf-8")
print(f"preview.html: {len(html.encode()) / 1024:.0f} KB")
