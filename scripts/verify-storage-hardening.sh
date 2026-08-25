#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT/app/JuiceStoragePaths.m"

test -f "$SOURCE" || { echo "Missing app/JuiceStoragePaths.m" >&2; exit 2; }
grep -Fq 'app/JuiceStoragePaths.m' "$ROOT/scripts/build-app.sh"
grep -Fq 'constructor(150)' "$SOURCE"
grep -Fq 'NSSearchPathForDirectoriesInDomains(NSDocumentDirectory' "$SOURCE"
grep -Fq 'access(legacy.fileSystemRepresentation, W_OK)' "$SOURCE"
grep -Fq 'NSTemporaryDirectory()' "$SOURCE"
grep -Fq 'DISPLAY_SOCKET path=' "$SOURCE"
grep -Fq 'CONTROL_V1_SOCKET path=' "$SOURCE"
grep -Fq 'storage_root=' "$SOURCE"
grep -Fq 'documentPicker:didPickDocumentsAtURLs:' "$SOURCE"
grep -Fq 'importPortableZipFromLocalPath:' "$SOURCE"
grep -Fq 'WINEDLLPATH=' "$SOURCE"

echo "JUICE_STORAGE_HARDENING_VERIFY_OK"
