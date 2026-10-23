#!/usr/bin/env bash
# Crave entrypoint: initialize an isolated PixelOS seventeen source tree and build zephyr.
set -eo pipefail

CONFIG_REPO="https://github.com/asxcaz/pixelos_seventeen-zephyr.git"
CONFIG_REF="${BUILD_CONFIG_REF:-main}"
MANIFEST_URL="https://github.com/PixelOS-AOSP/android_manifest.git"
MANIFEST_BRANCH="seventeen"
WORKSPACE_ROOT="$PWD"
CONFIG_DIR="$WORKSPACE_ROOT/.pixelos-seventeen-zephyr-config"
SRC_DIR="$WORKSPACE_ROOT/pixelos-seventeen-zephyr-src"
SYNC_MARKER="$SRC_DIR/.pixelos-zephyr-source-synced"

log() { printf '\n[%s] %s\n' "PixelOS-zephyr" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is missing in the Crave build image."
command -v curl >/dev/null 2>&1 || die "curl is missing in the Crave build image."
command -v repo >/dev/null 2>&1 || die "repo is missing in the Crave build image."
command -v nproc >/dev/null 2>&1 || die "nproc is missing in the Crave build image."

# Use the VM's available logical CPUs by default; allow an explicit override.
REPO_SYNC_JOBS="${REPO_SYNC_JOBS:-$(nproc --all)}"
[[ "$REPO_SYNC_JOBS" =~ ^[1-9][0-9]*$ ]] || die "REPO_SYNC_JOBS must be a positive integer (got: $REPO_SYNC_JOBS)."

log "Workspace: $WORKSPACE_ROOT"
log "Independent Android source tree: $SRC_DIR"

# Keep build scripts separate from Crave's pre-populated project source snapshot.
if [[ ! -d "$CONFIG_DIR/.git" ]]; then
  log "Cloning this build-config repository ($CONFIG_REF)"
  git clone --depth=1 --branch "$CONFIG_REF" "$CONFIG_REPO" "$CONFIG_DIR"
else
  log "Updating the small build-config checkout ($CONFIG_REF)"
  git -C "$CONFIG_DIR" fetch --depth=1 origin "$CONFIG_REF"
  git -C "$CONFIG_DIR" checkout -B "$CONFIG_REF" FETCH_HEAD
fi

mkdir -p "$SRC_DIR"

SYNC_SOURCE="${SYNC_SOURCE:-0}"
if [[ ! -f "$SYNC_MARKER" || "$SYNC_SOURCE" == "1" ]]; then
  if [[ -f "$SYNC_MARKER" && "$SYNC_SOURCE" == "1" ]]; then
    log "SYNC_SOURCE=1 requested; restoring only generated device-tree edits before syncing"
    bash "$CONFIG_DIR/scripts/restore_before_sync.sh" "$SRC_DIR"
  fi

  log "Initializing PixelOS manifest branch: $MANIFEST_BRANCH"
  bash "$CONFIG_DIR/scripts/init_repo_isolated.sh" "$WORKSPACE_ROOT" "$SRC_DIR" "$MANIFEST_URL" "$MANIFEST_BRANCH"
  cd "$SRC_DIR"

  mkdir -p .repo/local_manifests
  log "Resolving default branches for the device-source repositories"
  bash "$CONFIG_DIR/scripts/write_manifest.sh" > .repo/local_manifests/zephyr.xml.tmp
  mv .repo/local_manifests/zephyr.xml.tmp .repo/local_manifests/zephyr.xml

  log "Syncing PixelOS and device sources (jobs=$REPO_SYNC_JOBS)"
  repo sync --current-branch --no-clone-bundle --no-tags -j"$REPO_SYNC_JOBS"
  touch "$SYNC_MARKER"
else
  log "Reusing the existing synchronized source tree for an incremental build"
  cd "$SRC_DIR"
fi

log "Preparing the zephyr PixelOS product and device patches"
bash "$CONFIG_DIR/scripts/prepare_device.sh" "$SRC_DIR"

cd "$SRC_DIR"
log "Loading Android build environment"
source build/envsetup.sh

log "Selecting device: zephyr"
breakfast zephyr

if [[ "${PREPARE_ONLY:-0}" == "1" ]]; then
  log "PREPARE_ONLY=1: source sync and device lunch check completed; skipping compilation."
  exit 0
fi

log "Building PixelOS"
m pixelos

OUT_DIR="$SRC_DIR/out/target/product/zephyr"
log "Build finished. Available ROM ZIPs and images:"
if [[ -d "$OUT_DIR" ]]; then
  find "$OUT_DIR" -maxdepth 1 -type f \( -name '*.zip' -o -name '*.img' \) -printf '%f (%s bytes)\n' | sort
else
  echo "No output directory found at $OUT_DIR"
fi

log "Output directory: $OUT_DIR"
