#!/bin/bash
# Generate API documentation using zigmarkdoc + convert to HTML
set -e

cd "$(dirname "$0")/.."

ZIGMARKDOC="tools/zigmarkdoc/zig-out/bin/zigmarkdoc"
DOCS_DIR="docs"

mkdir -p "$DOCS_DIR"

# Source files to document
SOURCES="src/zpdf.zig src/embedded.zig src/fonts.zig src/metrics.zig src/objects.zig src/writer.zig"

# Generate markdown for each module
for src in $SOURCES; do
    name=$(basename "$src" .zig)
    echo "Generating $DOCS_DIR/$name.md"
    "$ZIGMARKDOC" "$src" -o "$DOCS_DIR/$name.md"
done

# Convert markdown to HTML
echo "Converting to HTML..."
.venv/bin/python3 scripts/md_to_html.py

echo "Documentation generated in $DOCS_DIR/"
