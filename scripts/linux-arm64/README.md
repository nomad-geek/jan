# Jan for Linux arm64 (AppImage)

An unofficial build of upstream Jan release tags as a Linux aarch64 AppImage,
for ARM servers and desktops (Ampere, Graviton, Snapdragon X). CPU inference
only: no CUDA, Vulkan or Jetson.

It is built by `.github/workflows/linux-arm64-appimage.yml` on GitHub's native
ARM runners. Nothing is cross-compiled or emulated. The workflow adds files and
edits nothing upstream, so syncing this fork with upstream stays conflict-free.

## Running the workflow

Actions → **linux-arm64-appimage** → **Run workflow**. The tag is checked out
from `janhq/jan` directly, not from this fork, so the fork does not need to carry
it (syncing a fork does not copy tags).

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
updates the release in place: it replaces assets of the same name and the notes,
and removes a backend archive left by a run with another `llama_cpp_tag`. The
release's own tag points at this repo's workflow commit; its notes name the
upstream tag and commit that were built, and the `janhq/llama.cpp` commit.

### What the build changes

`retarget-sources.sh` rewrites, in the throwaway CI checkout only, the three
places where upstream's Linux build hardcodes x86_64:

- the `bun`/`uv` sidecar names in `scripts/download-bin.mjs`;
- the linuxdeploy download in `src-tauri/build-utils/shim-linuxdeploy.sh`;
- the appimagetool download in `src-tauri/build-utils/buildAppImage.sh`.

Every substitution must match. If a future tag reworks one of these files, the
build stops there and names the file, rather than producing a wrong binary.

The aarch64 linuxdeploy (at the version upstream pins) and appimagetool (from
its `continuous` release) are downloaded without a checksum, as upstream's x64
build does.

The build sets `AUTO_UPDATER_DISABLED=true`, since upstream's update feed only
carries x86_64. It uses no secrets: the app is unsigned, and analytics keys are
empty.

## Installing

```sh
chmod +x Jan_0.8.4_aarch64.AppImage
./Jan_0.8.4_aarch64.AppImage
```

Running an AppImage needs FUSE: on Ubuntu 24.04+ `sudo apt install libfuse2t64
fuse3`, on 22.04 `sudo apt install libfuse2 fuse`. Without it, run
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
backend carries every ARM CPU variant ggml has (`GGML_CPU_ALL_VARIANTS`), from
plain `armv8.0` up to `armv9.2` with SVE2 and SME, and picks the best one for
the CPU at runtime. The release notes list the variants it carries.

All variants must build: there is no single-variant fallback, so a toolchain
problem fails the `llama-backend` job instead of quietly shipping a smaller
backend. The SME variants (`armv9.2_1`, `armv9.2_2`) need GCC 14, since GCC 13,
the default on `ubuntu-24.04-arm`, rejects `-march=...+sme`. The job therefore
builds with `gcc-14` from the Ubuntu 24.04 archive. It links against the
`libstdc++` and `libgomp` that 24.04 already ships, so the backend needs nothing
newer than the AppImage does. Before compiling, `build-llama-backend.sh` checks
that the compiler accepts every variant's `-march`. After it, it checks that
every variant's module is in the archive. It writes the list to
`llama-variants.txt`.

On `ubuntu-22.04-arm` no archive compiler knows `+sme`, so that runner leaves out
the two SME variants by name (`SKIP_ARM_VARIANTS`). The job summary and the
release notes then show 6 variants instead of 8. CPUs with SME use the
`armv8.6_2` (SVE2) variant instead.

Releases after 0.8.x compile the engine into the app. For those the workflow
detects the layout, builds the engine CPU-only (`JAN_ENGINE_VARIANT=cpu`) and
skips the separate backend.

## Limits

- **Oldest distro.** Built on `ubuntu-24.04-arm`, the AppImage needs glibc 2.39:
  Ubuntu 24.04+, Debian 13+. The `ubuntu-22.04-arm` runner gives a glibc 2.35
  floor (Ubuntu 22.04+, Debian 12+). Its backend leaves out the two SME
  variants (above).
- **No auto-update.** To update, rerun the workflow for the new upstream tag,
  and download the new AppImage.
- **Unsigned.** There is no updater signature, and no upstream signing key.
- **Model downloads.** Upstream signs requests to its download mirror with a key
  only its builds carry. Without it Jan falls back to the original Hugging Face
  URL, so downloads still work, but they do not go through the mirror.
- **Only the AppImage is published.** Tauri also builds a `.deb`, which is
  neither tested nor shipped.

## Host libraries

Like any AppImage, the bundle leaves out the libraries every desktop already
has. linuxdeploy follows the AppImage excludelist for this, and the x86_64 Jan
AppImage relies on the same host copies. On arm64 the app expects these from
the host:

- glibc (`libc`, `libm`, `libdl`, `libpthread`, `libresolv`), `libgcc_s` and
  `libstdc++`;
- the GL stack: `libEGL.so.1`, `libGL.so.1`, `libGLX`, `libGLdispatch`,
  `libgbm`, `libdrm` (Ubuntu packages `libegl1`, `libgl1`, `libgbm1`,
  `libdrm2`). It is left out on purpose, because it must match the host's GPU
  driver;
- X11 and Wayland client libraries (`libX11`, `libX11-xcb`, `libxcb`,
  `libwayland-client`), `fontconfig`, `freetype`, `harfbuzz`, `fribidi`,
  `expat`, `zlib`, `libgpg-error`, `libcom_err`.

Every desktop install has these. A minimal server or container image may lack
the GL stack: there, `sudo apt install libegl1 libgl1` (Ubuntu/Debian).

## Smoke tests

The `smoke` job runs on a fresh runner without the build's `-dev` packages. It
installs only what a desktop has and a bare runner image lacks: Xvfb, FUSE, and
`libegl1` (see Host libraries):

- `smoke-appimage.sh` extracts the AppImage and checks the following:
  - `Jan`, `jan-cli`, `uv` and `bun` are aarch64, and every shared library they
    need resolves;
  - `jan-cli --version` reports the tag's version;
  - the app stays up for 60 s under Xvfb, both extracted and through the
    AppImage's FUSE runtime, and creates its data directory.
- `smoke-backend.sh` checks the backend file name against Jan's own pattern. It
  unpacks the archive into the layout Jan installs to and checks that
  `llama-server` resolves its libraries through its own rpath. It checks that
  the archive holds exactly the CPU variant modules in `llama-variants.txt`,
  and that each resolves its libraries. It then serves a 15M-parameter model
  (19 MB, pinned to a Hugging Face commit and checked by sha256), generates
  tokens, and reports which variant the runner's CPU loaded.

On failure the job uploads the logs as the `smoke-logs` artifact. A failed build
uploads `appimage-debug`.

## Files

| File | Purpose |
|---|---|
| `retarget-sources.sh` | Rewrites the three x86_64 pins in the checked-out tag |
| `build-llama-backend.sh` | Builds `janhq/llama.cpp` as `llama-<tag>-bin-linux-arm64.tar.gz`, with every ARM CPU variant |
| `verify-bundle.sh` | Checks the built bundle and names the AppImage `Jan_<version>_aarch64.AppImage` |
| `smoke-appimage.sh` | AppImage smoke test |
| `smoke-backend.sh` | Backend smoke test with real inference |

`.test-tiers.json` at the repo root lints these scripts with shellcheck and the
workflow with actionlint.
