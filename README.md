# PixelOS seventeen — Realme GT Neo 3 / MT6895

Build automation for PixelOS Android 17 using the OPlus MT6895 device-source set and Crave.

## Design

- Crave project ID: `82` (the project label is not the ROM selector).
- ROM manifest: `https://github.com/PixelOS-AOSP/android_manifest.git`, branch `seventeen`.
- Device sources: the repositories listed in [oplus-mt6895/.github](https://github.com/oplus-mt6895/.github/blob/main/profile/README.md).
- The script puts a dedicated source tree in `pixelos-seventeen-zephyr-src/`. It does not build from or sync over the pre-populated Android tree at the root of the Crave project workspace.
- A small config checkout lives in `.pixelos-seventeen-zephyr-config/`.

The local manifest generator resolves the advertised default branch of every device-source remote using `git ls-remote --symref URL HEAD` before writing the manifest. This avoids silently pinning device repositories to guessed LineageOS branches. If a remote does not advertise its default branch, the script stops before syncing.

## Device identity

This build follows the actual device source: codename `zephyr`, product makefile `lineage_zephyr.mk`, and the model currently set to `RMX3563` in that source. Product names, paths, and lunch choices should follow the checked-out source, not alternate profile nicknames.

The upstream product makefile currently carries an OnePlus 10R build fingerprint despite the Realme model fields. The integration keeps upstream values rather than inventing a fingerprint; verify/fix product identity values before treating a build as ready to flash.

## First Crave run: sync and preflight only

From the Devspace directory for project 82:

```bash
crave run --projectID 82 --no-patch -- "curl -fLsS https://raw.githubusercontent.com/asxcaz/pixelos_seventeen-zephyr/main/build.sh | PREPARE_ONLY=1 bash -s --"
```

**This first run still downloads/syncs the full Android source tree** into `pixelos-seventeen-zephyr-src/`, then prepares the device tree and runs `breakfast zephyr`. It exits before starting the actual ROM compilation. Because this intentionally keeps the Crave project's pre-populated root source untouched, allow for additional disk usage.

Review the sync log and lunch result before submitting the full build:

```bash
crave run --projectID 82 --no-patch -- "curl -fLsS https://raw.githubusercontent.com/asxcaz/pixelos_seventeen-zephyr/main/build.sh | bash -s --"
```

The second command runs `m pixelos`.

Do not add `--clean` casually: Crave's clean workspace is based on the configured project snapshot, not an empty directory, and it discards incremental work from previous jobs.

## Source refresh

Normal reruns reuse the synchronized source tree and output directory to support incremental builds. To deliberately refresh sources, submit:

```bash
crave run --projectID 82 --no-patch -- "curl -fLsS https://raw.githubusercontent.com/asxcaz/pixelos_seventeen-zephyr/main/build.sh | SYNC_SOURCE=1 PREPARE_ONLY=1 bash -s --"
```

This resets only generated device-tree edits before syncing and stops before compilation. Do not use this if you have made manual edits inside `pixelos-seventeen-zephyr-src/` that you want to preserve.

## Device tree integration

The upstream device tree is LineageOS-shaped. The prepare script derives `custom_zephyr.mk` from `lineage_zephyr.mk`, changes the common product include to PixelOS's `vendor/custom/config/common_full_phone.mk`, adds the product to `AndroidProducts.mk`, and replaces the tree's side-effectful `vendorsetup.sh` with a no-op. The MediaTek IMS dependency is declared in the local manifest so envsetup does not need to clone it.

The device tree also lists several MediaTek framework/Aperture cherry-picks from older LineageOS branches. They are **not applied by default** because PixelOS seventeen is Android 17 and some target-file contexts differ. After a first build or a deliberate patch-porting pass, they can be attempted explicitly by setting `APPLY_LEGACY_DEVICE_PATCHES=1`; a conflict stops the script instead of being silently skipped.

## Kernel

The device tree points at the prebuilt kernel-output directory `device/oplus/zephyr-kernel`, so the ROM manifest uses that compiled-output repository. The separate `kernel_manifest`, kernel source, and external kernel-module source repos from the organization README are for rebuilding/developing the kernel and are not added to the initial ROM sync to avoid syncing unused large repositories.

## Notes

- Output is expected under `out/target/product/zephyr/`; the script prints available ROM ZIPs and images at the end.
- This is an initial device integration build setup, not a claim that the ROM has already compiled or booted successfully.
- Before flashing a first build, verify the exact handset model, bootloader state, firmware requirements, product fingerprint, and backup/recovery route.
