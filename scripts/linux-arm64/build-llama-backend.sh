#!/usr/bin/env bash
# Builds janhq/llama.cpp at a release tag as a Jan "linux-arm64" backend archive.
#
# janhq/llama.cpp publishes no Linux arm64 asset, so Jan releases that download
# their backend at runtime find nothing to run on ARM Linux. This builds the
# same CPU configuration janhq uses for linux-common_cpus-x64 (backend DL plus
# every CPU variant, picked at runtime), with $ORIGIN rpaths so the libraries
# resolve wherever Jan unpacks them, and packs it the way janhq does: an archive
# whose root is build/bin/. The file name is the one Jan's "Install backend from
# file" accepts: llama-<tag>-bin-linux-arm64.tar.gz.
#
# Usage: build-llama-backend.sh <llama-tag> <out-dir>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <llama-tag> <out-dir>" >&2
  exit 2
fi
TAG=$1
OUT_DIR=$2

if ! [[ "$TAG" =~ ^b[0-9]+$ ]]; then
  echo "error: llama.cpp tag must look like b1234, got '$TAG'" >&2
  exit 2
fi
if [ "$(uname -m)" != "aarch64" ]; then
  echo "error: run this on an aarch64 host (uname -m is $(uname -m))" >&2
  exit 1
fi

WORK=${RUNNER_TEMP:-$(mktemp -d)}
SRC="$WORK/llama.cpp"
ASSET="llama-$TAG-bin-linux-arm64.tar.gz"

rm -rf "$SRC"
git clone --depth 1 --branch "$TAG" https://github.com/janhq/llama.cpp.git "$SRC"
cd "$SRC"
echo "llama.cpp $TAG at $(git rev-parse HEAD)"

# shellcheck disable=SC2016 # a literal $ORIGIN, for the dynamic loader
COMMON_FLAGS=(
  -GNinja
  -DCMAKE_BUILD_TYPE=Release
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_CURL=OFF
  -DGGML_NATIVE=OFF
  -DGGML_BACKEND_DL=ON
  -DBUILD_SHARED_LIBS=ON
  -DCMAKE_INSTALL_RPATH='$ORIGIN'
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
)

# configure_and_build <cpu flags...>
configure_and_build() {
  rm -rf build
  cmake -S . -B build "${COMMON_FLAGS[@]}" "$@" &&
    cmake --build build --config Release -j"$(nproc)" --target llama-server
}

if configure_and_build -DGGML_CPU_ALL_VARIANTS=ON; then
  CPU_MODE="all ARM CPU variants, selected at runtime"
else
  # The newest ARM variants (SVE2/SME) need a recent compiler; gcc 11 on
  # ubuntu-22.04 rejects some of them. One armv8.2 build with dotprod and fp16
  # still covers Ampere, Graviton 2+ and Snapdragon X.
  echo "::warning::GGML_CPU_ALL_VARIANTS build failed; falling back to a single armv8.2-a+dotprod+fp16 CPU backend"
  configure_and_build -DGGML_CPU_ALL_VARIANTS=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16
  CPU_MODE="single armv8.2-a+dotprod+fp16 CPU backend (fallback)"
fi

# With GGML_BACKEND_DL the CPU backends are modules llama-server does not link
# against. ggml normally depends on them, but build them explicitly if not.
if ! compgen -G 'build/bin/libggml-cpu*.so' >/dev/null; then
  echo "CPU backend modules missing after the llama-server target; building all targets"
  cmake --build build --config Release -j"$(nproc)"
fi

echo "build/bin:"
ls -l build/bin

file build/bin/llama-server | tee /dev/stderr | grep -q 'ARM aarch64' || {
  echo "error: build/bin/llama-server is not an aarch64 binary" >&2
  exit 1
}
compgen -G 'build/bin/libggml-cpu*.so' >/dev/null || {
  echo "error: no libggml-cpu*.so in build/bin; the CPU backend was not built" >&2
  exit 1
}
# shellcheck disable=SC2016 # matching a literal $ORIGIN
readelf -d build/bin/llama-server | grep -E 'R(UN)?PATH' | grep -qF '$ORIGIN' || {
  echo "error: llama-server has no \$ORIGIN rpath; its libraries would not resolve once moved" >&2
  exit 1
}

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
tar -czf "$OUT_DIR/$ASSET" build/bin
(cd "$OUT_DIR" && sha256sum "$ASSET" >"$ASSET.sha256")

echo "built $OUT_DIR/$ASSET ($CPU_MODE)"
cat "$OUT_DIR/$ASSET.sha256"
