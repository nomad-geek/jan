#!/usr/bin/env bash
# Retargets an upstream Jan checkout's Linux build from x86_64 to aarch64.
#
# Upstream's Linux build hardcodes x86_64 in three places: the sidecar names in
# scripts/download-bin.mjs, the linuxdeploy download in shim-linuxdeploy.sh and
# the appimagetool download in buildAppImage.sh. This rewrites those tokens in
# the (throwaway) CI checkout so upstream's own `make build` produces an arm64
# bundle. Every substitution must match; if upstream reworks one of these files
# the script fails here, naming the file, instead of building something wrong.
#
# Usage: retarget-sources.sh <jan-dir>
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <jan-dir>" >&2
  exit 2
fi
JAN_DIR=$1

if [ "$(uname -m)" != "aarch64" ]; then
  echo "error: run this on an aarch64 host (uname -m is $(uname -m))" >&2
  exit 1
fi

# count <pattern> <file>: occurrences, not matching lines.
count() {
  # grep exits 1 on zero matches; a zero count is a valid answer here.
  { grep -oF -- "$1" "$2" || true; } | wc -l
}

# retarget <file> <from> <to> <min-replacements>
retarget() {
  local file="$JAN_DIR/$1" from=$2 to=$3 min=$4
  local from_before to_before from_after to_after

  if [ ! -f "$file" ]; then
    echo "error: $1 not found in $JAN_DIR; upstream layout changed" >&2
    exit 1
  fi

  from_before=$(count "$from" "$file")
  to_before=$(count "$to" "$file")
  if [ "$from_before" -lt "$min" ]; then
    echo "error: $1 has $from_before occurrence(s) of '$from', expected at least $min; upstream changed this file, review it before retargeting" >&2
    exit 1
  fi

  # The tokens contain only [A-Za-z0-9_.-]; escape the dots for sed.
  sed -i "s/${from//./\\.}/${to}/g" "$file"

  from_after=$(count "$from" "$file")
  to_after=$(count "$to" "$file")
  if [ "$from_after" -ne 0 ] || [ "$to_after" -ne $((to_before + from_before)) ]; then
    echo "error: $1: replacing '$from' with '$to' did not take (before $from_before/$to_before, after $from_after/$to_after)" >&2
    exit 1
  fi
  echo "retargeted $1: $from_before x '$from' -> '$to'"
}

# Sidecar copies bun-/uv-<triple>. Only the Linux branch uses this triple; the
# darwin and windows triples differ, so they are left alone.
retarget scripts/download-bin.mjs x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu 2
# linuxdeploy URL, cached filename, glob and symlink. Tauri's bundler looks for
# linuxdeploy-<arch>.AppImage in this cache, so the pinned version still applies.
retarget src-tauri/build-utils/shim-linuxdeploy.sh x86_64 aarch64 3
retarget src-tauri/build-utils/buildAppImage.sh appimagetool-x86_64.AppImage appimagetool-aarch64.AppImage 1

git -C "$JAN_DIR" --no-pager diff --stat
git -C "$JAN_DIR" --no-pager diff
