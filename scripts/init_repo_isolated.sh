#!/usr/bin/env bash
# Initialize a Repo client inside SRC_DIR even when SRC_DIR is nested in a
# Crave workspace that already has its own .repo/repo/main.py.
set -euo pipefail

WORKSPACE_ROOT="$(cd "${1:?workspace root required}" && pwd -P)"
SRC_DIR="$(cd "${2:?source directory required}" && pwd -P)"
MANIFEST_URL="${3:?manifest URL required}"
MANIFEST_BRANCH="${4:?manifest branch required}"

log() { printf '\n[PixelOS-zephyr] %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

cd "$SRC_DIR"

PARENT_REPO_TOOL="$WORKSPACE_ROOT/.repo/repo"
PARENT_TOOL_BACKUP=""
restore_parent_repo_tool() {
  if [[ -n "$PARENT_TOOL_BACKUP" && ( -e "$PARENT_TOOL_BACKUP" || -L "$PARENT_TOOL_BACKUP" ) ]]; then
    if [[ -e "$PARENT_REPO_TOOL" || -L "$PARENT_REPO_TOOL" ]]; then
      echo "ERROR: cannot restore Crave's original repo tool because $PARENT_REPO_TOOL already exists." >&2
      return 1
    fi
    mv -- "$PARENT_TOOL_BACKUP" "$PARENT_REPO_TOOL"
  fi
}

if [[ -f ".repo/repo/main.py" ]]; then
  log "Independent Repo client already exists; initializing it in $SRC_DIR"
  repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --git-lfs
elif [[ -f "$PARENT_REPO_TOOL/main.py" ]]; then
  REPO_LAUNCHER="$(type -P repo || true)"
  [[ -n "$REPO_LAUNCHER" && -f "$REPO_LAUNCHER" ]] || die "could not locate the repo launcher to initialize the isolated source tree."

  BOOTSTRAP_LAUNCHER="$WORKSPACE_ROOT/.pixelos-repo-bootstrap.$$"
  PARENT_TOOL_BACKUP="$WORKSPACE_ROOT/.repo/repo-pixelos-backup.$$"
  [[ ! -e "$BOOTSTRAP_LAUNCHER" ]] || die "temporary repo bootstrap path already exists: $BOOTSTRAP_LAUNCHER"
  [[ ! -e "$PARENT_TOOL_BACKUP" ]] || die "temporary parent repo backup path already exists: $PARENT_TOOL_BACKUP"

  # The repo launcher walks up from the current directory and otherwise finds
  # Crave's existing client. Copy the launcher, temporarily hide only that
  # client's repo tool directory, and restore it even if repo init fails.
  cp -L -- "$REPO_LAUNCHER" "$BOOTSTRAP_LAUNCHER"
  chmod +x "$BOOTSTRAP_LAUNCHER"
  trap restore_parent_repo_tool EXIT
  log "Temporarily isolating Crave's repo launcher while initializing $SRC_DIR"
  mv -- "$PARENT_REPO_TOOL" "$PARENT_TOOL_BACKUP"

  if "$BOOTSTRAP_LAUNCHER" init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --git-lfs; then
    INIT_STATUS=0
  else
    INIT_STATUS=$?
  fi

  restore_parent_repo_tool
  trap - EXIT
  PARENT_TOOL_BACKUP=""
  rm -f -- "$BOOTSTRAP_LAUNCHER"
  if (( INIT_STATUS != 0 )); then
    exit "$INIT_STATUS"
  fi
else
  log "Initializing a fresh Repo client inside $SRC_DIR"
  repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --git-lfs
fi

[[ -f "$SRC_DIR/.repo/repo/main.py" ]] || die "repo init did not create $SRC_DIR/.repo/repo/main.py; refusing to sync using an ancestor Crave checkout."
log "Verified isolated Repo client at $SRC_DIR/.repo"
