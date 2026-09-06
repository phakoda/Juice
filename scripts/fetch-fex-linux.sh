#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
SOURCE="${JUICE_FEX_SOURCE:-$ROOT/build/fex-source}"
PATCH="$ROOT/patches/fex-juice-ios.patch"
STIKDEBUG_PATCH="$ROOT/patches/fex-stikdebug-jit.patch"
LIFECYCLE_PATCH="$ROOT/patches/fex-stikdebug-lifecycle.patch"
VALIDATION_PATCH="$ROOT/patches/fex-stikdebug-validation.patch"
CODEGEN_PATCH="$ROOT/patches/fex-juice-codegen.patch"
RPMALLOC_PATCH="$ROOT/patches/fex-rpmalloc-juice-ios.patch"
test "$(uname -s)" = Linux || { echo 'FEX source preparation requires Linux.' >&2; exit 2; }
case "$SOURCE" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || { echo "Refusing external FEX source: $SOURCE" >&2; exit 2; };;
esac
if test ! -d "$SOURCE/.git"; then
  if test -d "$SOURCE" && test -n "$(find "$SOURCE" -mindepth 1 -print -quit)"; then
    echo 'Refusing nonempty non-Git FEX source.' >&2; exit 3
  fi
  mkdir -p "$SOURCE"
  git -C "$SOURCE" init
  git -C "$SOURCE" remote add origin "$JUICE_FEX_REPOSITORY"
fi
test "$(git -C "$SOURCE" remote get-url origin)" = "$JUICE_FEX_REPOSITORY" || { echo 'Unexpected FEX origin.' >&2; exit 3; }
head="$(git -C "$SOURCE" rev-parse HEAD 2>/dev/null || true)"
if test "$head" != "$JUICE_FEX_REVISION"; then
  test -z "$(git -C "$SOURCE" status --porcelain)" || { echo 'FEX has local changes at another revision.' >&2; exit 3; }
  git -C "$SOURCE" fetch --depth 1 origin "$JUICE_FEX_REVISION"
  git -C "$SOURCE" checkout --detach FETCH_HEAD
fi
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$JUICE_FEX_REVISION"
git -C "$SOURCE" submodule update --init --recursive --depth 1
RPMALLOC_SOURCE="$SOURCE/External/rpmalloc"
test "$(git -C "$RPMALLOC_SOURCE" rev-parse HEAD)" = "$JUICE_FEX_RPMALLOC_REVISION"
# Apply the base only to a clean base-shaped tree. A later codegen overlay
# overlaps the base, so reversing just the base is not a valid reuse check.
# The complete-prefix verifier below rejects partial or unrecognized layers.
if git -C "$SOURCE" apply --check "$PATCH" 2>/dev/null; then
  git -C "$SOURCE" apply "$PATCH"
fi
applied="$(python3 "$ROOT/scripts/verify-patch-stack.py" "$SOURCE" "$PATCH" --optional \
  "$STIKDEBUG_PATCH" "$LIFECYCLE_PATCH" "$VALIDATION_PATCH" "$CODEGEN_PATCH" --applied-count)"
patches=("$STIKDEBUG_PATCH" "$LIFECYCLE_PATCH" "$VALIDATION_PATCH" "$CODEGEN_PATCH")
for ((index=applied;index<${#patches[@]};index++)); do
  git -C "$SOURCE" apply --recount --check "${patches[$index]}"
  git -C "$SOURCE" apply --recount "${patches[$index]}"
done
if ! git -C "$RPMALLOC_SOURCE" apply --reverse --check "$RPMALLOC_PATCH" 2>/dev/null; then
  git -C "$RPMALLOC_SOURCE" apply --check "$RPMALLOC_PATCH"
  git -C "$RPMALLOC_SOURCE" apply "$RPMALLOC_PATCH"
fi
bash "$ROOT/scripts/verify-fex-patch.sh"
echo "JUICE_FEX_SOURCE_OK path=$SOURCE revision=$JUICE_FEX_REVISION stikdebug_jit=1 lifecycle=1 validation=1 codegen=1"
