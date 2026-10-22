#!/usr/bin/env bash
# Adapt the upstream LineageOS-shaped device tree for the PixelOS custom product.
set -eo pipefail

SRC_ROOT="$(cd "${1:?Usage: prepare_device.sh /path/to/android-source}" && pwd)"
cd "$SRC_ROOT"

DEVICE_DIR="$SRC_ROOT/device/oplus/zephyr"
[[ -f "$DEVICE_DIR/lineage_zephyr.mk" ]] || { echo "ERROR: expected device/oplus/zephyr/lineage_zephyr.mk"; exit 1; }
[[ -f "$DEVICE_DIR/device.mk" ]] || { echo "ERROR: expected device/oplus/zephyr/device.mk"; exit 1; }
[[ -f "vendor/custom/config/common_full_phone.mk" ]] || { echo "ERROR: PixelOS vendor/custom config is missing; did repo sync finish?"; exit 1; }
[[ -f "vendor/oplus/zephyr/BoardConfigVendor.mk" ]] || { echo "ERROR: vendor/oplus/zephyr/BoardConfigVendor.mk is missing."; exit 1; }
[[ -f "vendor/mediatek/ims/ims.mk" ]] || { echo "ERROR: vendor/mediatek/ims/ims.mk is missing."; exit 1; }

apply_patch_commit() {
  local repo_dir="$1"
  local remote_url="$2"
  local sha="$3"
  local label="$4"

  if [[ ! -e "$repo_dir/.git" && ! -d "$repo_dir/.git" ]]; then
    echo "ERROR: expected Git project at $repo_dir ($label)"
    return 1
  fi

  if git -C "$repo_dir" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
    echo "Already applied: $label ($sha)"
    return 0
  fi

  echo "Fetching patch source for $label"
  git -C "$repo_dir" fetch --quiet "$remote_url" || git -C "$repo_dir" fetch "$remote_url"
  if ! git -C "$repo_dir" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    git -C "$repo_dir" fetch "$remote_url" "$sha"
  fi
  git -C "$repo_dir" cat-file -e "${sha}^{commit}" || {
    echo "ERROR: patch commit $sha was not fetched for $label"
    return 1
  }

  # Intentionally stop on conflicts; never silently skip a device patch.
  git -C "$repo_dir" cherry-pick -x "$sha"
}

# These cherry-picks are referenced by the device tree's original vendorsetup.sh,
# but they originate from older LineageOS branches and may need porting to
# PixelOS seventeen / Android 17. Keep them opt-in instead of breaking the
# first source sync/build by applying potentially stale patches unconditionally.
if [[ "${APPLY_LEGACY_DEVICE_PATCHES:-0}" == "1" ]]; then
  apply_patch_commit "packages/apps/Aperture" "https://github.com/Adarsh0127-Elite/android_packages_apps_Aperture.git" "9509277efc852ad8bdcce204e0d9cfe104b6d190" "Aperture MediaTek 60fps patch"
  apply_patch_commit "frameworks/native" "https://github.com/oplus-mt6895/android_frameworks_native.git" "5ae7b13cc9e7359261d15ab185ee4aaeb512f754" "MediaTek GED-KPI patch"
  apply_patch_commit "frameworks/native" "https://github.com/oplus-mt6895/android_frameworks_native.git" "31f62caf1160bb8460eb7f7c66e279fdb51867d6" "MediaTek UDFPS dithering patch"
  apply_patch_commit "frameworks/base" "https://github.com/oplus-mt6895/android_frameworks_base.git" "8fdf7742a1adabcb5c79fd23dcf2039fcda6ce3b" "MediaTek UDFPS SystemUI patch"
else
  echo "Skipping legacy MediaTek framework cherry-picks for the first PixelOS seventeen build."
  echo "Set APPLY_LEGACY_DEVICE_PATCHES=1 only after reviewing/porting them for Android 17."
fi

# PixelOS product config: preserve the upstream device variables, but switch
# the common product include and product name to the PixelOS custom namespace.
sed \
  -e 's#vendor/lineage/config/common_full_phone.mk#vendor/custom/config/common_full_phone.mk#' \
  -e 's/^PRODUCT_NAME := lineage_zephyr$/PRODUCT_NAME := custom_zephyr/' \
  "$DEVICE_DIR/lineage_zephyr.mk" > "$DEVICE_DIR/custom_zephyr.mk"

grep -q 'PRODUCT_NAME := custom_zephyr' "$DEVICE_DIR/custom_zephyr.mk" || {
  echo "ERROR: failed to generate custom_zephyr.mk"
  exit 1
}
grep -q 'vendor/custom/config/common_full_phone.mk' "$DEVICE_DIR/custom_zephyr.mk" || {
  echo "ERROR: PixelOS common product include was not set"
  exit 1
}

cat > "$DEVICE_DIR/AndroidProducts.mk" <<'EOF'
PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/custom_zephyr.mk \
    $(LOCAL_DIR)/lineage_zephyr.mk
EOF

# The original vendorsetup.sh clones dependencies and cherry-picks legacy
# patches whenever build/envsetup.sh is sourced. Required repos are now part
# of our local manifest, and any legacy patch attempts are handled explicitly
# above, so make envsetup side-effect-free.
cat > "$DEVICE_DIR/vendorsetup.sh" <<'EOF'
#!/usr/bin/env bash
# PixelOS integration: source setup is handled by the project build scripts.
:
EOF
chmod +x "$DEVICE_DIR/vendorsetup.sh"

echo "PixelOS device integration prepared: device/oplus/zephyr/custom_zephyr.mk"
