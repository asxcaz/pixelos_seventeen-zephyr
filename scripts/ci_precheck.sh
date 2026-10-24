#!/usr/bin/env bash
# Lightweight checks for GitHub Actions; never sync or build the Android tree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
cleanup() {
  rm -rf -- "$TMP_ROOT"
  echo
  echo "===== Runner disk after cleanup ====="
  df -hT "${GITHUB_WORKSPACE:-$REPO_ROOT}" 2>/dev/null || df -hT
}
trap cleanup EXIT

cd "$REPO_ROOT"

echo "===== Disk at precheck start ====="
df -hT "${GITHUB_WORKSPACE:-$REPO_ROOT}" 2>/dev/null || df -hT

echo
echo "===== Bash syntax ====="
for file in build.sh scripts/*.sh; do
  echo "bash -n $file"
  bash -n "$file"
done

echo
echo "===== Local manifest generation + XML validation ====="
bash scripts/write_manifest.sh > "$TMP_ROOT/zephyr.xml"
python3 - "$TMP_ROOT/zephyr.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

manifest = ET.parse(sys.argv[1]).getroot()
projects = manifest.findall("project")
paths = [p.attrib.get("path") for p in projects]
if len(paths) != len(set(paths)):
    duplicates = sorted({p for p in paths if paths.count(p) > 1})
    raise SystemExit(f"Duplicate local-manifest paths: {duplicates}")

required = {
    "device/oplus/zephyr",
    "device/oplus/zephyr-kernel",
    "vendor/oplus/zephyr",
    "device/mediatek/sepolicy_vndr",
    "hardware/mediatek",
    "hardware/oplus",
    "vendor/mediatek/ims",
}
missing = required - set(paths)
if missing:
    raise SystemExit(f"Required device projects missing from manifest: {sorted(missing)}")

for project in projects:
    for attr in ("name", "path", "remote", "revision"):
        if not project.attrib.get(attr):
            raise SystemExit(f"Project is missing {attr}: {project.attrib}")

print(f"XML valid; {len(projects)} device projects; paths unique; all revisions explicit.")
PY

echo
echo "===== Shallow clone of PixelOS manifest for path-collision checks ====="
git clone --depth=1 --single-branch --branch seventeen \
  https://github.com/PixelOS-AOSP/android_manifest.git "$TMP_ROOT/pixelos-manifest"
python3 - "$TMP_ROOT/zephyr.xml" "$TMP_ROOT/pixelos-manifest" <<'PY'
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

local_root = ET.parse(sys.argv[1]).getroot()
manifest_root = Path(sys.argv[2])
active = {}

def apply_manifest(file_path):
    root = ET.parse(file_path).getroot()
    for node in root:
        if node.tag == "include":
            included = manifest_root / node.attrib["name"]
            if not included.is_file():
                raise SystemExit(f"Included manifest does not exist: {included}")
            apply_manifest(included)
        elif node.tag == "remove-project":
            name = node.attrib.get("name")
            path = node.attrib.get("path")
            to_remove = [
                p for p, project in active.items()
                if (name and project.attrib.get("name") == name)
                or (path and p == path)
            ]
            for p in to_remove:
                del active[p]
        elif node.tag == "project":
            path = node.attrib.get("path", node.attrib.get("name"))
            if path:
                active[path] = node

apply_manifest(manifest_root / "default.xml")
local_paths = {p.attrib["path"] for p in local_root.findall("project")}
collisions = sorted(local_paths & set(active))
if collisions:
    details = {p: active[p].attrib.get("name") for p in collisions}
    raise SystemExit(f"Device projects collide with active PixelOS manifest paths: {details}")
print(f"No path collisions against active PixelOS seventeen manifest ({len(active)} upstream project paths).")
PY

echo
echo "===== Shallow clone of device tree's advertised default branch ====="
DEVICE_URL="https://github.com/oplus-mt6895/android_device_oplus_zephyr.git"
DEVICE_BRANCH="$(git ls-remote --symref "$DEVICE_URL" HEAD | awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2; exit }')"
if [[ -z "$DEVICE_BRANCH" ]]; then
  echo "Unable to resolve device tree's advertised default branch." >&2
  exit 1
fi
echo "Default branch: $DEVICE_BRANCH"
git clone --depth=1 --single-branch --branch "$DEVICE_BRANCH" "$DEVICE_URL" "$TMP_ROOT/device"
DEVICE_TREE="$TMP_ROOT/device"

grep -Eq '^[[:space:]]*PRODUCT_DEVICE[[:space:]]*:=[[:space:]]*zephyr[[:space:]]*$' "$DEVICE_TREE/lineage_zephyr.mk"
grep -Eq '^[[:space:]]*PRODUCT_NAME[[:space:]]*:=[[:space:]]*lineage_zephyr[[:space:]]*$' "$DEVICE_TREE/lineage_zephyr.mk"
grep -q 'vendor/lineage/config/common_full_phone.mk' "$DEVICE_TREE/lineage_zephyr.mk"
grep -q 'vendor/oplus/zephyr/BoardConfigVendor.mk' "$DEVICE_TREE/BoardConfig.mk"
grep -Fq 'KERNEL_PATH := $(DEVICE_PATH)-kernel' "$DEVICE_TREE/BoardConfig.mk"
echo "Device-tree defaults and kernel-output path verified."

echo
echo "===== PixelOS product conversion test with a temporary fixture ====="
FIXTURE="$TMP_ROOT/fixture"
mkdir -p \
  "$FIXTURE/device/oplus/zephyr" \
  "$FIXTURE/vendor/custom/config" \
  "$FIXTURE/vendor/oplus/zephyr" \
  "$FIXTURE/vendor/mediatek/ims" \
  "$FIXTURE/external/libmnl"

cat > "$FIXTURE/device/oplus/zephyr/lineage_zephyr.mk" <<'EOF'
$(call inherit-product, device/oplus/zephyr/device.mk)
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)
PRODUCT_NAME := lineage_zephyr
PRODUCT_DEVICE := zephyr
PRODUCT_MODEL := RMX3563
EOF
: > "$FIXTURE/device/oplus/zephyr/device.mk"
: > "$FIXTURE/vendor/custom/config/common_full_phone.mk"
: > "$FIXTURE/vendor/oplus/zephyr/BoardConfigVendor.mk"
: > "$FIXTURE/vendor/mediatek/ims/ims.mk"

cat > "$FIXTURE/vendor/oplus/zephyr/Android.bp" <<'EOF'
cc_prebuilt_library_shared {
    name: "prebuilt_vendor.mediatek.hardware.bluetooth.audio@2.1",
    srcs: ["proprietary/vendor/lib64/vendor.mediatek.hardware.bluetooth.audio@2.1.so"],
    target: {
        android_arm64: {
            srcs: ["proprietary/vendor/lib64/vendor.mediatek.hardware.bluetooth.audio@2.1.so"],
        },
    },
    soc_specific: true,
}

cc_prebuilt_library_shared {
    name: "prebuilt_vendor.mediatek.hardware.bluetooth.audio@2.2",
    srcs: ["proprietary/vendor/lib64/vendor.mediatek.hardware.bluetooth.audio@2.2.so"],
    target: {
        android_arm64: {
            srcs: ["proprietary/vendor/lib64/vendor.mediatek.hardware.bluetooth.audio@2.2.so"],
        },
    },
    soc_specific: true,
}
EOF
git -C "$FIXTURE/vendor/oplus/zephyr" init -q
git -C "$FIXTURE/vendor/oplus/zephyr" config user.name "Preflight"
git -C "$FIXTURE/vendor/oplus/zephyr" config user.email "preflight@example.invalid"
git -C "$FIXTURE/vendor/oplus/zephyr" add Android.bp
git -C "$FIXTURE/vendor/oplus/zephyr" commit -qm "fixture baseline vendor bp"


cat > "$FIXTURE/external/libmnl/Android.bp" <<'EOF'
cc_library_shared {
    name: "libmnl",
    srcs: ["src/*.c"],
    vendor_available: true,
    visibility: ["//vendor:__subpackages__"],
}
EOF

bash scripts/prepare_device.sh "$FIXTURE"

grep -q 'PRODUCT_NAME := custom_zephyr' "$FIXTURE/device/oplus/zephyr/custom_zephyr.mk"
grep -q 'vendor/custom/config/common_full_phone.mk' "$FIXTURE/device/oplus/zephyr/custom_zephyr.mk"
grep -Fq '$(LOCAL_DIR)/custom_zephyr.mk' "$FIXTURE/device/oplus/zephyr/AndroidProducts.mk"
if grep -Fq 'PRODUCT_NAME := lineage_zephyr' "$FIXTURE/device/oplus/zephyr/AndroidProducts.mk"; then
  echo "Unexpected product assignment in AndroidProducts.mk" >&2
  exit 1
fi
grep -q 'PixelOS integration' "$FIXTURE/device/oplus/zephyr/vendorsetup.sh"
if grep -Eq '^[[:space:]]*vendor_available[[:space:]]*:[[:space:]]*true' "$FIXTURE/external/libmnl/Android.bp"; then
  echo "AOSP external/libmnl still exposes the conflicting vendor variant." >&2
  exit 1
fi
grep -q 'PIXEL_OS_ZEPHYR_ANDROID17_LIBMNL_PARTITION_FIX' "$FIXTURE/external/libmnl/Android.bp"
if grep -Eq 'name:[[:space:]]*"prebuilt_vendor\.mediatek\.hardware\.bluetooth\.audio@2\.[12]"' "$FIXTURE/vendor/oplus/zephyr/Android.bp"; then
  echo "Duplicate vendor Bluetooth HIDL interface prebuilts remain after preparation." >&2
  exit 1
fi
grep -q 'PIXEL_OS_ZEPHYR_ANDROID17_BT_HIDL_PREBUILT_FIX' "$FIXTURE/vendor/oplus/zephyr/Android.bp"
echo "PixelOS product, libmnl, and Bluetooth HIDL compatibility fixtures passed."

bash scripts/restore_before_sync.sh "$FIXTURE"
grep -Eq '^[[:space:]]*vendor_available[[:space:]]*:[[:space:]]*true' "$FIXTURE/external/libmnl/Android.bp"
if grep -q 'PIXEL_OS_ZEPHYR_ANDROID17_LIBMNL_PARTITION_FIX' "$FIXTURE/external/libmnl/Android.bp"; then
  echo "Restore left the libmnl patch marker behind." >&2
  exit 1
fi
grep -q 'name: "prebuilt_vendor.mediatek.hardware.bluetooth.audio@2.1"' "$FIXTURE/vendor/oplus/zephyr/Android.bp"
grep -q 'name: "prebuilt_vendor.mediatek.hardware.bluetooth.audio@2.2"' "$FIXTURE/vendor/oplus/zephyr/Android.bp"
if grep -q 'PIXEL_OS_ZEPHYR_ANDROID17_BT_HIDL_PREBUILT_FIX' "$FIXTURE/vendor/oplus/zephyr/Android.bp"; then
  echo "Restore left the Bluetooth HIDL patch marker behind." >&2
  exit 1
fi
echo "Generated product edits and Android 17 compatibility patches restore cleanly."

bash scripts/restore_before_sync.sh "$FIXTURE"
grep -Eq '^[[:space:]]*vendor_available[[:space:]]*:[[:space:]]*true' "$FIXTURE/external/libmnl/Android.bp"
if grep -q 'PIXEL_OS_ZEPHYR_ANDROID17_LIBMNL_PARTITION_FIX' "$FIXTURE/external/libmnl/Android.bp"; then
  echo "Restore left the libmnl patch marker behind." >&2
  exit 1
fi
echo "Generated product edits and libmnl compatibility patch restore cleanly."

echo
echo "===== Repo-client isolation test against an ancestor Crave checkout ====="
ISO_ROOT="$TMP_ROOT/repo-isolation"
ISO_WORKSPACE="$ISO_ROOT/workspace"
ISO_SRC="$ISO_WORKSPACE/pixelos-seventeen-zephyr-src"
ISO_BIN="$ISO_ROOT/fake-bin"
mkdir -p "$ISO_WORKSPACE/.repo/repo" "$ISO_SRC" "$ISO_BIN"
printf 'parent-client\n' > "$ISO_WORKSPACE/.repo/repo/main.py"
cat > "$ISO_BIN/repo" <<'FAKE_REPO'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "init" ]] || { echo "Unexpected fake repo command" >&2; exit 2; }
[[ ! -e "$ISO_WORKSPACE/.repo/repo/main.py" ]] || {
  echo "Ancestor Repo client was not isolated before init." >&2
  exit 3
}
mkdir -p .repo/repo
printf 'nested-client\n' > .repo/repo/main.py
printf '%s\n' "$PWD" > init.cwd
FAKE_REPO
chmod +x "$ISO_BIN/repo"
ISO_WORKSPACE="$ISO_WORKSPACE" PATH="$ISO_BIN:$PATH" \
  bash scripts/init_repo_isolated.sh "$ISO_WORKSPACE" "$ISO_SRC" \
  "https://example.invalid/android_manifest.git" "seventeen"
grep -qx 'parent-client' "$ISO_WORKSPACE/.repo/repo/main.py"
grep -qx 'nested-client' "$ISO_SRC/.repo/repo/main.py"
grep -qx "$ISO_SRC" "$ISO_SRC/init.cwd"
if find "$ISO_WORKSPACE/.repo" -maxdepth 1 -name 'repo-pixelos-backup.*' -print -quit | grep -q .; then
  echo "Temporary Crave repo-tool backup was not restored/cleaned." >&2
  exit 1
fi
echo "Isolated Repo init passed; parent Crave repo tool was restored intact."

echo
echo "===== Real Repo launcher isolation smoke test ====="
REAL_ROOT="$TMP_ROOT/real-repo-isolation"
REAL_WORKSPACE="$REAL_ROOT/workspace"
REAL_SRC="$REAL_WORKSPACE/pixelos-seventeen-zephyr-src"
REAL_BIN="$REAL_ROOT/bin"
mkdir -p "$REAL_WORKSPACE/.repo/repo" "$REAL_SRC" "$REAL_BIN"
printf 'parent-client-marker\n' > "$REAL_WORKSPACE/.repo/repo/main.py"
curl -fLsS https://storage.googleapis.com/git-repo-downloads/repo -o "$REAL_BIN/repo"
chmod +x "$REAL_BIN/repo"
PATH="$REAL_BIN:$PATH" bash scripts/init_repo_isolated.sh \
  "$REAL_WORKSPACE" "$REAL_SRC" \
  "https://github.com/PixelOS-AOSP/android_manifest.git" "seventeen"
grep -qx 'parent-client-marker' "$REAL_WORKSPACE/.repo/repo/main.py"
test -f "$REAL_SRC/.repo/repo/main.py"
test -f "$REAL_SRC/.repo/manifests/default.xml"
if find "$REAL_WORKSPACE/.repo" -maxdepth 1 -name 'repo-pixelos-backup.*' -print -quit | grep -q .; then
  echo "Real Repo test left the parent-client backup behind." >&2
  exit 1
fi
echo "Official Repo launcher initialized PixelOS manifests inside the independent source tree and restored the parent client."

echo
echo "===== CI precheck completed (manifest init only; no Android repo sync; no ROM compilation) ====="
