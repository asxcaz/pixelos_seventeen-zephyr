#!/usr/bin/env bash
# Extended, low-bandwidth compatibility audit against current upstream branches.
# This fetches real device/vendor/hardware configs, not a complete Android tree.
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

log "Resolve live default branches and verify all seven project refs"
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
            raise SystemExit(f"Expected branch revision for {path}, got {branch!r}")
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
        or p.endswith("/Android.mk") or p == "Android.mk"
        or p.endswith(".mk")
    ]
elif kind == "mediatek":
    selected = [
        p for p in paths
        if p.endswith("/Android.bp") or p == "Android.bp"
        or p in {"configs/properties/vendor_logtag.mk"}
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
elif kind == "kernel-source":
    selected = [p for p in paths if p == "Makefile"]
else:
    raise SystemExit(f"Unknown sparse checkout profile: {kind}")

if not selected:
    raise SystemExit(f"No tracked files matched profile {kind}; upstream layout may have changed.")
Path(selected_file).write_text("".join("/" + p + "\n" for p in selected), encoding="utf-8")
print(f"Tree contains {len(paths)} tracked paths; checking out {len(selected)} source/config files.")
PY

  [[ -s "$selected_file" ]] || die "No selected files for $label"
  git -C "$destination" sparse-checkout init --no-cone
  cp "$selected_file" "$destination/.git/info/sparse-checkout"
  git -C "$destination" config core.sparseCheckout true
  git -C "$destination" checkout --force --quiet HEAD
}

audit_hidl_vendor_overlap() {
  python3 - "$SRC/hardware/mediatek" "$SRC/hardware/oplus" "$SRC/device/oplus/zephyr" "$SRC/vendor/oplus/zephyr" "$1" <<'PY'
from pathlib import Path
import re
import sys

source_roots = [Path(value) for value in sys.argv[1:4]]
vendor_root = Path(sys.argv[4])
mode = sys.argv[5]

def brace_delta(line):
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

def blocks(path, start_pattern):
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    start_re = re.compile(start_pattern)
    i = 0
    while i < len(lines):
        if not start_re.match(lines[i]):
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
            raise SystemExit(f"Unbalanced module block in {path}:{start + 1}")
        yield start + 1, "".join(lines[start:end + 1])
        i = end + 1

source_modules = {}
for source_root in source_roots:
    for path in source_root.rglob("Android.bp"):
        try:
            for line_no, module_block in blocks(path, r'^[ \t]*hidl_interface[ \t]*\{'):
                name_match = re.search(r'(?m)^[ \t]*name:[ \t]*"([^"]+)"', module_block)
                if not name_match:
                    continue
                partition = "system_ext" if re.search(r'(?m)^[ \t]*system_ext_specific:[ \t]*true\b', module_block) else "system"
                if re.search(r'(?m)^[ \t]*(?:vendor|soc_specific):[ \t]*true\b', module_block):
                    partition = "vendor"
                if partition != "vendor":
                    source_modules[name_match.group(1)] = (partition, f"{path}:{line_no}")
        except (OSError, UnicodeError):
            continue

vendor_declarations = {}
bp_start = r'^[ \t]*(?:cc_prebuilt_library_shared|cc_prebuilt_library|cc_prebuilt_binary)[ \t]*\{'
for path in vendor_root.rglob("Android.bp"):
    try:
        for line_no, block in blocks(path, bp_start):
            name_match = re.search(r'(?m)^[ \t]*name:[ \t]*"([^"]+)"', block)
            if not name_match:
                continue
            name = name_match.group(1)
            normalized = name[len("prebuilt_"):] if name.startswith("prebuilt_") else name
            vendor_declarations.setdefault(normalized, []).append(f"{path}:{line_no} (Android.bp {name})")
    except (OSError, UnicodeError):
        continue

make_section_re = re.compile(
    r'(?ims)^[ \t]*include[ \t]+\$\([ \t]*CLEAR_VARS[ \t]*\)[ \t]*\r?\n'
    r'.*?^[ \t]*include[ \t]+\$\([ \t]*BUILD_[A-Z0-9_]+[ \t]*\)[ \t]*(?:#.*)?(?:\r?\n|$)'
)
local_module_re = re.compile(r'(?m)^[ \t]*LOCAL_MODULE[ \t]*:?=[ \t]*(?:prebuilt_)?([A-Za-z0-9_.@+-]+)[ \t]*(?:#.*)?$')
makefiles = set(vendor_root.rglob("Android.mk")) | set(vendor_root.rglob("*.mk"))
for path in makefiles:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        continue
    for section in make_section_re.finditer(text):
        name_match = local_module_re.search(section.group(0))
        if name_match:
            vendor_declarations.setdefault(name_match.group(1), []).append(f"{path}:Android.mk")

overlaps = {
    name: locations
    for name, locations in vendor_declarations.items()
    if name in source_modules and source_modules[name][0] in {"system", "system_ext"}
}
expected = {
    "vendor.mediatek.hardware.bluetooth.audio@2.1",
    "vendor.mediatek.hardware.bluetooth.audio@2.2",
    "vendor.mediatek.hardware.lbs@1.0",
    "vendor.mediatek.hardware.mtkradioex@2.0",
    "vendor.mediatek.hardware.mtkradioex@3.0",
    "vendor.mediatek.hardware.netdagent@1.0",
}
if mode == "before":
    if set(overlaps) != expected:
        details = [
            f"{name}: source={source_modules[name][0]} at {source_modules[name][1]}; vendor={locations}"
            for name, locations in sorted(overlaps.items())
        ]
        raise SystemExit(
            "Unexpected source/vendor HIDL overlap inventory. "
            f"Missing expected={sorted(expected - set(overlaps))}; "
            f"extra possible conflicts={sorted(set(overlaps) - expected)}; details=" + " | ".join(details)
        )
    for name, locations in sorted(overlaps.items()):
        print(f"Detected expected Soong partition collision: {name}; source={source_modules[name][0]} at {source_modules[name][1]}; vendor={locations}")
elif mode == "after":
    if overlaps:
        details = [
            f"{name}: source={source_modules[name][0]} at {source_modules[name][1]}; vendor={locations}"
            for name, locations in sorted(overlaps.items())
        ]
        raise SystemExit("Unresolved source/vendor HIDL overlaps after patch: " + " | ".join(details))
    print(f"No source HIDL/vendor prebuilt overlaps remain across {len(source_modules)} target-device HIDL modules.")
else:
    raise SystemExit(f"Unknown overlap audit mode: {mode}")
PY
}

log "Clone current device tree plus sparse vendor, MediaTek hardware, and kernel outputs"
SRC="$TMP_ROOT/source"
mkdir -p "$SRC/device/oplus" "$SRC/vendor/oplus" "$SRC/vendor/mediatek" "$SRC/hardware"

DEVICE_URL="$(project_value device/oplus/zephyr 2)"
DEVICE_BRANCH="$(project_value device/oplus/zephyr 3)"
VENDOR_URL="$(project_value vendor/oplus/zephyr 2)"
VENDOR_BRANCH="$(project_value vendor/oplus/zephyr 3)"
MTK_URL="$(project_value hardware/mediatek 2)"
MTK_BRANCH="$(project_value hardware/mediatek 3)"
OPLUS_HW_URL="$(project_value hardware/oplus 2)"
OPLUS_HW_BRANCH="$(project_value hardware/oplus 3)"
KERNEL_URL="$(project_value device/oplus/zephyr-kernel 2)"
KERNEL_BRANCH="$(project_value device/oplus/zephyr-kernel 3)"
IMS_URL="$(project_value vendor/mediatek/ims 2)"
IMS_BRANCH="$(project_value vendor/mediatek/ims 3)"

git clone --depth=1 --single-branch --branch "$DEVICE_BRANCH" "$DEVICE_URL" "$SRC/device/oplus/zephyr"
clone_sparse "$VENDOR_URL" "$VENDOR_BRANCH" "$SRC/vendor/oplus/zephyr" vendor vendor
clone_sparse "$MTK_URL" "$MTK_BRANCH" "$SRC/hardware/mediatek" mediatek mediatek
clone_sparse "$OPLUS_HW_URL" "$OPLUS_HW_BRANCH" "$SRC/hardware/oplus" mediatek oplus-hardware
clone_sparse "$KERNEL_URL" "$KERNEL_BRANCH" "$TMP_ROOT/kernel-output" kernel kernel-output
git clone --filter=blob:none --depth=1 --single-branch --branch "$IMS_BRANCH" "$IMS_URL" "$SRC/vendor/mediatek/ims"

for version in 2.1 2.2; do
  bp="$SRC/hardware/mediatek/interfaces/hardware/bluetooth/audio/$version/Android.bp"
  [[ -f "$bp" ]] || die "MediaTek hardware default branch is missing Bluetooth HIDL $version Android.bp."
  grep -Fq 'system_ext_specific: true' "$bp" || die "Bluetooth HIDL $version is no longer system_ext-specific; review the workaround."
  grep -Fq "vendor.mediatek.hardware.bluetooth.audio@$version" "$bp" || die "Bluetooth HIDL $version module name changed."
done
[[ -f "$SRC/vendor/mediatek/ims/ims.mk" ]] || die "IMS default branch is missing ims.mk."
echo "MediaTek Bluetooth HIDL sources and IMS makefile verified."

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
echo "Prebuilt kernel tree contains Image.gz, mt6895.dtb, load lists, and all referenced module paths."

log "Compare the live kernel-source default branch with the actual prebuilt kernel image"
KERNEL_SOURCE_URL="https://github.com/oplus-mt6895/android_kernel_oplus_mt6895.git"
KERNEL_SOURCE_BRANCH="$(git ls-remote --symref "$KERNEL_SOURCE_URL" HEAD 2>/dev/null | awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2; exit }')"
[[ -n "$KERNEL_SOURCE_BRANCH" ]] || die "Could not resolve the kernel-source repository's current default branch."
clone_sparse "$KERNEL_SOURCE_URL" "$KERNEL_SOURCE_BRANCH" "$TMP_ROOT/kernel-source" kernel-source kernel-source
kernel_source_version="$(awk -F '=' '
  /^VERSION[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); v=$2 }
  /^PATCHLEVEL[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); p=$2 }
  /^SUBLEVEL[[:space:]]*=/ { gsub(/[[:space:]]/, "", $2); s=$2 }
  END { if (v == "" || p == "" || s == "") exit 1; printf "%s.%s.%s\n", v, p, s }
' "$TMP_ROOT/kernel-source/Makefile")" || die "Could not parse kernel source version from upstream Makefile."
gzip -t "$TMP_ROOT/kernel-output/Image.gz" || die "Prebuilt Image.gz is not a valid gzip stream."
gzip -dc "$TMP_ROOT/kernel-output/Image.gz" > "$TMP_ROOT/kernel-image.uncompressed"
strings -a "$TMP_ROOT/kernel-image.uncompressed" > "$TMP_ROOT/kernel-image.strings"
kernel_output_version="$(awk '/Linux version [0-9]+\\.[0-9]+\\.[0-9]+/ { sub(/^.*Linux version /, \"\"); sub(/[[:space:]].*$/, \"\"); print; exit }' \"$TMP_ROOT/kernel-image.strings\")"
[[ -n "$kernel_output_version" ]] || die "Could not extract Linux version string from prebuilt Image.gz."
echo "Kernel source: $KERNEL_SOURCE_BRANCH -> $kernel_source_version"
echo "Prebuilt kernel image: $kernel_output_version (from $KERNEL_BRANCH)"
if [[ "$kernel_source_version" != "$kernel_output_version" ]]; then
  echo "NOTE: source and prebuilt versions differ; current ROM config explicitly uses the prebuilt kernel output tree."
fi

log "Fetch the exact Android 17 AOSP external/libmnl revision used by PixelOS"
git clone --depth=1 --single-branch --branch android-17.0.0_r1 \
  https://android.googlesource.com/platform/external/libmnl "$SRC/external/libmnl"
LIBMNL_BP="$SRC/external/libmnl/Android.bp"
[[ -f "$LIBMNL_BP" ]] || die "AOSP Android 17 external/libmnl/Android.bp was not found."
grep -Fq 'name: "libmnl"' "$LIBMNL_BP" || die "Expected AOSP libmnl module missing from Android.bp."
grep -Fq 'vendor_available: true' "$LIBMNL_BP" || die "Upstream libmnl no longer has the known vendor-variant collision; review the patch."

log "Verify actual vendor module declarations before patching"
[[ -f "$SRC/device/oplus/zephyr/BoardConfig.mk" ]] || die "Device tree has no BoardConfig.mk."
[[ -f "$SRC/vendor/oplus/zephyr/BoardConfigVendor.mk" ]] || die "Vendor default branch has no BoardConfigVendor.mk."
[[ -f "$SRC/vendor/oplus/zephyr/zephyr-vendor.mk" ]] || die "Vendor default branch has no zephyr-vendor.mk."
[[ -f "$SRC/device/oplus/zephyr/proprietary-files.txt" ]] || die "Device tree has no proprietary-files.txt."
for blob in \
  vendor/lib64/vendor.mediatek.hardware.bluetooth.audio@2.1.so \
  vendor/lib64/vendor.mediatek.hardware.bluetooth.audio@2.2.so \
  vendor/lib64/vendor.mediatek.hardware.lbs@1.0.so \
  vendor/lib64/vendor.mediatek.hardware.mtkradioex@2.0.so \
  vendor/lib64/vendor.mediatek.hardware.mtkradioex@3.0.so \
  vendor/lib64/vendor.mediatek.hardware.netdagent@1.0.so; do
  grep -Fqx "$blob" "$SRC/device/oplus/zephyr/proprietary-files.txt" \
    || die "Expected proprietary blob entry was not found: $blob"
done
audit_hidl_vendor_overlap before

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

audit_hidl_vendor_overlap after
if ! grep -R -q 'PIXEL_OS_ZEPHYR_ANDROID17_BT_HIDL_PREBUILT_FIX' "$SRC/vendor/oplus/zephyr" --include='Android.bp' --include='Android.mk' --include='*.mk'; then
  die "Bluetooth HIDL patch marker missing from actual vendor module files."
fi
echo "All six real source/vendor HIDL collisions were removed; all six proprietary blob entries remain intact."

bash "$ROOT/scripts/restore_before_sync.sh" "$SRC"
git -C "$SRC/device/oplus/zephyr" diff --check
git -C "$SRC/vendor/oplus/zephyr" diff --check
git -C "$SRC/external/libmnl" diff --check
git -C "$SRC/device/oplus/zephyr" diff --quiet || die "Device-tree generated edits were not fully restored."
git -C "$SRC/vendor/oplus/zephyr" diff --quiet || die "Vendor module edits were not fully restored."
git -C "$SRC/external/libmnl" diff --quiet || die "AOSP libmnl edit was not fully restored."
echo "Actual upstream patch/restore cycle leaves device, vendor, and AOSP worktrees clean."

log "Upstream compatibility audit completed successfully"
