#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
IO="$ROOT/app/JuiceHostIOHardening.m"
BUILD="$ROOT/scripts/build-app.sh"

test -f "$IO" || { echo "Missing host I/O hardening source." >&2; exit 2; }
grep -Fq 'app/JuiceHostIOHardening.m' "$BUILD" || {
  echo "build-app.sh does not compile JuiceHostIOHardening.m" >&2
  exit 3
}

# Both directions of the host protocol must tolerate EINTR and make progress
# until the entire fixed header/payload has been transferred.
grep -Fq 'count < 0 && errno == EINTR' "$IO"
grep -Fq 'JuiceHostIOReadAll' "$IO"
grep -Fq 'JuiceHostIOWriteAll' "$IO"
grep -Fq 'sendMessage:payload:toFD:' "$IO"
grep -Fq 'broadcast:size:' "$IO"
grep -Fq 'sendControlResponseToFD:request:status:path:detail:' "$IO"
grep -Fq 'readControlClient:' "$IO"

# Writes to a display client remain serialized so a frame/input header cannot
# be interleaved with another producer on the same stream.
grep -Fq '@synchronized(clients)' "$IO"
grep -Fq 'containsObject:@(fd)' "$IO"

# A control import request deliberately keeps its fd open until the document
# picker finishes; all rejected/host-action paths close their ownership.
grep -Fq 'picker owns fd until completion/cancellation' "$IO"
grep -Fq 'CONTROL_V1_PROTOCOL_REJECTED' "$IO"

echo "JUICE_HOST_IO_HARDENING_VERIFY_OK"
