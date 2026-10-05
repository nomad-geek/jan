#!/usr/bin/env bash
# Smoke-tests a linux-arm64 llama.cpp backend archive the way Jan will use it.
#
# Checks that the file name is one Jan's "Install backend from file" accepts
# (as version <tag>, backend linux-arm64), unpacks it into the layout Jan
# installs backends into, checks that llama-server resolves its libraries
# through its own rpath, then serves a tiny model and generates tokens.
#
# Usage: smoke-backend.sh <tarball> <llama-tag>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <tarball> <llama-tag>" >&2
  exit 2
fi
TARBALL=$(realpath "$1")
TAG=$2

SMOKE=${RUNNER_TEMP:-$(mktemp -d)}/smoke
mkdir -p "$SMOKE/home"
cd "$SMOKE"
export HOME="$SMOKE/home"
PORT=18080
# Pinned to a commit and checked by hash. ggml-org/models redirects here.
MODEL_COMMIT=499bc8821c6b12b4e53c5bffcb21ec206f212d81
MODEL_URL=https://huggingface.co/ggml-org/models-moved/resolve/$MODEL_COMMIT/tinyllamas/stories15M-q4_0.gguf
MODEL_SHA256=66967fbece6dbe97886593fdbb73589584927e29119ec31f08090732d1861739

# 1. The name, checked with the regex from Jan's llamacpp extension
#    (extensions/llamacpp-extension/src/index.ts, installBackend).
node - "$(basename "$TARBALL")" "$TAG" <<'EOF'
const [name, tag] = process.argv.slice(2)
const m =
  /^(.+?[-_])?llama(?:-main)?-(b\d+(?:-[a-f0-9]+)?)(?:-cudart-llama)?-bin-(.+?)\.(?:tar\.gz|zip)$/.exec(name)
if (!m) {
  console.error(`::error::${name} does not match Jan's backend file name pattern`)
  process.exit(1)
}
if (m[2] !== tag || m[3] !== 'linux-arm64') {
  console.error(`::error::${name} parses as version ${m[2]}, backend ${m[3]}; expected ${tag}, linux-arm64`)
  process.exit(1)
}
console.log(`file name ok: version ${m[2]}, backend ${m[3]}`)
EOF

# 2. The installed layout: <data>/llamacpp/backends/<tag>/<backend>/build/bin.
BACKEND_DIR="$HOME/.local/share/Jan/data/llamacpp/backends/$TAG/linux-arm64"
mkdir -p "$BACKEND_DIR"
tar -xzf "$TARBALL" -C "$BACKEND_DIR"
SERVER="$BACKEND_DIR/build/bin/llama-server"
[ -x "$SERVER" ] || {
  echo "::error::build/bin/llama-server missing from the archive"
  exit 1
}

# 3. Libraries resolve through $ORIGIN alone, with no LD_LIBRARY_PATH.
ldd_out=$(env -u LD_LIBRARY_PATH ldd "$SERVER")
echo "$ldd_out"
if grep -q 'not found' <<<"$ldd_out"; then
  echo "::error::llama-server has unresolved libraries"
  exit 1
fi
env -u LD_LIBRARY_PATH "$SERVER" --version

# 4. Real inference with a 19 MB model.
curl -fsSL --retry 3 -o stories15M-q4_0.gguf "$MODEL_URL"
echo "$MODEL_SHA256  stories15M-q4_0.gguf" | sha256sum -c - || {
  echo "::error::model checksum mismatch"
  exit 1
}

env -u LD_LIBRARY_PATH "$SERVER" -m stories15M-q4_0.gguf --host 127.0.0.1 --port "$PORT" -c 256 \
  >llama-server.log 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

ready=0
for _ in $(seq 60); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  tail -n 50 llama-server.log
  echo "::error::llama-server did not become healthy within 60s"
  exit 1
fi

content=$(curl -sf "http://127.0.0.1:$PORT/completion" \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"Once upon a time","n_predict":16}' | jq -r '.content // empty')
if [ -z "$content" ]; then
  tail -n 50 llama-server.log
  echo "::error::llama-server returned no completion"
  exit 1
fi
echo "completion: Once upon a time$content"

echo "CPU backend selected:"
grep -Ei 'load_backend|ggml_cpu|CPU :' llama-server.log | head -n 10 || true
echo "backend smoke test passed"
