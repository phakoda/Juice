#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="${JUICE_WINE_SOURCE:-$ROOT/wine}"
PATCH="$ROOT/patches/wine-stikdebug-jit.patch"

test -d "$SOURCE" || { echo "Missing Wine source tree: $SOURCE" >&2; exit 2; }
test -s "$PATCH" || { echo "Missing Wine StikDebug JIT patch: $PATCH" >&2; exit 2; }

if git -C "$ROOT" apply --reverse --check --directory="${SOURCE#$ROOT/}" "$PATCH" 2>/dev/null; then
  echo "JUICE_WINE_STIKDEBUG_PATCH_REUSE path=$SOURCE"
  exit 0
fi

git -C "$ROOT" apply --check --directory="${SOURCE#$ROOT/}" "$PATCH"
git -C "$ROOT" apply --directory="${SOURCE#$ROOT/}" "$PATCH"
echo "JUICE_WINE_STIKDEBUG_PATCH_OK path=$SOURCE"
