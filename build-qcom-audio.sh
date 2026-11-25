#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
spf=ipc/audio_pkt_dlkm.ko
lpass=asoc/codecs/lpass-cdc/lpass_cdc_tx_macro_dlkm.ko

usage() {
    cat <<'EOF'
Usage: build-qcom-audio.sh --modules-src DIR --kernel-src DIR --kernel-out DIR
                           --dist DIR --driver {spf|lpass} [--driver ...] [options]
       build-qcom-audio.sh --list

  --modules-src DIR     Vendor tree containing qcom/opensource/audio-kernel.
  --driver spf          Select audio_pkt_dlkm.ko.
  --driver lpass        Select lpass_cdc_tx_macro_dlkm.ko.
  --board NAME          Vendor BOARD_PLATFORM (default: pineapple).
  --product NAME        Vendor TARGET_PRODUCT (default: no override).
  --llvm-bin DIR        Directory with the matching LLVM tools.
  --jobs N              Parallel jobs.
  --dry-run             Print build steps, without writing output.

This profile builds the vendor audio package but only exports the chosen .ko files
and the package's Module.symvers.
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
if [[ $# == 1 ]]; then
    case $1 in
        --list) printf 'spf\t%s\nlpass\t%s\n' "$spf" "$lpass"; exit 0 ;;
        --help|-h) usage; exit 0 ;;
    esac
fi

vendor= kernel= out= dist= product= board=pineapple dry=0
common=()
declare -A wanted=()
while (($#)); do
    if [[ $1 == --dry-run ]]; then dry=1; common+=(--dry-run); shift; continue; fi
    [[ $# -ge 2 && -n $2 && $2 != --* ]] || fail "Missing value for $1"
    case $1 in
        --modules-src) vendor=$2 ;;
        --kernel-src) kernel=$2 ;;
        --kernel-out) out=$2 ;;
        --dist) dist=$2 ;;
        --board) board=$2 ;;
        --product) product=$2 ;;
        --llvm-bin|--jobs) common+=("$1" "$2") ;;
        --driver)
            [[ $2 == spf || $2 == lpass ]] || fail "Unknown driver: $2 (see --list)"
            [[ ! ${wanted[$2]+yes} ]] || fail "Duplicate driver: $2"
            wanted[$2]=1 ;;
        *) fail "Unknown option: $1" ;;
    esac
    shift 2
done
[[ -n $vendor && -n $kernel && -n $out && -n $dist && ${#wanted[@]} -gt 0 ]] || { usage >&2; exit 1; }
[[ $board =~ ^[A-Za-z0-9_]+$ && $product =~ ^[A-Za-z0-9_]*$ ]] || fail 'Invalid board or product.'
[[ ! -L $dist ]] || fail "--dist must not be a symlink: $dist"
dist=$(realpath -m -- "$dist")
[[ ! -e $dist && ! -L $dist && $dist =~ ^[a-zA-Z0-9_./+-]+$ ]] || fail "Invalid or existing --dist: $dist"
base=$vendor/qcom/opensource
[[ -f $base/audio-kernel/Kbuild && -f $base/mm-drivers/msm_ext_display/Kbuild ]] || fail 'Vendor audio or display Kbuild not found.'
common+=(--kernel-src "$kernel" --kernel-out "$out")
if ((dry)); then
    tmp=${TMPDIR:-/tmp}/qcom-audio.XXXXXXXX
else
    tmp=$(mktemp -d -- "${TMPDIR:-/tmp}/qcom-audio.XXXXXXXX")
    trap 'rm -rf -- "$tmp"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi
build() { "$here/build-kernel.sh" external "${common[@]}" "$@"; }

build --external-root "$base/mm-drivers" --package msm_ext_display --dist "$tmp/display" \
    --target msm_ext_display.ko --set 'MSM_EXT_DISPLAY_ROOT=@work@' --set MODNAME=msm_ext_display \
    --set "BOARD_PLATFORM=$board" --set 'KERNEL_SRC=@kernel@'

# The vendor Kbuild enumerates overlapping subdirectories, which breaks
# single-target traversal. Build the package once and export selected modules.
audio=(--external-root "$base/audio-kernel" --set 'AUDIO_ROOT=@work@' --set MODNAME=audio_dlkm
    --set "BOARD_PLATFORM=$board" --set 'KERNEL_SRC=@kernel@')
if [[ -n $product ]]; then audio+=(--set "TARGET_PRODUCT=$product"); fi

targets=()
for name in spf lpass; do
    [[ ${wanted[$name]+yes} ]] || continue
    if [[ $name == spf ]]; then targets+=(--target "$spf"); else targets+=(--target "$lpass"); fi
done
build "${audio[@]}" --dist "$dist" --symvers "$tmp/display/Module.symvers" \
    --build-package "${targets[@]}"
