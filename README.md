# PixelOS seventeen — Realme GT Neo 3 / MT6895

Build automation for PixelOS Android 17 using the OPlus MT6895 device-source set and Crave.

## Design

- Crave project ID: `82` (the project label is not the ROM selector).
- ROM manifest: `https://github.com/PixelOS-AOSP/android_manifest.git`, branch `seventeen`.
- Device sources: the repositories listed in [oplus-mt6895/.github](https://github.com/oplus-mt6895/.github/blob/main/profile/README.md).
- The script puts a dedicated source tree in `pixelos-seventeen-zephyr-src/`. It does not build from or sync over the pre-populated Android tree at the root of the Crave project workspace.
- A small config checkout lives in `.pixelos-seventeen-zephyr-config/`.

The local manifest generator resolves the advertised default branch of every device-source remote using `git ls-remote --symref URL HEAD` before writing the manifest. This avoids silently pinning device repositories to guessed LineageOS branches. If a remote does not advertise its default branch, the script stops before syncing.

## Device identity note

The organization profile README calls the Realme GT Neo 3 `lisaa`, while the linked `android_device_oplus_zephyr` default branch defines `PRODUCT_DEVICE := zephyr` and provides `lineage_zephyr.mk` for model `RMX3563`. This build follows that repository's actual product configuration and uses `breakfast zephyr`; it does not assume the profile nickname is the Android product name.

The upstream product makefile currently carries an OnePlus 10R build fingerprint despite the Realme model fields. The integration keeps upstream values rather than inventing a fingerprint; verify/fix product identity values before treating a build as ready to flash.

## Start from Crave Devspace

From the Devspace directory for project 82:

```bash
crave run --projectID 82 --no-patch -- "curl -fLsS https://raw.githubusercontent.com/asxcaz/pixelos_seventeen-zephyr/main/build.sh | bash -s --"
```

The first run initializes and syncs the independent PixelOS source tree, applies the device integration steps, runs `breakfast zephyr`, then `m pixelos`.

Do not add `--clean` casually: Crave's clean workspace is based on the configured project snapshot, not an empty directory, and it discards incremental work from previous jobs.

## Source refresh

Normal reruns reuse the synchronized source tree and output directory to support incremental builds. To deliberately refresh sources, submit:

```bash
crave run --projectID 82 --no-patch -- "curl -fLsS https://raw.githubusercontent.com/asxcaz/pixelos_seventeen-zephyr/main/build.sh | SYNC_SOURCE=1 bash -s --"
```

This resets only build-generated device-tree edits before syncing. Do not use this if you have made manual edits inside `pixelos-seventeen-zephyr-src/` that you want to preserve.

## Device tree integration

The upstream device tree is LineageOS-shaped. The prepare script derives `custom_zephyr.mk` from `lineage_zephyr.mk`, changes the common product include to PixelOS's `vendor/custom/config/common_full_phone.mk`, adds the product to `AndroidProducts.mk`, and replaces the tree's side-effectful `vendorsetup.sh` with a no-op after applying its listed vendor/framework patches explicitly and idempotently.

Those patches can still conflict with PixelOS seventeen's Android 17 baseline. If they do, the script stops and leaves the failing cherry-pick visible in the logs rather than skipping it silently.

## Kernel

The device tree points at the prebuilt kernel-output directory `device/oplus/zephyr-kernel`, so the ROM manifest uses that compiled-output repository. The separate `kernel_manifest`, kernel source, and external kernel-module source repos from the organization README are for rebuilding/developing the kernel and are not added to the initial ROM sync to avoid syncing unused large repositories.

## Notes

- Output is expected under `out/target/product/zephyr/`; the script prints available ZIPs and images at the end.
- This is an initial device integration build setup, not a claim that the ROM has already compiled or booted successfully.
- Before flashing a first build, verify the exact handset model, bootloader state, firmware requirements, product fingerprint, and backup/recovery route.
