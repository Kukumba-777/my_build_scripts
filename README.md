# GKI build and vendor_dlkm tools

[Русская версия](README.ru.md)

Build an Android GKI kernel with Kbuild, build explicitly selected `.ko` files, or replace existing modules in an ext4 `vendor_dlkm` image. The scripts do not connect to a device, flash partitions, or sign images.

| Script | Purpose |
| --- | --- |
| `build-kernel.sh` | Configure/build `Image` and in-tree modules, list configured modules, or build selected in-tree or external modules. |
| `build-qcom-audio.sh` | Build the Qualcomm vendor audio package and export only the selected SPF/LPASS `.ko` files and `Module.symvers`. |
| `repack-vendor-dlkm.py` | List existing modules or replace selected `.ko` files in a new raw ext4 image. |

## Requirements

- **Build:** Linux, Bash 4+, GNU coreutils and GNU Make, `rsync` for external modules, and the LLVM toolchain for your kernel branch (Clang, LLD, and LLVM utilities). The kernel also needs its usual host dependencies, typically `bc`, `bison`, `flex`, OpenSSL and ELF development libraries, and `pahole` for BTF. Use the Android LLVM revision specified by your source tree.
- **Repack:** Python 3.8+, `e2fsprogs` (`debugfs`, `e2fsck`), `kmod` (`modinfo`, `modprobe`), and `readelf` from `binutils`. Sparse input needs `simg2img`; `--strip-debug` needs `llvm-strip`. No root or mounting is needed. Use trusted images and module sources.
- Use paths without spaces for Kbuild. Module builds require a **new** `--dist` directory. In-tree selection copies the kernel output to `$TMPDIR` (default `/tmp`); allow enough space for a full copy if reflinks are unavailable. Don't build concurrently against the same kernel output.

Run the examples below from `my-build-scripts`. Adjust paths, branch and toolchain for your target:

```bash
KERNEL_SRC=../android_kernel_xiaomi_sm8635
LLVM_BIN=../clang-r547379/bin
KERNEL_OUT="$PWD/out/gki"
```

## 1. Build GKI

```bash
./build-kernel.sh kernel \
  --kernel-src "$KERNEL_SRC" --kernel-out "$KERNEL_OUT" \
  --llvm-bin "$LLVM_BIN" --defconfig gki_defconfig --jobs 8 \
  --dist "$PWD/dist/gki"
```

- The default is `ARCH=arm64`, `gki_defconfig`, and one job per logical CPU. `kernel` builds `Image` and all configured in-tree modules. If set, `--dist` copies out `Image` and `Module.symvers`; the `.ko` files stay under `--kernel-out`.
- Use `--config FILE` instead of `--defconfig` to start from an existing config, `--reuse-config` to keep the output tree's config, and repeat `--fragment FILE` to merge config fragments in order. Add `--configure-only` (without `--dist`) to check that Kconfig retained the requested settings before compiling. `--dry-run` prints the planned commands without creating artifacts.
- This is a direct Kbuild workflow, not a replacement for a device's Kleaf/Bazel, certification, or Android packaging pipeline. `Image` is **not** `boot.img`. Keep the output tree and exact source revision/config/toolchain together for later module builds.

## 2. Select any Kbuild module

Use `--module NAME` for an exact `.ko` basename (with or without the extension), or `--target PATH.ko` for a specific path. Both options are repeatable. If more than one module has the same basename, use `--target` to disambiguate. This is not a fixed driver list: the candidates come from Kbuild. A driver built into the kernel is not a `.ko`, and a package that can only be built with Kleaf/DDK or another vendor build system still needs that system.

### In-tree Kbuild module

```bash
./build-kernel.sh list --kernel-out "$KERNEL_OUT"
./build-kernel.sh in-tree \
  --kernel-src "$KERNEL_SRC" --kernel-out "$KERNEL_OUT" \
  --llvm-bin "$LLVM_BIN" --module cfg80211 --module rfkill \
  --dist "$PWD/dist/cfg80211"
```

Choose a name or path from the list. The driver's Kconfig option must be `m`, not `y`; if needed, merge a fragment and rebuild GKI first. If modpost reports unresolved symbols from another in-tree module, include that `.ko` as another target or add `--build-package` to build the full module set and export only the requested files. In-tree module builds run on a temporary output copy so they cannot replace the original `Module.symvers` or `modules.order`. `cfg80211` is kernel Wi-Fi infrastructure, not the vendor WLAN driver.

### External Kbuild module

```bash
./build-kernel.sh external \
  --kernel-src "$KERNEL_SRC" --kernel-out "$KERNEL_OUT" \
  --llvm-bin "$LLVM_BIN" --external-root /path/to/vendor-modules \
  --package drivers/my-driver --module my_driver \
  --dist "$PWD/dist/my-driver"
```

`--package` selects the directory containing the package's `Kbuild` or `Makefile`; omit it if the package is at the root. `--module` builds the package and finds the selected `.ko` in the generated `modules.order`. If you know its path relative to the package, use `--target` to try building just that target. Use `--build-package` with `--target` if individual targets do not work for that package. Use `--all` instead of a selection to build and export the entire package. `--symvers FILE` provides symbol tables from matching dependency builds and is repeatable. Repeat `--set NAME=VALUE` for vendor make variables; `@work@` expands to the copied source root and `@kernel@` to the kernel source. The original external sources are not used as build output.

### Qualcomm vendor WLAN (Poco F6 / Peridot)

The stock Peridot image contains `qca_cld3_qca6750.ko`, not `wlan.ko`. Use the same generic `external` command: first build the WLAN platform package for its symbol table, then select the actual driver by name. The options below match the QCA6750 profile in this vendor source tree; other chipsets and branches may need a different profile or dependencies. Start with new output directories.

```bash
VENDOR_ROOT=../android_kernel_xiaomi_sm8635-modules/qcom/opensource
PERIDOT_OUT=../out/peridot-nosig/kernel
wlan_build=(./build-kernel.sh external
  --kernel-src "$KERNEL_SRC" --kernel-out "$PERIDOT_OUT"
  --llvm-bin "$LLVM_BIN" --external-root "$VENDOR_ROOT" --jobs 6)

"${wlan_build[@]}" --package wlan/platform --all \
  --set 'WLAN_PLATFORM_ROOT=@work@/wlan/platform' \
  --dist "$PWD/dist/peridot-wlan-platform"

"${wlan_build[@]}" --package wlan/qcacld-3.0 --module qca_cld3_qca6750 \
  --set 'WLAN_ROOT=@work@/wlan/qcacld-3.0' \
  --set MODNAME=qca_cld3_qca6750 --set CONFIG_QCA_CLD_WLAN=m \
  --set WLAN_PROFILE=qca6750 --set DYNAMIC_SINGLE_CHIP=qca6750 --set DEVNAME=qca6750 \
  --set CONFIG_IPA_OUT_OF_TREE=y --set CONFIG_QCA_WIFI_ISOC=0 --set CONFIG_QCA_WIFI_2_0=1 \
  --symvers "$PWD/dist/peridot-wlan-platform/Module.symvers" \
  --dist "$PWD/dist/peridot-wlan"
```

Find the driver in `dist/peridot-wlan/qca_cld3_qca6750.ko`. The local `PERIDOT_OUT` is a build example; its `vermagic` differs from stock, so its modules are not drop-in replacements for the stock image.

### Qualcomm SPF and LPASS (example: Poco F6 / Peridot)

```bash
./build-qcom-audio.sh --list
./build-qcom-audio.sh \
  --kernel-src "$KERNEL_SRC" --kernel-out ../out/peridot-nosig/kernel \
  --llvm-bin "$LLVM_BIN" --modules-src ../android_kernel_xiaomi_sm8635-modules \
  --board pineapple --product lineage_peridot --jobs 6 \
  --driver spf --driver lpass --dist "$PWD/dist/peridot-audio"
```

Remove either `--driver` option to export just the other `.ko`. The profile builds `msm_ext_display` for its symbols and compiles the full audio package because this vendor Kbuild does not reliably build individual nested targets. For both drivers, the output includes `ipc/audio_pkt_dlkm.ko`, `asoc/codecs/lpass-cdc/lpass_cdc_tx_macro_dlkm.ko`, and the audio package's `Module.symvers`. Use a kernel output matching the vendor tree and the kernel you intend to run; the example path is an existing local build, not a generally applicable release.

## 3. Repack vendor_dlkm

```bash
./repack-vendor-dlkm.py --input /path/to/vendor_dlkm.img --list

mkdir -p out
./repack-vendor-dlkm.py \
  --input /path/to/vendor_dlkm.img --output out/vendor_dlkm-repacked.img \
  --replace audio_pkt_dlkm.ko=dist/peridot-audio/ipc/audio_pkt_dlkm.ko \
  --replace lpass_cdc_tx_macro_dlkm.ko=dist/peridot-audio/asoc/codecs/lpass-cdc/lpass_cdc_tx_macro_dlkm.ko
```

- Use the exact path from `--list` for nested modules. A bare filename means `/lib/modules/NAME.ko`. Each target must already exist as an uncompressed regular `.ko` with one link. Files such as `modules.load` and `modules.dep` are not regenerated.
- The script checks ELF identity, module metadata, existing import CRCs, and exports. For new versioned imports, repeat `--symvers FILE` with trusted symbol tables from the **target** kernel and its module providers. It preserves the replaced module's permissions, UID/GID, timestamps and xattrs, verifies the written bytes, and runs `e2fsck` before publishing a new image. The input is left unchanged and an existing output is never overwritten.
- **AVB:** AVB-footer images are refused unless you explicitly pass `--for-resigning`. That mode writes **only the unsigned filesystem**, not a bootable or AVB-valid partition image. Use your device's partition sizing and signing pipeline separately. Even without a footer, AVB descriptors can live in separate `vbmeta`; don't assume a modified image will be accepted.
- Output is raw ext4 even for sparse ext4 input. EROFS, compressed modules, `super.img`, OTA payloads, and filesystem resizing are not supported. For a tight image, `--strip-debug "$LLVM_BIN/llvm-strip"` may help with **unsigned** replacement modules; do not strip a signed module.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Missing `Module.symvers`, generated headers, or `vmlinux` | Use output from a complete build for the target kernel. `modules_prepare` alone does not supply the needed CRCs; BTF needs matching `vmlinux`. |
| `undefined` at modpost or missing `.ko` | Verify `CONFIG_…=m` and the target path. Supply dependency symvers for external builds or use `--build-package` where individual Kbuild targets miss other modules. |
| `vermagic` or import/export CRCs differ | Rebuild against the target kernel and installed module providers. Matching `uname -r` alone does not prove ABI/KMI compatibility; do not edit `vermagic` to force a match. |
| No space in ext4 | Use a smaller compatible build or the original Android filesystem build tooling. The script does not enlarge partitions. |
| Image verifies locally but a module won't load | ABI checks are not a runtime test. Kernel module signatures and partition AVB are separate; use the intended kernel, dependency set and signing pipeline. The repacker does not verify cryptographic signatures. |

Run each script with `--help` for all options.
