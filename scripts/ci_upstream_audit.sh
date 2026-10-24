#!/usr/bin/env bash
# Extended, low-bandwidth compatibility audit against current upstream branches.
# This deliberately fetches real Android.bp/makefiles, not a complete Android tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
cleanup() {
  echo
  echo "===== Disk usage before upstream-audit cleanup ====="
  df -hT "$TMP_ROOT" || true
  rm -rf "$TMP_ROOT"
  echo "===== Disk usage after upstream-audit cleanup ====="
  df -hT "$ROOT" || true
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '\n===== %s =====\n' "$*"; }

log "Generate the live device manifest and validate every selected default branch"
MANIFEST="$TMP_ROOT/zephyr.xml"
PROJECTS="$TMP_ROOT/projects.tsv"
bash "$ROOT/scripts/write_manifest.sh" > "$MANIFEST"
python3 - "$MANIFEST" "$PROJECTS" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = ET.parse(sys.argv[1]).getroot()
remotes = {node.attrib["name"]: node.attrib["fetch"].rstrip("/") for node in root.findall("remote")}
with Path(sys.argv[2]).open("w", encoding="utf-8") as output:
    for project in root.findall("project"):
        path = project.attrib["path"]
        name = project.attrib["name"]
        fetch = remotes[project.attrib["remote"]]
        url = f"{fetch}/{name}"
        if not url.endswith(".git"):
            url += ".git"
        branch = project.attrib["revision"]
        if not branch or branch.startswith("refs/tags/"):
            raise SystemExit(f"Expected a branch revision for {path}, got {branch!r}")
        output.write(f"{path}\t{url}\t{branch}\n")
PY

project_value() {
  local wanted="$1"
  local column="$2"
  awk -F '\t' -v path="$wanted" -v col="$column" '$1 == path { print $col; found=1; exit } END { if (!found) exit 1 }' "$PROJECTS"
}

while IFS=$'\t' read -r project_path project_url project_branch; do
  ref="refs/heads/$project_branch"
  if ! git ls-remote "$project_url" "$ref" | awk -v wanted="$ref" '$2 == wanted { found=1 } END { exit !found }'; then
    die "Selected default branch is not fetchable: $project_path -> $project_branch ($project_url)"
  fi
  printf 'OK default branch: %-44s %s\n' "$project_path" "$project_branch"
done < "$PROJECTS"

clone_sparse() {
  local url="$1"
  local branch="$2"
  local destination="$3"
  local kind="$4"
  local label="$5"
  local tree_file="$TMP_ROOT/$label.tree"
  local selected_file="$TMP_ROOT/$label.selected"

  echo "Fetching tree metadata for $label ($branch)"
  git clone --filter=blob:none --depth=1 --no-checkout --single-branch \
    --branch "$branch" "$url" "$destination"
  git -C "$destination" ls-tree -r --name-only HEAD > "$tree_file"

  python3 - "$tree_file" "$selected_file" "$kind" <<'PY'
import sys
from pathlib import Path

tree_file, selected_file, kind = sys.argv[1:]
paths = Path(tree_file).read_text(encoding="utf-8").splitlines()
if kind == "vendor":
    selected = [
        p for p in paths
        if p.endswith("/Android.bp") or p == "Android.bp"
        or p in {"BoardConfigVendor.mk", "zephyr-vendor.mk", "proprietary-files.txt"}
    ]
elif kind == "mediatek":
    selected = [
        p for p in paths
        if p in {
            "interfaces/hardware/bluetooth/audio/2.1/Android.bp",
            "interfaces/hardware/bluetooth/audio/2.2/Android.bp",
            "configs/properties/vendor_logtag.mk",
        }
        or p.startswith("libion_mtk/")
        or p.startswith("libmtkperf_client/")
    ]
elif kind == "kernel":
    selected = [
        p for p in paths
        if p in {
            "Image.gz",
            "dtb/mt6895.dtb",
            "modules/vendor_dlkm.modules.load",
            "modules/vendor_ramdisk.modules.load",
            "modules/vendor_ramdisk.modules.load.recovery",
        }
    ]
else:
    raise SystemExit(f"Unknown sparse checkout profile: {kind}")

if not selected:
    raise SystemExit(f"No tracked files matched profile {kind}; upstream layout may have changed.")
Path(selected_file).write_text("".join("/" + p + "\n" for p in selected), encoding="utf-8")
print(f"Tree contains {len(paths)} tracked paths; checking out {len(selected)} selected source/config files.")
PY

  [[ -s "$selected_file" ]] || die "No selected files for $label"
  git -C "$destination" sparse-checkout init --no-cone
  cp "$selected_file" "$destination/.git/info/sparse-checkout"
  git -C "$destination" config core.sparseCheckout true
  git -C "$destination" checkout --force --quiet HEAD
}

log "Clone real current device tree and inspect actual vendor / hardware / kernel metadata"
SRC="$TMP_ROOT/source"
mkdir -p "$SRC/device/oplus" "$SRC/vendor/oplus" "$SRC/vendor/mediatek" "$SRC/hardware"
DEVICE_URL="$(project_value device/oplus/zephyr 2)"
DEVICE_BRANCH="$(project_value device/oplus/zephyr 3)"
VENDOR_URL="$(project_value vendor/oplus/zephyr 2)"
VENDOR_BRANCH="$(project_value vendor/oplus/zephyr 3)"
MTK_URL="$(project_value hardware/mediatek 2)"
MTK_BRANCH="$(project_value hardware/mediatek 3)"
KERNEL_URL="$(project_value device/oplus/zephyr-kernel 2)"
KERNEL_BRANCH="$(project_value device/oplus/zephyr-kernel 3)"
IMS_URL="$(project_value vendor/mediatek/ims 2)"
IMS_BRANCH="$(project_value vendor/mediatek/ims 3)"

git clone --depth=1 --single-branch --branch "$DEVICE_BRANCH" \
  "$DEVICE_URL" "$SRC/device/oplus/zephyr"
clone_sparse "$VENDOR_URL" "$VENDOR_BRANCH" "$SRC/vendor/oplus/zephyr" vendor vendor
clone_sparse "$MTK_URL" "$MTK_BRANCH" "$SRC/hardware/mediatek" mediatek mediatek
clone_sparse "$KERNEL_URL" "$KERNEL_BRANCH" "$TMP_ROOT/kernel-output" kernel kernel-output
git clone --filter=blob:none --depth=1 --single-branch --branch "$IMS_BRANCH" \
  "$IMS_URL" "$SRC/vendor/mediatek/ims"

grep -Fq 'system_ext_specific: true' "$SRC/hardware/mediatek/interfaces/hardware/bluetooth/audio/2.1/Android.bp" \
  || die "Bluetooth HIDL 2.1 source module is no longer system_ext-specific; review the workaround."
grep -Fq 'name: "vendor.mediatek.hardware.bluetooth.audio@2.1"' \
  "$SRC/hardware/mediatek/interfaces/hardware/bluetooth/audio/2.1/Android.bp" \
  || die "Bluetooth HIDL 2.1 source module name changed."
grep -Fq 'system_ext_specific: true' "$SRC/hardware/mediatek/interfaces/hardware/bluetooth/audio/2.2/Android.bp" \
  || die "Bluetooth HIDL 2.2 source module is no longer system_ext-specific; review the workaround."
grep -Fq 'name: "vendor.mediatek.hardware.bluetooth.audio@2.2"' \
  "$SRC/hardware/mediatek/interfaces/hardware/bluetooth/audio/2.2/Android.bp" \
  || die "Bluetooth HIDL 2.2 source module name changed."
[[ -f "$SRC/vendor/mediatek/ims/ims.mk" ]] || die "IMS default branch is missing ims.mk."
echo "Bluetooth HIDL source definitions match the partition assumptions."

KERNEL_TREE="$TMP_ROOT/kernel-output.tree"
git -C "$TMP_ROOT/kernel-output" ls-tree -r --name-only HEAD > "$KERNEL_TREE"
for required in Image.gz dtb/mt6895.dtb modules/vendor_dlkm.modules.load modules/vendor_ramdisk.modules.load modules/vendor_ramdisk.modules.load.recovery; do
  grep -Fxq "$required" "$KERNEL_TREE" || die "Prebuilt kernel default branch is missing $required."
done
for load_file in \
  "$TMP_ROOT/kernel-output/modules/vendor_dlkm.modules.load" \
  "$TMP_ROOT/kernel-output/modules/vendor_ramdisk.modules.load" \
  "$TMP_ROOT/kernel-output/modules/vendor_ramdisk.modules.load.recovery"; do
  while IFS= read -r module; do
    [[ -n "$module" ]] || continue
    [[ "$module" == \#* ]] && continue
    grep -Fxq "modules/$module" "$KERNEL_TREE" || die "Kernel module list references missing file: $module"
  done < "$load_file"
done
for module in bt_drv_6895.ko connfem.ko conninfra.ko fmradio_drv_connac2x.ko gps_drv_dl_v050.ko gps_pwr.ko gps_scp.ko wlan_drv_gen4m_6895.ko wmt_chrdev_wifi_connac2.ko; do
  grep -Fxq "modules/$module" "$KERNEL_TREE" || die "BoardConfig expects missing prebuilt module: $module"
done
echo "Prebuilt kernel branch contains Image.gz, mt6895.dtb, load lists, and every referenced module path."

log "Fetch the exact Android 17 AOSP external/libmnl revision used by the PixelOS manifest"
git clone --depth=1 --single-branch --branch android-17.0.0_r1 \
  https://android.googlesource.com/platform/external/libmnl "$SRC/external/libmnl"
LIBMNL_BP="$SRC/external/libmnl/Android.bp"
[[ -f "$LIBMNL_BP" ]] || die "AOSP Android 17 external/libmnl/Android.bp was not found."
grep -Fq 'name: "libmnl"' "$LIBMNL_BP" || die "Expected AOSP libmnl module missing from Android.bp."
grep -Fq 'vendor_available: true' "$LIBMNL_BP" || die "Upstream libmnl source no longer has the vendor_available collision; re-review this patch."

log "Run prepare/patch/restore against actual upstream files"
[[ -f "$SRC/device/oplus/zephyr/BoardConfig.mk" ]] || die "Device tree has no BoardConfig.mk."
[[ -f "$SRC/vendor/oplus/zephyr/BoardConfigVendor.mk" ]] || die "Vendor default branch has no BoardConfigVendor.mk."
[[ -f "$SRC/vendor/oplus/zephyr/zephyr-vendor.mk" ]] || die "Vendor default branch has no zephyr-vendor.mk."
[[ -f "$SRC/vendor/oplus/zephyr/proprietary-files.txt" ]] || die "Vendor sparse checkout omitted proprietary-files.txt."
grep -Fq 'vendor/lib64/vendor.mediatek.hardware.bluetooth.audio@2.1.so' "$SRC/vendor/oplus/zephyr/proprietary-files.txt" \
  || die "Bluetooth audio 2.1 proprietary blob was not found in vendor file list."
grep -Fq 'vendor/lib64/vendor.mediatek.hardware.bluetooth.audio@2.2.so' "$SRC/vendor/oplus/zephyr/proprietary-files.txt" \
  || die "Bluetooth audio 2.2 proprietary blob was not found in vendor file list."
for version in 2.1 2.2; do
  grep -R -E --include='Android.bp' -q "name:[[:space:]]*\"prebuilt_vendor\\.mediatek\\.hardware\\.bluetooth\\.audio@$version\"" "$SRC/vendor/oplus/zephyr" \
    || die "Expected real vendor prebuilt module for Bluetooth audio $version was not found."
done

mkdir -p "$SRC/vendor/custom/config"
touch "$SRC/vendor/custom/config/common_full_phone.mk"
bash "$ROOT/scripts/prepare_device.sh" "$SRC"

python3 - "$LIBMNL_BP" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
modules = list(re.finditer(
    r'(?ms)^[ \t]*cc_library_shared[ \t]*\{[ \t]*\n'
    r'[ \t]*name:[ \t]*"libmnl",[^\n]*\n(?P<body>.*?)^[ \t]*\}',
    text,
))
if len(modules) != 1:
    raise SystemExit(f"Expected exactly one libmnl module after patch, found {len(modules)}")
body = modules[0].group("body")
if "PIXEL_OS_ZEPHYR_ANDROID17_LIBMNL_PARTITION_FIX" not in body:
    raise SystemExit("Actual upstream libmnl patch marker not found in module body.")
if re.search(r'(?m)^[ \t]*vendor_available[ \t]*:[ \t]*true,[ \t]*$', body):
    raise SystemExit("Actual upstream libmnl still exposes the conflicting vendor variant.")
print("Actual Android 17 libmnl source was patched to system-only.")
PY

for version in 2.1 2.2; do
  if grep -R -E --include='Android.bp' -q "name:[[:space:]]*\"prebuilt_vendor\\.mediatek\\.hardware\\.bluetooth\\.audio@$version\"" "$SRC/vendor/oplus/zephyr"; then
    die "Duplicate vendor Bluetooth HIDL $version module remains after patch."
  fi
done
grep -R -q 'PIXEL_OS_ZEPHYR_ANDROID17_BT_HIDL_PREBUILT_FIX' "$SRC/vendor/oplus/zephyr" --include='Android.bp' \
  || die "Bluetooth HIDL patch marker missing from actual vendor Android.bp files."
echo "Both actual vendor HIDL prebuilts were removed; their proprietary blobs remain listed."

bash "$ROOT/scripts/restore_before_sync.sh" "$SRC"
git -C "$SRC/device/oplus/zephyr" diff --check
git -C "$SRC/vendor/oplus/zephyr" diff --check
git -C "$SRC/external/libmnl" diff --check
git -C "$SRC/device/oplus/zephyr" diff --quiet || die "Device-tree generated edits were not fully restored."
git -C "$SRC/vendor/oplus/zephyr" diff --quiet || die "Vendor Android.bp edits were not fully restored."
git -C "$SRC/external/libmnl" diff --quiet || die "AOSP libmnl edit was not fully restored."
echo "Actual upstream patch/restore cycle leaves device, vendor, and AOSP Git worktrees clean."

log "Upstream compatibility audit completed successfully"
