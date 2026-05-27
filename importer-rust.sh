#!/usr/bin/env bash
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${IMPORTER_BIN:-}" ]]; then
  IMPORTER="$IMPORTER_BIN"
else
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}:${arch}" in
    Linux:x86_64 | Linux:amd64)
      IMPORTER="${CURRENT_DIR}/rust/linux/importer"
      ;;
    Darwin:arm64 | Darwin:aarch64)
      IMPORTER="${CURRENT_DIR}/rust/macos/importer"
      ;;
    *)
      echo "Unsupported platform for bundled Rust importer: ${os}/${arch}" >&2
      echo "Set IMPORTER_BIN=/path/to/importer to use a custom binary." >&2
      exit 1
      ;;
  esac
fi

if [[ ! -x "$IMPORTER" ]]; then
  echo "Rust importer binary cannot be found or is not executable: $IMPORTER" >&2
  echo "Expected binary at: $IMPORTER" >&2
  exit 1
fi

exec "$IMPORTER" "$@"
