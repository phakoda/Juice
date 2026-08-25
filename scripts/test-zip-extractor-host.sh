#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="${JUICE_ZIP_HOST_TEST_DIR:-$ROOT/build/zip-host-test}"
TEST="$WORK/JuiceZipTest"
CC="${CC:-$(xcrun --find clang)}"

rm -rf "$WORK"
mkdir -p "$WORK"

"$CC" -fobjc-arc -O2 -I"$ROOT/app" \
  "$ROOT/app/JuiceZip.m" "$ROOT/app/tests/ZipExtractorTests.m" \
  -framework Foundation -framework CoreFoundation -lz -o "$TEST"

python3 - "$WORK" <<'PY'
import pathlib
import struct
import sys
import zipfile
import zlib

root = pathlib.Path(sys.argv[1])

with zipfile.ZipFile(root / "portable.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("PortableGame.exe", b"MZ-portable-test")
    z.writestr("helper.dll", b"dependency")
    z.writestr("assets/settings.dat", b"settings")
    z.writestr("empty.dat", b"")
    z.comment = b"comment containing PK\x05\x06 but not an EOCD"

large_size = 48 * 1024 * 1024
with zipfile.ZipFile(root / "large.zip", "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    with z.open("large.bin", "w") as out:
        block = bytes(range(256)) * 4096
        for _ in range(large_size // len(block)):
            out.write(block)

with zipfile.ZipFile(root / "unsafe.zip", "w") as z:
    z.writestr("../escape.txt", b"must not escape")
with zipfile.ZipFile(root / "drive-path.zip", "w") as z:
    z.writestr("C:/escape.txt", b"must not escape")
with zipfile.ZipFile(root / "case-collision.zip", "w") as z:
    z.writestr("Readme.txt", b"first")
    z.writestr("README.TXT", b"second")
with zipfile.ZipFile(root / "directory-data.zip", "w") as z:
    z.writestr("folder/", b"unexpected-data")

with zipfile.ZipFile(root / "crc.zip", "w", zipfile.ZIP_STORED) as z:
    z.writestr("crc.bin", b"0123456789")
crc_data = bytearray((root / "crc.zip").read_bytes())
name_len, extra_len = struct.unpack_from("<HH", crc_data, 26)
payload = 30 + name_len + extra_len
crc_data[payload] ^= 0x20
(root / "bad-crc.zip").write_bytes(crc_data)

inconsistent = bytearray((root / "portable.zip").read_bytes())
struct.pack_into("<H", inconsistent, 8, 0)  # local method: stored; central: deflate
(root / "inconsistent.zip").write_bytes(inconsistent)

local_crc = bytearray((root / "portable.zip").read_bytes())
original_local_crc = struct.unpack_from("<I", local_crc, 14)[0]
struct.pack_into("<I", local_crc, 14, original_local_crc ^ 0x01020304)
(root / "local-crc-mismatch.zip").write_bytes(local_crc)


def minimal_stored(path, name, body):
    crc = zlib.crc32(body) & 0xffffffff
    local = struct.pack(
        "<IHHHHHIIIHH", 0x04034B50, 20, 0, 0, 0, 0,
        crc, len(body), len(body), len(name), 0,
    ) + name + body
    central = struct.pack(
        "<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 0, 0, 0, 0,
        crc, len(body), len(body), len(name), 0, 0,
        0, 0, 0, 0,
    ) + name
    eocd = struct.pack(
        "<IHHHHIIH", 0x06054B50, 0, 0, 1, 1, len(central), len(local), 0,
    )
    path.write_bytes(local + central + eocd)


minimal_stored(root / "cp437.zip", b"caf\x82.txt", b"legacy-name")
minimal_stored(root / "nul-path.zip", b"safe.txt\x00.exe", b"must-not-extract")
PY

rm -rf "$WORK"/output-* "$WORK/escape.txt"

"$TEST" "$WORK/portable.zip" "$WORK/output-portable"
test "$(cat "$WORK/output-portable/helper.dll")" = dependency
test -f "$WORK/output-portable/empty.dat"
test ! -s "$WORK/output-portable/empty.dat"

"$TEST" "$WORK/large.zip" "$WORK/output-large"
test "$(stat -f %z "$WORK/output-large/large.bin")" -eq $((48 * 1024 * 1024))

"$TEST" "$WORK/cp437.zip" "$WORK/output-cp437"
test "$(cat "$WORK/output-cp437/café.txt")" = legacy-name

for bad in unsafe drive-path case-collision directory-data bad-crc inconsistent local-crc-mismatch nul-path; do
  rm -rf "$WORK/output-$bad"
  if "$TEST" "$WORK/$bad.zip" "$WORK/output-$bad"; then
    echo "Invalid ZIP unexpectedly succeeded: $bad.zip" >&2
    exit 3
  fi
done

test ! -e "$WORK/escape.txt"
test ! -e "$WORK/output-bad-crc/crc.bin"
echo "JUICE_ZIP_HOST_TESTS_OK"
