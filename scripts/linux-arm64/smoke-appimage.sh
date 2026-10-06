#!/usr/bin/env bash
# Smoke-tests a Jan aarch64 AppImage on a clean host (no -dev packages).
#
# Extracts it, checks that the app binary and its sidecars (jan-cli, uv, bun)
# are aarch64 with every shared library resolved, checks their versions, then
# launches the app under Xvfb twice: extracted, and through the AppImage's own
# FUSE runtime. A launch passes if the app is still running when the timeout
# hits and its log holds no loader error, panic or crash.
#
# Usage: smoke-appimage.sh <appimage> <expected-version>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <appimage> <expected-version>" >&2
  exit 2
fi
APPIMAGE=$(realpath "$1")
VERSION=$2

SMOKE=${RUNNER_TEMP:-$(mktemp -d)}/smoke
rm -rf "$SMOKE"
mkdir -p "$SMOKE/home"
cd "$SMOKE"
# A fresh data dir, so the launch proves first-run init.
export HOME="$SMOKE/home"
unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME
# The second launch must go through the real FUSE runtime.
unset APPIMAGE_EXTRACT_AND_RUN
LAUNCH_SECONDS=${LAUNCH_SECONDS:-60}
FAILED=0

fail() {
  echo "::error::$*"
  FAILED=1
}

# The FUSE launch needs a setuid fusermount (FUSE 2) or fusermount3 (FUSE 3);
# libfuse2t64 alone ships neither.
if ! command -v fusermount >/dev/null && ! command -v fusermount3 >/dev/null; then
  echo "::error::neither fusermount nor fusermount3 is on PATH; install fuse3 (Ubuntu 24.04) or fuse (22.04)"
  exit 1
fi

chmod +x "$APPIMAGE"
"$APPIMAGE" --appimage-extract >extract.log 2>&1 || {
  tail -n 50 extract.log
  echo "::error::--appimage-extract failed"
  exit 1
}
ROOT="$SMOKE/squashfs-root"
for f in AppRun usr/bin/Jan; do
  [ -e "$ROOT/$f" ] || {
    echo "::error::$f missing from the AppImage"
    exit 1
  }
done

# find_one <name>: the single regular file of that name inside the AppImage.
find_one() {
  local hits
  hits=$(find "$ROOT" -type f -name "$1")
  if [ -z "$hits" ]; then
    echo "::error::$1 not found in the AppImage" >&2
    return 1
  fi
  if [ "$(printf '%s\n' "$hits" | wc -l)" -ne 1 ]; then
    echo "::warning::more than one $1 in the AppImage, checking the first:" >&2
    printf '%s\n' "$hits" >&2
  fi
  printf '%s\n' "$hits" | sort | head -n 1
}

JAN="$ROOT/usr/bin/Jan"
JAN_CLI=$(find_one jan-cli)
UV=$(find_one uv)
BUN=$(find_one bun)

declare -A ARCH_OK LDD_OK VERSION_OUT
for bin in "$JAN" "$JAN_CLI" "$UV" "$BUN"; do
  name=${bin#"$ROOT"/}
  if file -L "$bin" | grep -q 'ARM aarch64'; then
    ARCH_OK[$name]=yes
  else
    ARCH_OK[$name]=no
    fail "$name is not aarch64: $(file -L "$bin")"
  fi
  # Static binaries make ldd exit non-zero ("not a dynamic executable").
  ldd_out=$(LD_LIBRARY_PATH="$ROOT/usr/lib" ldd "$bin" 2>&1 || true)
  printf '%s\n' "== ldd $name" "$ldd_out" >>ldd.log
  if grep -q 'not found' <<<"$ldd_out"; then
    LDD_OK[$name]=no
    fail "$name has unresolved libraries: $(grep 'not found' <<<"$ldd_out" | tr '\n' ' ')"
  else
    LDD_OK[$name]=yes
  fi
done

# version_of <label> <bin>
version_of() {
  local out
  if out=$("$2" --version 2>&1); then
    VERSION_OUT[$1]=$(head -n 1 <<<"$out")
  else
    VERSION_OUT[$1]="FAILED"
    fail "$1 --version exited non-zero: $out"
  fi
}
version_of jan-cli "$JAN_CLI"
version_of uv "$UV"
version_of bun "$BUN"
VERSION_OUT[usr/bin/Jan]="(no --version)"
if [ "${VERSION_OUT[jan-cli]}" = "FAILED" ] || ! grep -qF -- "$VERSION" <<<"${VERSION_OUT[jan-cli]}"; then
  fail "jan-cli --version is '${VERSION_OUT[jan-cli]}', expected it to contain $VERSION"
fi

# The app's own structured log records ([YYYY-MM-DD][HH:MM:SS][module][LEVEL] ...)
# can legitimately report a missing shared library at DEBUG or TRACE level,
# e.g. the optional NVIDIA probe's "libnvidia-ml.so: cannot open shared
# object file" on a host with no NVIDIA card (always [DEBUG] in practice).
# The loader patterns below must not fire on those records; they still apply
# to every other line, including the same module logging at INFO/WARN/ERROR
# (a real failure, not a probe), the dynamic loader's own stderr, and
# libepoxy's "Couldn't open libGLESv2.so.2: ... cannot open shared object".
# The module field (third bracket) never contains ']', confirmed from the
# run logs.
APP_DEBUG_RECORD_RE='^\[[0-9]{4}-[0-9]{2}-[0-9]{2}\]\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]\[[^]]*\]\[(DEBUG|TRACE)\]'

# has_crash <log>: true if the log shows a loader error, panic or crash.
has_crash() {
  local log=$1 non_record
  # Panics and segfaults are fatal wherever they appear, app records included.
  if LC_ALL=C grep -aEq 'panicked at|Segmentation fault' "$log"; then
    return 0
  fi
  # Captured rather than piped: under pipefail, grep -Eq exiting on its first
  # match (with more input still queued) would SIGPIPE the producer side of a
  # pipe, and that 141 would read as "no crash" here. LC_ALL=C and -a: a NUL
  # byte or invalid UTF-8 would otherwise make grep treat the log as binary
  # and silently stop, or drop lines, under a UTF-8 locale.
  non_record=$(LC_ALL=C grep -avE "$APP_DEBUG_RECORD_RE" "$log" || true)
  LC_ALL=C grep -aEq 'error while loading shared libraries|cannot open shared object' <<<"$non_record"
}

# launch <label> <command...>: passes if the app outlives the timeout cleanly.
launch() {
  local label=$1 log="$SMOKE/gui-$1.log" code=0
  shift
  timeout --kill-after=15 "$LAUNCH_SECONDS" xvfb-run -a "$@" >"$log" 2>&1 || code=$?
  # Strays: the extracted app, or the app inside the AppImage's FUSE mount.
  # Never match on the AppImage path itself, which is in this script's argv.
  pkill -f "$ROOT/" || true
  pkill -f '/\.mount_' || true
  sleep 2
  echo "--- gui-$label.log (tail)"
  tail -n 40 "$log"
  # 124: still running at the timeout; 137: and it needed the KILL as well.
  if [ "$code" -ne 124 ] && [ "$code" -ne 137 ]; then
    fail "GUI launch ($label) exited with $code before the ${LAUNCH_SECONDS}s timeout"
  fi
  if has_crash "$log"; then
    fail "GUI launch ($label) log shows a loader error, panic or crash"
  fi
}

launch extracted "$ROOT/AppRun"
if [ ! -d "$HOME/.local/share/Jan/data" ]; then
  fail "the extracted launch did not create $HOME/.local/share/Jan/data (app init did not run)"
fi
launch fuse "$APPIMAGE"

echo
printf '%-40s %-6s %-7s %s\n' binary arch ldd version
for bin in "$JAN" "$JAN_CLI" "$UV" "$BUN"; do
  name=${bin#"$ROOT"/}
  case $name in
    */jan-cli) v=${VERSION_OUT[jan-cli]} ;;
    */uv) v=${VERSION_OUT[uv]} ;;
    */bun) v=${VERSION_OUT[bun]} ;;
    *) v=${VERSION_OUT[usr/bin/Jan]} ;;
  esac
  printf '%-40s %-6s %-7s %s\n' "$name" "${ARCH_OK[$name]}" "${LDD_OK[$name]}" "$v"
done

if [ "$FAILED" -ne 0 ]; then
  echo "AppImage smoke test FAILED"
  exit 1
fi
echo "AppImage smoke test passed"
