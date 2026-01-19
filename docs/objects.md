# objects

PDF object types and serialization

PDF files consist of numbered objects in the format:
`n 0 obj ... endobj`

Objects can be: booleans, integers, reals, strings, names,
arrays, dictionaries, streams, and null.

## Structs

### `Array`

PDF Array

```zig
pub const Array = struct {
    items: std.ArrayListUnmanaged(Value),
    allocator: std.mem.Allocator
}
```

#### `append`

```zig
pub fn append(self: *Array, value: Value) !void
```

#### `deinit`

```zig
pub fn deinit(self: *Array) void
```

#### `format`

```zig
pub fn format(self: Array, writer: anytype) @TypeOf(writer).Error!void
```

#### `init`

```zig
pub fn init(allocator: std.mem.Allocator) Array
```

### `Dict`

PDF Dictionary

```zig
pub const Dict = struct {
    entries: std.ArrayListUnmanaged(Entry),
    allocator: std.mem.Allocator,

    pub const Entry = struct {
        key: Name,
        value: Value,
    };
}
```

#### `deinit`

```zig
pub fn deinit(self: *Dict) void
```

#### `format`

```zig
pub fn format(self: Dict, writer: anytype) @TypeOf(writer).Error!void
```

#### `init`

```zig
pub fn init(allocator: std.mem.Allocator) Dict
```

#### `put`

```zig
pub fn put(self: *Dict, key: []const u8, value: Value) !void
```

### `Name`

PDF Name (e.g., /Type, /Page)

```zig
pub const Name = struct {
    value: []const u8
}
```

#### `format`

```zig
pub fn format(self: Name, writer: anytype) @TypeOf(writer).Error!void
```

### `ObjectIdAllocator`

Tracks object IDs for a document

```zig
pub const ObjectIdAllocator = struct {
    next_id: ObjectId = 1
}
```

#### `alloc`

```zig
pub fn alloc(self: *ObjectIdAllocator) ObjectId
```

#### `ref`

```zig
pub fn ref(self: *ObjectIdAllocator) Ref
```

### `Ref`

PDF Object reference (n 0 R)

```zig
pub const Ref = struct {
    id: ObjectId,
    gen: u16 = 0
}
```

#### `format`

```zig
pub fn format(self: Ref, writer: anytype) @TypeOf(writer).Error!void
```

## Unions

### `Value`

PDF Value (union of all value types)

```zig
pub const Value = union(enum) {
    null_val,
    bool_val: bool,
    int_val: i64,
    real_val: f64,
    string_val: []const u8,
    name_val: Name,
    array_val: *Array,
    dict_val: *Dict,
    ref_val: Ref,
    literal_val: []const u8
}
```

#### `format`

```zig
pub fn format(self: Value, writer: anytype) @TypeOf(writer).Error!void
```

#### `int`

```zig
pub fn int(i: i64) Value
```

#### `literal`

```zig
pub fn literal(s: []const u8) Value
```

#### `name`

```zig
pub fn name(n: []const u8) Value
```

#### `real`

```zig
pub fn real(r: f64) Value
```

#### `ref`

```zig
pub fn ref(r: Ref) Value
```

#### `string`

```zig
pub fn string(s: []const u8) Value
```

## Constants

### `ObjectId`

Object ID (the 'n' in 'n 0 obj')

```zig
pub const ObjectId = u32;
```

