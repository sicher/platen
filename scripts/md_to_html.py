#!/usr/bin/env python3
"""Convert markdown docs to static HTML."""

import markdown
from pathlib import Path

DOCS_DIR = Path("docs")

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{title} - zpdf API</title>
    <style>
        :root {{
            --bg: #fff;
            --fg: #222;
            --code-bg: #f5f5f5;
            --link: #0066cc;
            --border: #ddd;
        }}
        @media (prefers-color-scheme: dark) {{
            :root {{
                --bg: #1a1a1a;
                --fg: #e0e0e0;
                --code-bg: #2d2d2d;
                --link: #6db3f2;
                --border: #444;
            }}
        }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            line-height: 1.6;
            max-width: 900px;
            margin: 0 auto;
            padding: 2rem;
            background: var(--bg);
            color: var(--fg);
        }}
        nav {{
            margin-bottom: 2rem;
            padding-bottom: 1rem;
            border-bottom: 1px solid var(--border);
        }}
        nav a {{
            margin-right: 1rem;
            color: var(--link);
            text-decoration: none;
        }}
        nav a:hover {{
            text-decoration: underline;
        }}
        h1, h2, h3 {{
            margin-top: 2rem;
        }}
        h1 {{
            border-bottom: 2px solid var(--border);
            padding-bottom: 0.5rem;
        }}
        code {{
            font-family: "SF Mono", Consolas, monospace;
            font-size: 0.9em;
            background: var(--code-bg);
            padding: 0.2em 0.4em;
            border-radius: 3px;
        }}
        pre {{
            background: var(--code-bg);
            padding: 1rem;
            overflow-x: auto;
            border-radius: 5px;
        }}
        pre code {{
            padding: 0;
            background: none;
        }}
        table {{
            border-collapse: collapse;
            width: 100%;
            margin: 1rem 0;
        }}
        th, td {{
            border: 1px solid var(--border);
            padding: 0.5rem;
            text-align: left;
        }}
        th {{
            background: var(--code-bg);
        }}
        a {{
            color: var(--link);
        }}
    </style>
</head>
<body>
    <nav>
        <strong>zpdf API:</strong>
        <a href="index.html">Index</a>
        <a href="zpdf.html">zpdf</a>
        <a href="embedded.html">embedded</a>
        <a href="fonts.html">fonts</a>
        <a href="metrics.html">metrics</a>
        <a href="objects.html">objects</a>
        <a href="writer.html">writer</a>
    </nav>
    {content}
</body>
</html>
"""

def convert_file(md_path: Path):
    """Convert a markdown file to HTML."""
    content = md_path.read_text()
    html_content = markdown.markdown(
        content,
        extensions=["fenced_code", "tables", "toc"]
    )
    title = md_path.stem
    html = HTML_TEMPLATE.format(title=title, content=html_content)

    html_path = md_path.with_suffix(".html")
    html_path.write_text(html)
    print(f"  {html_path}")

def generate_index():
    """Generate index.html with links to all modules."""
    modules = [
        ("zpdf", "Main module - PDF document creation"),
        ("embedded", "Embedded font handling (TTF/OTF)"),
        ("fonts", "Standard PDF fonts"),
        ("metrics", "Text metrics and measurement"),
        ("objects", "PDF object types"),
        ("writer", "Low-level PDF writer"),
    ]

    content = "<h1>zpdf API Documentation</h1>\n"
    content += "<p>Fast PDF rendering library for Zig</p>\n"
    content += "<h2>Modules</h2>\n<ul>\n"
    for name, desc in modules:
        content += f'<li><a href="{name}.html"><code>{name}</code></a> - {desc}</li>\n'
    content += "</ul>\n"

    html = HTML_TEMPLATE.format(title="Index", content=content)
    (DOCS_DIR / "index.html").write_text(html)
    print("  docs/index.html")

def main():
    for md_file in DOCS_DIR.glob("*.md"):
        convert_file(md_file)
    generate_index()

if __name__ == "__main__":
    main()
