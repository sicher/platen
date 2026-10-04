# Fast PDF rendering library

We are going to write a library for creating PDF documents. It is supposed to be used by applications that need to produce PDF document output, but a command line tool should be provided for testing the library functionality.

The library is a low level library. It should be stateless.

All code should be written in Zig 0.17. It should be self contained. Users clone the repo and build, nothing more!

## Session start

- Read context.md (first 50 lines if it grown large)
- Use the File connector to read files.
- Confirm: current focus, any open issues, files of interest

## Tools

https://git.urverk.org/urverk/simgrep

for searching for code duplications! Use the --min-lines=N and --min-clones=M arguments to tailor searches.

https://git.urverk.org/urverk/zigmap

for generating codemaps!

Make sure both of these tools are locally available in this project!

If you need additional tools, MAKE SURE you install them local to the project. NEVER install global tool unless it's specifically allowed.

Check what's already installed in the local .venv python environment, like fonttools.

## Refactoring

If doing refactoring, start by running "zigmap" and "simgrep" to get good overview data before digging into details.

## Testing

- If a test fails. Never EVER do a "quick fix" to get the test to pass. ALWAYS investigate the cause of the fail, and investigate THOROUGHLY!!!

- If possible, generate REFERENCE pdf:s with the python fpdf2 library, then integration tests that generate the same with platen and compares them.

- Make sure to keep a command line tool up to date, allowing access to all library innards so they can be tested!

- Make sure to add proper tests, both unit tests and integration tests. If you have to manually test something, it should likely be part of the test suite.

- NEVER, EVER mask failed test results with increased test tolerance!!!!!

## Pairing rules

- One change at the time, verify before continuing
- When in doubt, ask rather than assume

## Token Efficiency

- Use codemaps!
- List directories before reading files
- Search before reading - locate, do not guess
- Use read_multiple_files for batched reads
- Ask which files matter rather than reading speculatively.
- Keep source files sufficiently small so it’s efficient to read and search them

## Session end

- Update context.md: What we did, whats next and new decisions
- Update DESIGN.md with any relevant stuff done or changed. Write down things that may be needed for reference moving forward.
- Keep it lean - prune old sessions that are no longer relevant
