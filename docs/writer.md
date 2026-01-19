# writer

PDF Writer

Handles serializing PDF structure to a byte stream:
- Header with version and binary marker
- Objects with tracking of byte offsets
- Cross-reference table
- Trailer

## Structs

### `Writer`

PDF Writer - serializes PDF structure to output

```zig
pub const Writer = struct {
    output: std.ArrayListUnmanaged(u8),
    offsets: std.ArrayListUnmanaged(ObjectOffset),
    allocator: std.mem.Allocator
}
```

#### `beginObject`

Begin an object and record its offset

```zig
pub fn beginObject(self: *Writer, id: ObjectId) !void
```

#### `deinit`

```zig
pub fn deinit(self: *Writer) void
```

#### `endObject`

End an object

```zig
pub fn endObject(self: *Writer) !void
```

#### `finish`

Write xref table and trailer, return the final PDF bytes
Caller owns the returned memory

```zig
pub fn finish(self: *Writer, catalog_ref: Ref) ![]u8
```

#### `init`

```zig
pub fn init(allocator: std.mem.Allocator) Writer
```

#### `pos`

Get current byte position

```zig
pub fn pos(self: *Writer) u64
```

#### `writeDict`

Write a dictionary as the object content

```zig
pub fn writeDict(self: *Writer, dict: Dict) !void
```

#### `writeHeader`

Write PDF header with binary marker

```zig
pub fn writeHeader(self: *Writer) !void
```

#### `writeStream`

Write a stream object (dictionary + stream data)

```zig
pub fn writeStream(self: *Writer, dict: *Dict, data: []const u8) !void
```

#### `writeStreamCompressed`

Write a compressed stream object using FlateDecode (zlib)
Compresses the data and adds appropriate Filter entry to dict

```zig
pub fn writeStreamCompressed(self: *Writer, dict: *Dict, data: []const u8) !void
```

## Constants

### `PDF_VERSION`

```zig
pub const PDF_VERSION = "1.4";
```

