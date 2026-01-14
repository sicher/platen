# PDF rendering library

## Architecture

### Modules
- `zpdf.zig` - Main library entry, Document API
- `objects.zig` - PDF object types (Dict, Array, Value, Ref, Name)
- `writer.zig` - PDF serialization (header, objects, xref, trailer)
- `cli.zig` - Command line tool

### PDF Structure
Objects are numbered sequentially starting at 1:
- Object 1: Catalog (root)
- Object 2: Pages (page tree root)
- Object 3+: Pages (2 objects each: page dict + content stream)

### Memory Management
Uses `ArrayListUnmanaged` throughout - allocator passed to each operation.
`Document.output()` returns owned memory that caller must free.

## Zig 0.15 Compatibility Notes

The project targets Zig 0.15 which has significant API changes from earlier versions:

- **I/O**: Uses new buffered `File.Reader` and `File.Writer` with explicit buffer parameters
- **ArrayListUnmanaged**: Allocator passed to each method, not stored
- **XML**: No `std.xml` - we implement our own simple XML parser if needed
- **ZIP**: `std.zip` exists but with lower-level API; MXL support pending

