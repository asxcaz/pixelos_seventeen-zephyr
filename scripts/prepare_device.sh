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

# Android 17's AOSP external/libmnl defines a vendor variant that conflicts with
# the MediaTek GPS prebuilt shipped by this device. The device tree renames the
# proprietary blob to libmnl_mtk; keep AOSP's netlink libmnl system-only too.
fix_android17_libmnl_partition() {
  local bp="$SRC_ROOT/external/libmnl/Android.bp"
  [[ -f "$bp" ]] || {
    echo "ERROR: expected external/libmnl/Android.bp for the Android 17 partition fix."
    return 1
  }

  python3 - "$bp" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "PIXEL_OS_ZEPHYR_ANDROID17_LIBMNL_PARTITION_FIX"
module_re = re.compile(
    r'(?ms)^[ \t]*cc_library_shared[ \t]*\{[ \t]*\n'
    r'[ \t]*name:[ \t]*"libmnl",[^\n]*\n(?P<body>.*?)^[ \t]*\}'
)
modules = list(module_re.finditer(text))
if len(modules) != 1:
    raise SystemExit(f"Expected exactly one cc_library_shared module named libmnl in {path}; found {len(modules)}")

module = modules[0]
body = module.group("body")
if marker in body:
    print("Android 17 libmnl partition fix already applied.")
else:
    properties = list(re.finditer(r'(?m)^(?P<indent>[ \t]*)vendor_available[ \t]*:[ \t]*true,[ \t]*$', body))
    if len(properties) == 1:
        prop = properties[0]
        indent = prop.group("indent")
        replacement = (
            f"{indent}// {marker}: keep AOSP libmnl system-only; MediaTek GPS blob is libmnl_mtk.\n"
            f"{indent}// vendor_available: true,"
        )
        body = body[:prop.start()] + replacement + body[prop.end():]
        text = text[:module.start("body")] + body + text[module.end("body"):]
        path.write_text(text, encoding="utf-8")
        print("Applied Android 17 libmnl fix: removed vendor_available from AOSP libmnl.")
    elif not properties:
        print("AOSP libmnl is already system-only; no partition fix needed.")
    else:
        raise SystemExit(f"Unexpected duplicate vendor_available properties in {path}; refusing to edit automatically")
PY
}

fix_android17_libmnl_partition

# These HIDL interface libraries are built from hardware/mediatek .hal files
# with system_ext_specific=true. The full upstream compatibility audit detects
# source/vendor prebuilt name collisions; remove the exact overlapping vendor
# module declarations while preserving proprietary blob files and file lists.
# Current overlaps: Bluetooth audio 2.1/2.2, LBS 1.0, MtkRadioEx 2.0/3.0,
# and netdagent 1.0. This mapping is checked against live upstreams in CI.
fix_mtk_bluetooth_hidl_prebuilts() {
  local vendor_dir="$SRC_ROOT/vendor/oplus/zephyr"
  [[ -d "$vendor_dir" ]] || {
    echo "ERROR: expected vendor project at $vendor_dir"
    return 1
  }

  python3 - "$vendor_dir" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
marker = "PIXEL_OS_ZEPHYR_ANDROID17_BT_HIDL_PREBUILT_FIX"
targets = {
    "prebuilt_vendor.mediatek.hardware.bluetooth.audio@2.1": "Bluetooth audio @2.1",
    "vendor.mediatek.hardware.bluetooth.audio@2.1": "Bluetooth audio @2.1",
    "prebuilt_vendor.mediatek.hardware.bluetooth.audio@2.2": "Bluetooth audio @2.2",
    "vendor.mediatek.hardware.bluetooth.audio@2.2": "Bluetooth audio @2.2",
    "prebuilt_vendor.mediatek.hardware.lbs@1.0": "LBS @1.0",
    "vendor.mediatek.hardware.lbs@1.0": "LBS @1.0",
    "prebuilt_vendor.mediatek.hardware.mtkradioex@2.0": "MtkRadioEx @2.0",
    "vendor.mediatek.hardware.mtkradioex@2.0": "MtkRadioEx @2.0",
    "prebuilt_vendor.mediatek.hardware.mtkradioex@3.0": "MtkRadioEx @3.0",
    "vendor.mediatek.hardware.mtkradioex@3.0": "MtkRadioEx @3.0",
    "prebuilt_vendor.mediatek.hardware.netdagent@1.0": "Netdagent @1.0",
    "vendor.mediatek.hardware.netdagent@1.0": "Netdagent @1.0",
}
filenames = {
    "vendor.mediatek.hardware.bluetooth.audio@2.1.so": "Bluetooth audio @2.1",
    "vendor.mediatek.hardware.bluetooth.audio@2.2.so": "Bluetooth audio @2.2",
    "vendor.mediatek.hardware.lbs@1.0.so": "LBS @1.0",
    "vendor.mediatek.hardware.mtkradioex@2.0.so": "MtkRadioEx @2.0",
    "vendor.mediatek.hardware.mtkradioex@3.0.so": "MtkRadioEx @3.0",
    "vendor.mediatek.hardware.netdagent@1.0.so": "Netdagent @1.0",
}
removed = set()
already_marked = False

def brace_delta(line: str) -> int:
    delta = 0
    quoted = False
    escaped = False
    i = 0
    while i < len(line):
        char = line[i]
        if quoted:
            if escaped:
                escaped = False
            elif char == chr(92):
                escaped = True
            elif char == '"':
                quoted = False
        else:
            if char == '"':
                quoted = True
            elif char == "/" and i + 1 < len(line) and line[i + 1] == "/":
                break
            elif char == "{":
                delta += 1
            elif char == "}":
                delta -= 1
        i += 1
    return delta

# Remove generated Soong prebuilt module declarations where they exist.
module_start = re.compile(r'^[ \t]*(?:cc_prebuilt_library_shared|cc_prebuilt_library|cc_prebuilt_binary)[ \t]*\{')
for path in sorted(root.rglob("Android.bp")):
    text = path.read_text(encoding="utf-8")
    already_marked = already_marked or marker in text
    lines = text.splitlines(keepends=True)
    blocks = []
    i = 0
    while i < len(lines):
        if not module_start.match(lines[i]):
            i += 1
            continue
        start = i
        depth = 0
        end = None
        for j in range(start, len(lines)):
            depth += brace_delta(lines[j])
            if depth == 0:
                end = j
                break
        if end is None:
            raise SystemExit(f"Unbalanced Android.bp module braces in {path} starting at line {start + 1}")
        module_text = "".join(lines[start:end + 1])
        name_match = re.search(r'(?m)^[ \t]*name:[ \t]*"([^"]+)"', module_text)
        name = name_match.group(1) if name_match else ""
        version = targets.get(name)
        if version is None:
            for filename, candidate in filenames.items():
                if filename in module_text and re.search(r'(?m)^[ \t]*srcs[ \t]*:', module_text):
                    version = candidate
                    break
        if version is not None:
            blocks.append((start, end, version))
        i = end + 1

    if blocks:
        for start, end, version in reversed(blocks):
            removed.add(version)
            del lines[start:end + 1]
            if start < len(lines) and start > 0 and lines[start - 1].strip() and lines[start].strip():
                lines.insert(start, "\n")
        updated = "".join(lines)
        if marker not in updated:
            updated = f"// {marker}: replaced by the source-built system_ext HIDL interface.\n" + updated
        path.write_text(updated, encoding="utf-8")

# Legacy vendor trees commonly declare prebuilt libraries in Android.mk.
section_re = re.compile(
    r'(?ims)^[ \t]*include[ \t]+\$\([ \t]*CLEAR_VARS[ \t]*\)[ \t]*\r?\n'
    r'.*?^[ \t]*include[ \t]+\$\([ \t]*BUILD_[A-Z0-9_]+[ \t]*\)[ \t]*(?:#.*)?(?:\r?\n|$)'
)
local_module_re = re.compile(
    r'(?m)^[ \t]*LOCAL_MODULE[ \t]*:?=[ \t]*(?:prebuilt_)?'
    r'(vendor\.mediatek\.hardware\.(?:bluetooth\.audio@2\.[12]|lbs@1\.0|mtkradioex@(?:2\.0|3\.0)|netdagent@1\.0))[ \t]*(?:#.*)?$'
)
makefiles = sorted(set(root.rglob("*.mk")) | set(root.rglob("Android.mk")))
for path in makefiles:
    if not path.is_file():
        continue
    text = path.read_text(encoding="utf-8")
    already_marked = already_marked or marker in text
    matches = list(section_re.finditer(text))
    if not matches:
        continue
    output = []
    cursor = 0
    changed = False
    for match in matches:
        section = match.group(0)
        local_module = local_module_re.search(section)
        if not local_module:
            continue
        module_name = local_module.group(1)
        label = targets.get(module_name, targets.get("prebuilt_" + module_name))
        if label is None:
            continue
        removed.add(label)
        output.append(text[cursor:match.start()])
        output.append(f"# {marker}: replaced by the source-built system_ext HIDL interface ({label}).\n")
        cursor = match.end()
        changed = True
    if changed:
        output.append(text[cursor:])
        updated = "".join(output)
        path.write_text(updated, encoding="utf-8")

if not removed and not already_marked:
    print("No duplicate MediaTek HIDL prebuilt declarations found in the current vendor tree; nothing changed.")
elif removed:
    print("Removed duplicate vendor Bluetooth HIDL module declarations: " + ", ".join(sorted(removed)))
else:
    print("MediaTek HIDL prebuilt removal already applied.")
PY
}

fix_mtk_bluetooth_hidl_prebuilts

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
