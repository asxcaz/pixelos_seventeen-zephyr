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

echo "===== Runner resources (before tests) ====="
df -hT
df -ih
free -h || true
printf 'CPUs: '; nproc
for path in /usr/local/lib/android/sdk /opt/hostedtoolcache /usr/share/dotnet /usr/local/share/boost /usr/local/share/powershell; do
  if [[ -d "$path" ]]; then du -sh "$path" 2>/dev/null || true; fi
done

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
grep -q 'device/oplus/zephyr-kernel' "$DEVICE_TREE/BoardConfig.mk"
echo "Device-tree defaults and kernel-output path verified."

echo
echo "===== PixelOS product conversion test with a temporary fixture ====="
FIXTURE="$TMP_ROOT/fixture"
mkdir -p \
  "$FIXTURE/device/oplus/zephyr" \
  "$FIXTURE/vendor/custom/config" \
  "$FIXTURE/vendor/oplus/zephyr" \
  "$FIXTURE/vendor/mediatek/ims"

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

bash scripts/prepare_device.sh "$FIXTURE"

grep -q 'PRODUCT_NAME := custom_zephyr' "$FIXTURE/device/oplus/zephyr/custom_zephyr.mk"
grep -q 'vendor/custom/config/common_full_phone.mk' "$FIXTURE/device/oplus/zephyr/custom_zephyr.mk"
grep -q '$(LOCAL_DIR)/custom_zephyr.mk' "$FIXTURE/device/oplus/zephyr/AndroidProducts.mk"
grep -q 'PRODUCT_NAME := lineage_zephyr' "$FIXTURE/device/oplus/zephyr/AndroidProducts.mk" && {
  echo "Unexpected product assignment in AndroidProducts.mk" >&2
  exit 1
} || true
grep -q 'PixelOS integration' "$FIXTURE/device/oplus/zephyr/vendorsetup.sh"
echo "PixelOS product conversion fixture passed."

echo
echo "===== CI precheck completed (no Android repo sync; no ROM compilation) ====="
