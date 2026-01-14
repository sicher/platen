# PDF rendering library

## Zig 0.15 Compatibility Notes

The project targets Zig 0.15 which has significant API changes from earlier versions:

- **I/O**: Uses new buffered `File.Reader` and `File.Writer` with explicit buffer parameters
- **XML**: No `std.xml` - we implement our own simple XML parser
- **ZIP**: `std.zip` exists but with lower-level API; MXL support pending

