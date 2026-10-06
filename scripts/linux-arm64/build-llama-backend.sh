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
# Every ARM variant ggml declares must build: there is no single-backend
# fallback, so a compiler too old for one fails the job instead of quietly
# shipping less. The SME variants (armv9.2_*) need GCC 14 or newer; pick the
# compiler with CC/CXX. A host with no such compiler can leave named variants
# out with SKIP_ARM_VARIANTS (space-separated, e.g. "armv9.2_1 armv9.2_2"); the
# variants that shipped are written to llama-variants.txt beside the archive.
#
# Usage: [CC=gcc-14 CXX=g++-14] [SKIP_ARM_VARIANTS="..."] build-llama-backend.sh <llama-tag> <out-dir>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <llama-tag> <out-dir>" >&2
  exit 2
fi
TAG=$1
OUT_DIR=$2
CC=${CC:-cc}
CXX=${CXX:-c++}
export CC CXX
SKIP_ARM_VARIANTS=${SKIP_ARM_VARIANTS:-}

if ! [[ "$TAG" =~ ^b[0-9]+$ ]]; then
  echo "error: llama.cpp tag must look like b1234, got '$TAG'" >&2
  exit 2
fi
for v in $SKIP_ARM_VARIANTS; do
  if ! [[ "$v" =~ ^armv[0-9]+\.[0-9]+_[0-9]+$ ]]; then
    echo "error: SKIP_ARM_VARIANTS entries must look like armv9.2_1, got '$v'" >&2
    exit 2
  fi
done
if [ "$(uname -m)" != "aarch64" ]; then
  echo "error: run this on an aarch64 host (uname -m is $(uname -m))" >&2
  exit 1
fi
"$CC" --version | head -n 1
"$CXX" --version | head -n 1

WORK=${RUNNER_TEMP:-$(mktemp -d)}
SRC="$WORK/llama.cpp"
ASSET="llama-$TAG-bin-linux-arm64.tar.gz"

rm -rf "$SRC"
# Fetch the tag ref itself: clone --branch would prefer a branch of that name.
git init -q "$SRC"
cd "$SRC"
git remote add origin https://github.com/janhq/llama.cpp.git
git fetch --depth 1 origin "refs/tags/$TAG:refs/tags/$TAG"
git -c advice.detachedHead=false checkout -q "refs/tags/$TAG"
# The tag is mutable; record the commit actually built, for the release notes.
COMMIT=$(git rev-parse HEAD)
echo "llama.cpp $TAG at $COMMIT"

# Leave out the named variants. Each must match exactly one declaration, so a
# rename upstream stops the build here instead of skipping nothing.
for v in $SKIP_ARM_VARIANTS; do
  pattern="^[[:space:]]*ggml_add_cpu_backend_variant\\(${v//./\\.}[[:space:])]"
  hits=$(grep -cE "$pattern" ggml/src/CMakeLists.txt || true)
  if [ "$hits" != 1 ]; then
    echo "error: expected one ggml_add_cpu_backend_variant($v ...) in ggml/src/CMakeLists.txt, found $hits" >&2
    exit 1
  fi
  sed -i -E "/$pattern/d" ggml/src/CMakeLists.txt
  echo "::warning::leaving out the $v CPU variant (SKIP_ARM_VARIANTS)"
done

# shellcheck disable=SC2016 # a literal $ORIGIN, for the dynamic loader
cmake -S . -B build -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_CURL=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_BACKEND_DL=ON \
  -DGGML_CPU_ALL_VARIANTS=ON \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_INSTALL_RPATH='$ORIGIN' \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON | tee "$WORK/llama-configure.log"

# The variants this configure declared, with their -march flags:
#   -- Adding CPU backend variant ggml-cpu-armv8.2_1: -march=armv8.2-a+dotprod GGML_USE_DOTPROD
mapfile -t VARIANT_LINES < <(sed -nE 's/^-- Adding CPU backend variant ggml-cpu-([^:]+): (-march=[^ ]+).*/\1 \2/p' "$WORK/llama-configure.log")
if [ "${#VARIANT_LINES[@]}" -eq 0 ]; then
  echo "error: configure declared no CPU backend variants; GGML_CPU_ALL_VARIANTS did not take effect" >&2
  exit 1
fi

# Fail before a long build if the compiler rejects a variant's -march (GCC 13
# does not know +sme). ggml's own configure checks do not fail on this.
probe=$(mktemp -d)
printf 'int main(void) { return 0; }\n' >"$probe/p.c"
VARIANTS=()
for line in "${VARIANT_LINES[@]}"; do
  v=${line%% *}
  march=${line#* }
  # Names go into file names, the manifest and the release notes.
  if ! [[ "$v" =~ ^armv[0-9]+\.[0-9]+_[0-9]+$ ]]; then
    echo "error: unexpected CPU variant name '$v' in the configure output" >&2
    exit 1
  fi
  for lang in c c++; do
    compiler=$CC
    [ "$lang" = c++ ] && compiler=$CXX
    if ! "$compiler" -x "$lang" "$march" -c "$probe/p.c" -o "$probe/p.o" 2>"$probe/err"; then
      cat "$probe/err" >&2
      echo "::error::$compiler rejects $march for CPU variant $v; build with a newer compiler (CC/CXX) or leave it out with SKIP_ARM_VARIANTS"
      exit 1
    fi
  done
  VARIANTS+=("$v")
done
rm -rf "$probe"
echo "CPU variants: ${VARIANTS[*]}"

cmake --build build --config Release -j"$(nproc)" --target llama-server

# With GGML_BACKEND_DL the CPU variants are modules llama-server does not link
# against. ggml depends on them, but build any that are missing explicitly.
for v in "${VARIANTS[@]}"; do
  if [ ! -f "build/bin/libggml-cpu-$v.so" ]; then
    echo "build/bin/libggml-cpu-$v.so missing after the llama-server target; building ggml-cpu-$v"
    cmake --build build --config Release -j"$(nproc)" --target "ggml-cpu-$v"
  fi
done

echo "build/bin:"
ls -l build/bin

server_type=$(file build/bin/llama-server)
echo "$server_type"
grep -q 'ARM aarch64' <<<"$server_type" || {
  echo "error: build/bin/llama-server is not an aarch64 binary" >&2
  exit 1
}
# Exactly the declared variants, no more and no fewer.
expected=$(printf 'libggml-cpu-%s.so\n' "${VARIANTS[@]}" | sort)
built=$(cd build/bin && find . -maxdepth 1 -name 'libggml-cpu*.so' -printf '%f\n' | sort)
if [ "$expected" != "$built" ]; then
  echo "error: CPU backend modules in build/bin do not match the declared variants" >&2
  diff <(echo "$expected") <(echo "$built") >&2 || true
  exit 1
fi
# shellcheck disable=SC2016 # matching a literal $ORIGIN
readelf -d build/bin/llama-server | grep -E 'R(UN)?PATH' | grep -qF '$ORIGIN' || {
  echo "error: llama-server has no \$ORIGIN rpath; its libraries would not resolve once moved" >&2
  exit 1
}

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
tar -czf "$OUT_DIR/$ASSET" build/bin
archived=$(tar -tzf "$OUT_DIR/$ASSET")
for v in "${VARIANTS[@]}"; do
  grep -qx "build/bin/libggml-cpu-$v.so" <<<"$archived" || {
    echo "error: $ASSET lacks build/bin/libggml-cpu-$v.so" >&2
    exit 1
  }
done
(cd "$OUT_DIR" && sha256sum "$ASSET" >"$ASSET.sha256")
echo "$COMMIT" >"$OUT_DIR/llama-commit.txt"
printf '%s\n' "${VARIANTS[@]}" >"$OUT_DIR/llama-variants.txt"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### llama.cpp backend $TAG"
    echo
    echo "Compiler: \`$("$CC" --version | head -n 1)\`"
    echo
    echo "CPU variants (${#VARIANTS[@]}): \`${VARIANTS[*]}\`"
    if [ -n "$SKIP_ARM_VARIANTS" ]; then
      echo
      echo "Left out: \`$SKIP_ARM_VARIANTS\`"
    fi
  } >>"$GITHUB_STEP_SUMMARY"
fi

echo "built $OUT_DIR/$ASSET with ${#VARIANTS[@]} CPU variants: ${VARIANTS[*]}"
cat "$OUT_DIR/$ASSET.sha256"
