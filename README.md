# service-asset
command and query service jar files for ui developer
lightapi and signin ui asset for full stack developer



```
./importer.sh --filename events.json

```

## Rust importer

Use `importer-rust.sh` to run the Rust event importer binary bundled under
`rust/linux/importer`. On macOS Apple Silicon, place the binary at
`rust/macos/importer` before using the same wrapper.

```bash
./importer-rust.sh --filename events.json
```

For offline validation:

```bash
./importer-rust.sh --filename events.json --dry-run
```

For database imports, set `DATABASE_URL` before running the script:

```bash
export DATABASE_URL=postgres://postgres:secret@localhost:5432/configserver
./importer-rust.sh --filename events.json
```

To use a binary outside this repository:

```bash
IMPORTER_BIN=/path/to/importer ./importer-rust.sh --help
```
