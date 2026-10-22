#!/usr/bin/env bash
# Resolve each upstream repository's advertised default branch and emit a repo local manifest.
set -euo pipefail

default_branch() {
  local url="$1"
  local branch
  branch="$(git ls-remote --symref "$url" HEAD 2>/dev/null | awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2; exit }')"
  if [[ -z "$branch" ]]; then
    echo "ERROR: could not discover default branch from $url (git ls-remote --symref)" >&2
    return 1
  fi
  printf '%s\n' "$branch"
}

device_url="https://github.com/oplus-mt6895/android_device_oplus_zephyr.git"
kernel_output_url="https://gitlab.com/NINJAHUNTER1357/android_device_oplus_zephyr-kernel.git"
vendor_url="https://gitlab.com/NINJAHUNTER1357/proprietary_vendor_oplus_zephyr.git"
sepolicy_url="https://github.com/oplus-mt6895/android_device_mediatek_sepolicy_vndr.git"
mediatek_hw_url="https://github.com/oplus-mt6895/android_hardware_mediatek.git"
oplus_hw_url="https://github.com/oplus-mt6895/android_hardware_oplus.git"
ims_url="https://github.com/Adarsh0127-Elite/android_vendor_mediatek_ims.git"

device_branch="$(default_branch "$device_url")"
kernel_output_branch="$(default_branch "$kernel_output_url")"
vendor_branch="$(default_branch "$vendor_url")"
sepolicy_branch="$(default_branch "$sepolicy_url")"
mediatek_hw_branch="$(default_branch "$mediatek_hw_url")"
oplus_hw_branch="$(default_branch "$oplus_hw_url")"
ims_branch="$(default_branch "$ims_url")"

printf 'Default branches selected:\n' >&2
printf '  device tree: %s\n  prebuilt kernel outputs: %s\n  vendor: %s\n  MediaTek SEPolicy: %s\n  MediaTek hardware: %s\n  OPlus hardware: %s\n  MediaTek IMS: %s\n' \
  "$device_branch" "$kernel_output_branch" "$vendor_branch" "$sepolicy_branch" "$mediatek_hw_branch" "$oplus_hw_branch" "$ims_branch" >&2

cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="oplus" fetch="https://github.com/oplus-mt6895" />
  <remote name="zephyr-gitlab" fetch="https://gitlab.com/NINJAHUNTER1357" />
  <remote name="adarsh" fetch="https://github.com/Adarsh0127-Elite" />

  <project name="android_device_oplus_zephyr" path="device/oplus/zephyr" remote="oplus" revision="$device_branch" />
  <project name="android_device_oplus_zephyr-kernel" path="device/oplus/zephyr-kernel" remote="zephyr-gitlab" revision="$kernel_output_branch" />
  <project name="proprietary_vendor_oplus_zephyr" path="vendor/oplus/zephyr" remote="zephyr-gitlab" revision="$vendor_branch" />

  <project name="android_device_mediatek_sepolicy_vndr" path="device/mediatek/sepolicy_vndr" remote="oplus" revision="$sepolicy_branch" />
  <project name="android_hardware_mediatek" path="hardware/mediatek" remote="oplus" revision="$mediatek_hw_branch" />
  <project name="android_hardware_oplus" path="hardware/oplus" remote="oplus" revision="$oplus_hw_branch" />

  <project name="android_vendor_mediatek_ims" path="vendor/mediatek/ims" remote="adarsh" revision="$ims_branch" />
</manifest>
XML
