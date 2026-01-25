#!/usr/bin/env python3
"""Extract public API from document.zig and update README.md API Reference.

Descriptions are extracted from /// doc comments in the source.
Categories are determined by method name prefixes.
"""

import re
from pathlib import Path

# Methods to exclude from docs (internal use only)
EXCLUDE_METHODS = {
    'renderPageCommands',  # Internal
    'findSoftHyphenBreak', 'findHyphenBreak',  # Internal helpers
    'name', 'print', 'hasAnyField',  # Methods on other structs (FontHandle, ContentWriter, DocumentMetadata)
}

# Category rules: (prefix_or_name, category)
# Order matters - first match wins
CATEGORY_RULES = [
    # Exact matches first
    (['init', 'deinit', 'output'], 'Core'),
    (['getPageIndex', 'pageCount', 'addPage', 'insertPage', 'selectPage',
      'setMetadata', 'getPageRegion'], 'Document'),
    (['loadFont', 'setFont', 'setEmbeddedFont', 'setFeature',
      'setFontFeature', 'getFontMetrics', 'getTextStyle'], 'Fonts'),
    (['write', 'writeStyled', 'writeFlow', 'writeAt',
      'measureText', 'measureTextWidth', 'getTextWidth', 'measureWrappedText',
      'drawRegion'], 'Text'),
    (['setTextColor', 'setTextStyle', 'setCharSpacing', 'setLineHeight', 'getLineHeightPts'], 'Text Styling'),
    (['setPosition', 'getPosition'], 'Cursor Position'),
    (['currentDestination', 'addLink', 'addExternalLink',
      'addOutlineItem', 'setPageLabel'], 'Navigation'),
    (['loadImage', 'drawImage', 'loadSvg', 'drawSvg'], 'Images & SVG'),
    (['setDrawStyle', 'createPath'], 'Graphics'),
]

# Prefix-based fallback categories
PREFIX_CATEGORIES = {
    'draw': 'Graphics',
    'add': 'Gradients',  # addLinearGradient, addRadialGradient
    'fill': 'Gradients',
}


def extract_methods(source_path: Path) -> dict[str, tuple[str, str]]:
    """Extract pub fn methods with their signatures and doc comments from Document struct.

    Returns dict mapping method name to (signature, description).
    """
    content = source_path.read_text()

    # Pattern: optional doc comment(s), then full pub fn signature
    # Doc comments are /// lines immediately before the function
    # Match both `self` methods and `init(allocator)` constructor
    pattern = r'((?:\s*///[^\n]*\n)+)?\s*pub fn (\w+)\(((?:self|allocator)[^)]*)\)([^{]*)'

    methods = {}
    for match in re.finditer(pattern, content):
        doc_comment = match.group(1)
        name = match.group(2)
        params = match.group(3)
        return_part = match.group(4).strip()

        if name in EXCLUDE_METHODS:
            continue

        # Build signature
        signature = format_signature(name, params, return_part)

        # Extract first line of doc comment as description
        if doc_comment:
            # Get first /// line, strip /// and whitespace
            lines = doc_comment.strip().split('\n')
            first_line = lines[0].replace('///', '').strip()
            # Remove trailing period for consistency
            description = first_line.rstrip('.')
        else:
            description = f'TODO: add doc comment for {name}'

        methods[name] = (signature, description)

    return methods


def format_signature(name: str, params: str, return_part: str) -> str:
    """Format a method signature for display in docs."""
    # Parse parameters (skip self, simplify types)
    param_list = []
    for param in params.split(','):
        param = param.strip()
        if param in ('self', 'self: *Document', 'self: *const Document'):
            continue
        if param.startswith('allocator'):
            param_list.append('allocator')
            continue
        # Extract param name and simplify type
        if ':' in param:
            pname, ptype = param.split(':', 1)
            pname = pname.strip()
            ptype = ptype.strip()
            # Simplify common types
            ptype = simplify_type(ptype)
            param_list.append(f'{ptype}' if ptype else pname)

    # Parse return type
    ret_type = ''
    if return_part:
        # Handle "!Type" (error union) and "Type"
        return_part = return_part.lstrip('!')
        if return_part and return_part != 'void':
            ret_type = simplify_type(return_part)

    # Build signature string
    params_str = ', '.join(param_list)
    if ret_type:
        return f'{name}({params_str}) -> {ret_type}'
    else:
        return f'{name}({params_str})'


def simplify_type(t: str) -> str:
    """Simplify a Zig type for documentation."""
    t = t.strip()
    # Remove module prefixes
    if '.' in t and not t.startswith('*'):
        t = t.split('.')[-1]
    # Handle pointers
    if t.startswith('*const '):
        inner = t[7:]
        if '.' in inner:
            inner = inner.split('.')[-1]
        return f'*{inner}'
    if t.startswith('*'):
        inner = t[1:]
        if '.' in inner:
            inner = inner.split('.')[-1]
        return f'*{inner}'
    # Handle slices
    if t.startswith('[]const u8'):
        return 'str'
    if t.startswith('[]'):
        return t
    # Handle optionals
    if t.startswith('?'):
        inner = simplify_type(t[1:])
        return f'?{inner}'
    return t


def categorize_method(name: str) -> str:
    """Determine category for a method based on its name."""
    # Check explicit rules first
    for names, category in CATEGORY_RULES:
        if name in names:
            return category

    # Prefix-based fallback
    for prefix, category in PREFIX_CATEGORIES.items():
        if name.startswith(prefix):
            return category

    return 'Other'


def generate_api_reference(methods: dict[str, tuple[str, str]]) -> str:
    """Generate markdown API reference tables."""
    # Group methods by category
    categories: dict[str, list[tuple[str, str, str]]] = {}

    for name, (signature, desc) in methods.items():
        cat = categorize_method(name)
        if cat not in categories:
            categories[cat] = []
        categories[cat].append((name, signature, desc))

    # Define category order
    category_order = [
        'Core', 'Document', 'Fonts', 'Text', 'Text Styling',
        'Cursor Position', 'Navigation', 'Images & SVG', 'Graphics', 'Gradients', 'Other'
    ]

    lines = ['## API Reference']

    for category in category_order:
        if category not in categories:
            continue

        methods_in_cat = categories[category]
        # Sort methods within category
        methods_in_cat.sort(key=lambda x: x[0])

        lines.extend(['', f'### {category}', '', '| Method | Description |', '|--------|-------------|'])

        for name, signature, desc in methods_in_cat:
            lines.append(f'| `{signature}` | {desc} |')

    return '\n'.join(lines)


def update_readme(readme_path: Path, api_reference: str) -> None:
    """Replace API Reference section in README."""
    content = readme_path.read_text()

    # Find and replace API Reference section
    # It starts with "## API Reference" and ends before "## Requirements"
    pattern = r'## API Reference\n.*?(?=\n## Requirements)'

    replacement = api_reference + '\n\n'
    new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

    if new_content == content:
        print("Warning: Could not find API Reference section to replace")
        return

    readme_path.write_text(new_content)
    print(f"Updated {readme_path}")


def check_missing_docs(methods: dict[str, tuple[str, str]]) -> None:
    """Report methods missing doc comments."""
    missing = [name for name, (sig, desc) in methods.items() if desc.startswith('TODO:')]
    if missing:
        print(f"\nMethods missing doc comments:")
        for name in sorted(missing):
            print(f"  - {name}")


def main():
    root = Path(__file__).parent.parent
    source_path = root / 'src' / 'document.zig'
    readme_path = root / 'README.md'

    print(f"Extracting methods from {source_path}")
    methods = extract_methods(source_path)
    print(f"Found {len(methods)} public methods")

    check_missing_docs(methods)

    api_reference = generate_api_reference(methods)

    print(f"\nUpdating {readme_path}")
    update_readme(readme_path, api_reference)

    print("Done!")


if __name__ == '__main__':
    main()
