# Jan for Linux arm64 (AppImage)

An unofficial build of upstream Jan release tags as a Linux aarch64 AppImage,
for ARM servers and desktops (Ampere, Graviton, Snapdragon X). CPU inference
only: no CUDA, Vulkan or Jetson.

It is built by `.github/workflows/linux-arm64-appimage.yml` on GitHub's native
ARM runners. Nothing is cross-compiled or emulated. The workflow adds files and
edits nothing upstream, so syncing this fork with upstream stays conflict-free.

## Running the workflow

1. Sync the fork so it has the upstream tag you want, e.g. `v0.8.4`.
2. Actions → **linux-arm64-appimage** → **Run workflow**:

   | Input | Default | Meaning |
   |---|---|---|
   | `tag` | `v0.8.4` | Upstream tag to build, or `main` to try the next release's layout (never published) |
   | `llama_cpp_tag` | `b9967` | `janhq/llama.cpp` release built as the backend (releases that download their backend only) |
   | `runner` | `ubuntu-24.04-arm` | Build host; sets the oldest distro the AppImage runs on (below) |
   | `publish` | `true` | Create or update the release `<tag>-linux-arm64` |

The workflow file must be on the fork's default branch for **Run workflow** to
appear.

Jobs:

- `prepare` validates the inputs and reads the tag's version and layout.
- `llama-backend` builds the backend archive (10-20 min).
- `appimage` runs upstream's own `make build` after retargeting it to aarch64
  (40-70 min).
- `smoke` tests both on a fresh runner.
- `release` publishes them.

Every run also keeps the files as workflow artifacts. Rerunning for the same tag
updates the release in place and replaces assets of the same name.

### What the build changes

`retarget-sources.sh` rewrites, in the throwaway CI checkout only, the three
places where upstream's Linux build hardcodes x86_64:

- the `bun`/`uv` sidecar names in `scripts/download-bin.mjs`;
- the linuxdeploy download in `src-tauri/build-utils/shim-linuxdeploy.sh`;
- the appimagetool download in `src-tauri/build-utils/buildAppImage.sh`.

Every substitution must match. If a future tag reworks one of these files, the
build stops there and names the file, rather than producing a wrong binary.

The build sets `AUTO_UPDATER_DISABLED=true`, since upstream's update feed only
carries x86_64. It uses no secrets: the app is unsigned, and analytics keys are
empty.

## Installing

```sh
chmod +x Jan_0.8.4_aarch64.AppImage
./Jan_0.8.4_aarch64.AppImage
```

Running an AppImage needs FUSE 2 (`sudo apt install libfuse2t64`, or `libfuse2`
before Ubuntu 24.04). Without it, run
`./Jan_0.8.4_aarch64.AppImage --appimage-extract-and-run`.

Check a download with `sha256sum -c Jan_0.8.4_aarch64.AppImage.sha256`.

### The llama.cpp backend (Jan 0.8.x)

Jan 0.8.x downloads its llama.cpp backend on first run from `janhq/llama.cpp`,
which publishes none for Linux arm64. Without a backend the app opens but cannot
run a model. The workflow builds one from the same `janhq/llama.cpp` tag the x64
assets come from, and the release carries it as
`llama-b9967-bin-linux-arm64.tar.gz`. Install it once:

1. Download `llama-b9967-bin-linux-arm64.tar.gz` from the release.
2. In Jan: **Settings → llama.cpp → Install backend from file**, and pick it.
3. Jan installs it as version `b9967`, backend `linux-arm64`, and selects it.

Keep the file name as it is: Jan reads the version and backend from it. The
backend carries every ARM CPU variant ggml has, and picks the best one for the
CPU at runtime. If that build fails on the runner's compiler, the script falls
back to a single `armv8.2-a+dotprod+fp16` backend, which still covers Ampere,
Graviton 2+ and Snapdragon X. The run then shows a warning.

Releases after 0.8.x compile the engine into the app. For those the workflow
detects the layout, builds the engine CPU-only (`JAN_ENGINE_VARIANT=cpu`) and
skips the separate backend.

## Limits

- **Oldest distro.** Built on `ubuntu-24.04-arm`, the AppImage needs glibc 2.39:
  Ubuntu 24.04+, Debian 13+. The `ubuntu-22.04-arm` runner gives a glibc 2.35
  floor (Ubuntu 22.04+, Debian 12+). Its older compiler is more likely to need
  the backend fallback above.
- **No auto-update.** To update, sync the fork, rerun the workflow for the new
  tag, and download the new AppImage.
- **Unsigned.** There is no updater signature, and no upstream signing key.
- **Model downloads.** Upstream signs requests to its download mirror with a key
  only its builds carry. Without it Jan falls back to the original Hugging Face
  URL, so downloads still work, but they do not go through the mirror.
- **Only the AppImage is published.** Tauri also builds a `.deb`, which is
  neither tested nor shipped.

## Smoke tests

The `smoke` job runs on a fresh runner without the build's `-dev` packages:

- `smoke-appimage.sh` extracts the AppImage and checks the following:
  - `Jan`, `jan-cli`, `uv` and `bun` are aarch64, and every shared library they
    need resolves;
  - `jan-cli --version` reports the tag's version;
  - the app stays up for 60 s under Xvfb, both extracted and through the
    AppImage's FUSE runtime, and creates its data directory.
- `smoke-backend.sh` checks the backend file name against Jan's own pattern. It
  unpacks the archive into the layout Jan installs to and checks that
  `llama-server` resolves its libraries through its own rpath. It then serves a
  15M-parameter model (19 MB) and generates tokens.

On failure the job uploads the logs as the `smoke-logs` artifact. A failed build
uploads `appimage-debug`.

## Files

| File | Purpose |
|---|---|
| `retarget-sources.sh` | Rewrites the three x86_64 pins in the checked-out tag |
| `build-llama-backend.sh` | Builds `janhq/llama.cpp` as `llama-<tag>-bin-linux-arm64.tar.gz` |
| `verify-bundle.sh` | Checks the built bundle and names the AppImage `Jan_<version>_aarch64.AppImage` |
| `smoke-appimage.sh` | AppImage smoke test |
| `smoke-backend.sh` | Backend smoke test with real inference |

`.test-tiers.json` at the repo root lints these scripts with shellcheck and the
workflow with actionlint.
