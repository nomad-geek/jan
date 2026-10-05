#!/usr/bin/env bash
# Checks the bundle a Jan arm64 build produced, then gives the AppImage a
# stable name with a checksum beside it, ready to upload.
#
# Fails fast on: no AppImage or more than one, an AppImage or app binary that is
# not aarch64, a missing aarch64 uv sidecar and, for builds with the compiled-in
# engine, a missing engine worker or CPU backend.
#
# Usage: verify-bundle.sh <jan-dir> <version> <layout> <out-dir>
#   layout: runtime-backend | engine
# Prints the AppImage's path in <out-dir> as the last line of output.
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <jan-dir> <version> <layout> <out-dir>" >&2
  exit 2
fi
JAN_DIR=$1
VERSION=$2
LAYOUT=$3
OUT_DIR=$4

RELEASE="$JAN_DIR/src-tauri/target/release"
BUNDLE="$RELEASE/bundle/appimage"

mapfile -t images < <(find "$BUNDLE" -maxdepth 1 -type f -name '*.AppImage')
if [ "${#images[@]}" -ne 1 ]; then
  echo "::error::expected exactly one AppImage in $BUNDLE, found ${#images[@]}: ${images[*]}"
  exit 1
fi
IMAGE=${images[0]}

# expect_arm64 <path>
expect_arm64() {
  local desc
  desc=$(file -L "$1")
  echo "$desc"
  grep -q 'ARM aarch64' <<<"$desc" || {
    echo "::error::$1 is not an aarch64 ELF"
    exit 1
  }
}
expect_arm64 "$IMAGE"
expect_arm64 "$RELEASE/Jan"

UV="$JAN_DIR/src-tauri/resources/bin/uv-aarch64-unknown-linux-gnu"
[ -f "$UV" ] || {
  echo "::error::$UV missing; the sidecar was not retargeted"
  exit 1
}
expect_arm64 "$UV"

case "$LAYOUT" in
  engine)
    worker=$(find "$BUNDLE" -path '*.AppDir/*' -name jan-llama-worker -type f | head -n 1)
    [ -n "$worker" ] || {
      echo "::error::no jan-llama-worker in the AppDir"
      exit 1
    }
    expect_arm64 "$worker"
    [ -n "$(find "$BUNDLE" -path '*.AppDir/*' -name 'libggml-cpu*.so*' | head -n 1)" ] || {
      echo "::error::no libggml-cpu*.so in the AppDir; the CPU backend is missing"
      exit 1
    }
    ;;
  runtime-backend) ;;
  *)
    echo "::error::unknown layout '$LAYOUT'"
    exit 1
    ;;
esac

NAME="Jan_${VERSION}_aarch64.AppImage"
mkdir -p "$OUT_DIR"
cp "$IMAGE" "$OUT_DIR/$NAME"
(cd "$OUT_DIR" && sha256sum "$NAME" >"$NAME.sha256" && cat "$NAME.sha256")
if [ "$(basename "$IMAGE")" != "$NAME" ]; then
  echo "renamed $(basename "$IMAGE") to $NAME"
fi
echo "$OUT_DIR/$NAME"
