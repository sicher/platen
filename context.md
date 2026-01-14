# zpdf Context

## Current Focus
Minimal PDF generation is working. Next: add text/font support.

## What We Did (Session 2026-01-14)
- Set up project structure with simgrep/zigmap as git submodules in `tools/`
- Created PDF object types: `ObjectId`, `Ref`, `Name`, `Dict`, `Array`, `Value`
- Implemented PDF writer with header, object serialization, xref, trailer
- Built Document struct with page support and output method
- CLI tool with `test` command to generate minimal PDFs
- Verified output opens in Preview and validates with pdfinfo

## Files of Interest
- `src/zpdf.zig` - Main library, Document struct
- `src/objects.zig` - PDF object types
- `src/writer.zig` - PDF serialization
- `src/cli.zig` - Command line tool

## Open Issues
- None currently

## Next Steps
1. Add text rendering (content stream operators)
2. Add built-in PDF fonts (Helvetica, Times, Courier, etc.)
3. Port tests from fpdf2
