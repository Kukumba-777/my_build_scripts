#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-kernel.sh {kernel|in-tree|external|list} [options]

  kernel    Configure and build Image and all configured in-tree modules.
  in-tree   Build only the specified in-tree .ko targets in an isolated output copy.
  external  Build specified external .ko targets in a clean source copy.
  list      List .ko paths recorded in a modules.order file.

Common build options:
  --kernel-src DIR       Kernel source tree (required).
  --kernel-out DIR       Kbuild output tree (required).
  --llvm-bin DIR         Directory containing clang and LLVM tools (default: PATH).
  --arch ARCH            Kbuild ARCH (default: arm64).
  --jobs N               Parallel jobs (default: nproc).
  --dist DIR             New directory for selected artifacts (required for module builds).
  --dry-run              Show the commands without writing build files.

Kernel options:
  --defconfig TARGET     Base configuration target (default: gki_defconfig).
  --config FILE          Use an existing .config instead of running a defconfig.
  --fragment FILE        Merge a configuration fragment (repeatable).
  --reuse-config         Keep the .config already in --kernel-out.
  --configure-only       Stop after olddefconfig and verify the requested fragments.

Module options:
  --target PATH.ko       Path relative to the kernel tree or external package (repeatable).
  --module NAME          Select a module by basename, with or without .ko (repeatable).
                         In external mode, build the package first to discover its modules.
  --external-root DIR    External source root to copy (required for external).
  --package DIR          Package within --external-root (default: .).
  --all                  Build all modules in the external package instead of --target.
  --build-package        Build the full in-tree module set or external package, but export only
                         --target modules. Use when single-target modpost misses dependencies.
  --symvers FILE         Additional dependency symbol table (repeatable; external only).
  --set NAME=VALUE       Extra vendor Kbuild argument (repeatable; external only).
                         Use @work@ for the copied root and @kernel@ for the kernel source.

List options:
  --order FILE           Path to modules.order (defaults to --kernel-out/modules.order).
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
need_arg() { [[ $# -ge 2 && -n $2 && $2 != --* ]] || fail "Missing value for $1"; }
need_file() { [[ -s $1 && -f $1 && -r $1 ]] || fail "Required file not found: $1"; }
need_tool() { command -v "$1" >/dev/null || fail "Missing tool: $1"; }

# Kbuild expands file paths in Make recipes, where shell quoting is not reliable.
build_path() {
    local path
    path=$(realpath -m -- "$1") || return 1
    [[ $path =~ ^[a-zA-Z0-9_./+-]+$ ]] || fail "Unsupported Kbuild path: $path"
    printf '%s\n' "$path"
}

relative_path() {
    [[ $1 =~ ^[a-zA-Z0-9_+.-]+(/[a-zA-Z0-9_+.-]+)*$ && /$1/ != */../* && /$1/ != */./* ]]
}

module_paths() {
    local prefix=${2:-} target
    # Older Kbuild records .ko; newer versions may record .o in modules.order.
    while IFS= read -r target || [[ -n $target ]]; do
        target=${target#"$prefix"}
        case $target in
            *.ko) printf '%s\n' "$target" ;;
            *.o) printf '%s.ko\n' "${target%.o}" ;;
        esac
    done < "$1" | LC_ALL=C sort -u
}

resolve_modules() {
    local file=$1 prefix=${2:-} name target
    local -a available matches
    need_file "$file"
    mapfile -t available < <(module_paths "$file" "$prefix")
    for name in "${module_names[@]}"; do
        matches=()
        for target in "${available[@]}"; do
            [[ ${target##*/} == "$name.ko" ]] && matches+=("$target")
        done
        case ${#matches[@]} in
            0) fail "Module not found in $file: $name.ko (check the package and configuration)." ;;
            1) targets+=("${matches[0]}") ;;
            *) printf 'Matches for %s.ko:\n' "$name" >&2
               printf '  %s\n' "${matches[@]}" >&2
               fail 'Select the exact path with --target.' ;;
        esac
    done
}

validate_targets() {
    local t
    local -A selected=()
    for t in "${targets[@]}"; do
        relative_path "$t" && [[ $t == *.ko && $t != -* ]] || fail "Invalid module target: $t"
        [[ ! ${selected[$t]+exists} ]] || fail "Duplicate module target: $t"
        selected[$t]=1
    done
}

run() {
    printf '+'; printf ' %q' "$@"; printf '\n'
    if (( ! dry )); then "$@"; fi
}

case ${1:-} in
    -h|--help) usage; exit 0 ;;
    kernel|in-tree|external|list) mode=$1; shift ;;
    *) usage >&2; fail 'Select a build mode.' ;;
esac

src= out= dist= llvm_bin= config= defconfig= ext_root= package=. order=
arch=arm64 jobs=$(nproc) dry=0 reuse=0 configure_only=0 all=0 build_package=0
targets=() module_names=() fragments=() symvers=() extra=()
while (($#)); do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --dry-run) dry=1; shift; continue ;;
        --reuse-config) reuse=1; shift; continue ;;
        --configure-only) configure_only=1; shift; continue ;;
        --all) all=1; shift; continue ;;
        --build-package) build_package=1; shift; continue ;;
    esac
    need_arg "$@"
    case $1 in
        --kernel-src) src=$2 ;;
        --kernel-out) out=$2 ;;
        --dist) dist=$2 ;;
        --llvm-bin) llvm_bin=$2 ;;
        --arch) arch=$2 ;;
        --jobs) jobs=$2 ;;
        --config) config=$2 ;;
        --defconfig) defconfig=$2 ;;
        --fragment) fragments+=("$2") ;;
        --target) targets+=("$2") ;;
        --module)
            name=${2%.ko}
            [[ $name =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.+-]*$ ]] || fail "Invalid module name: $2"
            module_names+=("$name") ;;
        --external-root) ext_root=$2 ;;
        --package) package=$2 ;;
        --symvers) symvers+=("$2") ;;
        --set) extra+=("$2") ;;
        --order) order=$2 ;;
        *) fail "Unknown option: $1" ;;
    esac
    shift 2
done

if [[ $mode == list ]]; then
    (( ${#targets[@]} + ${#module_names[@]} == 0 )) || fail 'Use in-tree or external to select module targets.'
    [[ -n $order || -n $out ]] || fail 'Use --order or --kernel-out.'
    order=${order:-$out/modules.order}
    need_file "$order"
    module_paths "$order"
    exit
fi

[[ -z $order ]] || fail '--order is only for list.'
[[ -n $src && -n $out ]] || fail 'Specify --kernel-src and --kernel-out.'
[[ $arch =~ ^[a-zA-Z0-9_]+$ && $jobs =~ ^[1-9][0-9]*$ ]] || fail 'Invalid --arch or --jobs.'
src=$(build_path "$src"); out=$(build_path "$out")
[[ $out != / && $src != / && $out != "$src" && $src != "$out/"* ]] || fail 'Use a separate Kbuild output directory.'
need_file "$src/Makefile"
if [[ -n $dist ]]; then
    [[ ! -L $dist ]] || fail "--dist must not be a symlink: $dist"
    dist=$(build_path "$dist")
    [[ ! -e $dist && ! -L $dist ]] || fail "--dist already exists: $dist"
    [[ $out != "$dist" && $src != "$dist" && $out != "$dist/"* && $src != "$dist/"* ]] ||
        fail '--dist cannot contain a build or source tree.'
fi

llvm=1
if [[ -n $llvm_bin ]]; then
    llvm_bin=$(build_path "$llvm_bin")
    llvm="$llvm_bin/"
fi
for tool in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip; do
    need_tool "${llvm_bin:+$llvm_bin/}$tool"
done
need_tool make
export LC_ALL=C
unset KBUILD_EXTRA_SYMBOLS KBUILD_KCONFIG KCONFIG_ALLCONFIG KCONFIG_CONFIG
# Do not inherit a modpost override that turns unresolved symbols into warnings.
kmake=(make -C "$src" "O=$out" "ARCH=$arch" "LLVM=$llvm" LLVM_IAS=1 "-j$jobs"
    KCONFIG_CONFIG=.config KBUILD_MODPOST_WARN= KBUILD_MODPOST_NOFINAL=)

check_prepared() {
    local file
    for file in .config Module.symvers include/config/auto.conf include/config/kernel.release \
        include/generated/autoconf.h include/generated/utsrelease.h; do
        need_file "$out/$file"
    done
    grep -Fxq CONFIG_MODULES=y "$out/.config" || fail 'CONFIG_MODULES is disabled.'
    if grep -Fxq CONFIG_MODVERSIONS=y "$out/.config"; then
        awk '$2 == "module_layout" && $1 ~ /^0x[[:xdigit:]]+$/ && $1 !~ /^0x0+$/ { ok=1 }
            END { exit !ok }' "$out/Module.symvers" || fail 'Module.symvers has no module_layout CRC.'
    fi
    if grep -Fxq CONFIG_DEBUG_INFO_BTF_MODULES=y "$out/.config"; then
        need_file "$out/vmlinux"
    fi
    grep -Fxq "#define UTS_RELEASE \"$(<"$out/include/config/kernel.release")\"" \
        "$out/include/generated/utsrelease.h" || fail 'Inconsistent generated kernel release files.'
}

if [[ -L $out/source && ! $out/source -ef $src ]]; then
    fail "The output belongs to $(readlink "$out/source"), not $src"
fi

if [[ $mode == kernel ]]; then
    (( ${#targets[@]} + ${#module_names[@]} + ${#extra[@]} + ${#symvers[@]} + all + build_package == 0 )) && [[ -z $ext_root && $package == . ]] ||
        fail 'Use in-tree or external to select module targets.'
    [[ -z $config || -z $defconfig ]] || fail 'Use either --config or --defconfig.'
    if (( reuse )); then
        [[ -z $config && -z $defconfig ]] || fail '--reuse-config excludes --config and --defconfig.'
        need_file "$out/.config"
    elif [[ -e $out/.config || -L $out/.config ]]; then
        fail 'Output already has a .config. Use --reuse-config or a fresh --kernel-out.'
    fi
    [[ ! -L $out/.config ]] || fail 'Refusing to modify a symlinked .config.'
    [[ -z $defconfig ]] || relative_path "$defconfig" || fail 'Invalid defconfig target.'
    if [[ -n $config ]]; then config=$(build_path "$config"); need_file "$config"; fi
    for i in "${!fragments[@]}"; do
        fragments[i]=$(build_path "${fragments[i]}"); need_file "${fragments[i]}"
    done
    if ((${#fragments[@]})); then need_file "$src/scripts/kconfig/merge_config.sh"; fi
    [[ -z $dist || $configure_only == 0 ]] || fail 'No --dist is produced with --configure-only.'
    run mkdir -p -- "$out"
    if [[ -n $config ]]; then
        run cp -- "$config" "$out/.config"
    elif (( ! reuse )); then
        run "${kmake[@]}" M= "${defconfig:-gki_defconfig}"
    fi
    if ((${#fragments[@]})); then
        # Merge in the output directory, then resolve dependencies via Kconfig.
        run bash -c 'cd -- "$1"; shift; exec env -u CONFIG_ bash "$@"' _ "$out" \
            "$src/scripts/kconfig/merge_config.sh" -m .config "${fragments[@]}"
    fi
    run "${kmake[@]}" M= olddefconfig
    if (( ! dry && ${#fragments[@]} )); then
        # Report options Kconfig dropped or changed after resolving dependencies.
        awk '/^CONFIG_[A-Za-z0-9_]+=/ { split($0,a,"="); key=a[1] }
             /^# CONFIG_[A-Za-z0-9_]+ is not set$/ { key=$2 }
             { if (key != "") { if (FILENAME==ARGV[ARGC-1]) got[key]=$0; else want[key]=$0; key="" } }
             END { for (k in want) if (got[k]!=want[k] && !(got[k]=="" && want[k] ~ /^# /)) {
                 print "Kconfig did not retain: " want[k] > "/dev/stderr"; bad=1
             } exit bad }' "${fragments[@]}" "$out/.config"
    fi
    if (( configure_only )); then exit 0; fi
    run "${kmake[@]}" M= Image modules
    if (( ! dry )); then check_prepared; need_file "$out/arch/$arch/boot/Image"; fi
    if [[ -n $dist ]]; then
        run mkdir -p -- "$(dirname -- "$dist")"
        run mkdir -- "$dist"
        run cp -- "$out/arch/$arch/boot/Image" "$out/Module.symvers" "$dist/"
    fi
    printf 'Kernel output: %s\n' "$out"
    exit
fi

[[ -z $config && -z $defconfig && $reuse == 0 && $configure_only == 0 && ${#fragments[@]} == 0 ]] ||
    fail 'Configuration options are only for kernel.'
[[ -n $dist ]] || fail 'Module builds require --dist.'
check_prepared
validate_targets
if (( all )); then
    [[ $mode == external && ${#targets[@]} == 0 && ${#module_names[@]} == 0 && $build_package == 0 ]] ||
        fail '--all is external-only and excludes --target, --module and --build-package.'
else
    (( ${#targets[@]} + ${#module_names[@]} )) || fail 'Specify at least one --target or --module.'
fi

work= output_tree=$out
cleanup() { if [[ -n $work ]]; then rm -rf -- "$work"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
tmp_root=$(build_path "${TMPDIR:-/tmp}")
make_work() {
    local prefix=$1
    if (( dry )); then work_path=$tmp_root/$prefix.XXXXXXXX
    else work=$(mktemp -d -- "$tmp_root/$prefix.XXXXXXXX"); work_path=$work; fi
}
if [[ $mode == external ]]; then
    [[ -n $ext_root ]] || fail 'Specify --external-root.'
    ext_root=$(build_path "$ext_root")
    [[ $package == . ]] || relative_path "$package" || fail 'Invalid --package path.'
    [[ $(realpath -m -- "$ext_root/$package") == "$ext_root" || $(realpath -m -- "$ext_root/$package") == "$ext_root/"* ]] ||
        fail 'The external package escapes its source root.'
    [[ -f $ext_root/$package/Kbuild || -f $ext_root/$package/Makefile ]] || fail 'External package has no Kbuild or Makefile.'
    need_tool rsync
    [[ $tmp_root != "$ext_root" && $tmp_root != "$ext_root/"* ]] || fail 'TMPDIR cannot be within the external root.'
    make_work kbuild-ext
    work_src=$work_path/src
    output_tree=$work_src
    if [[ $package != . ]]; then output_tree+=/$package; fi
    symbols=()
    for s in "${symvers[@]}"; do
        s=$(build_path "$s")
        if (( ! dry )); then need_file "$s"; fi
        symbols+=("$s")
    done
    for i in "${!extra[@]}"; do
        arg=${extra[i]}; key=${arg%%=*}
        [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ && $arg == *=* ]] || fail "Invalid --set: $arg"
        case $key in
            M|O|ARCH|LLVM|LLVM_IAS|KCONFIG_*|KBUILD_*|MAKE*) fail "Reserved Kbuild argument: $key" ;;
        esac
        arg=${arg//@work@/$work_src}
        extra[i]=${arg//@kernel@/$src}
    done
    run mkdir -p -- "$work_src"
    # Copy tracked and local source changes, but not stale build objects or outside links.
    run rsync -a --safe-links --exclude='.git' --exclude='*.ko' --exclude='*.o' --exclude='*.mod' \
        --exclude='*.mod.c' --exclude='.*.cmd' --exclude=Module.symvers --exclude=modules.order \
        -- "$ext_root/" "$work_src/"
    goals=("${targets[@]}")
    if (( all || build_package || ${#module_names[@]} )); then goals=(modules); fi
    run "${kmake[@]}" "M=$output_tree" "KBUILD_EXTRA_SYMBOLS=${symbols[*]}" "${extra[@]}" "${goals[@]}"
    if ((${#module_names[@]})); then
        if (( dry )); then
            printf 'Resolve and export from package modules.order:'; printf ' %s.ko' "${module_names[@]}"; printf '\n'
        else
            resolve_modules "$output_tree/modules.order" "$output_tree/"
            validate_targets
        fi
    fi
else
    [[ -z $ext_root && $package == . && ${#extra[@]} == 0 && ${#symvers[@]} == 0 ]] ||
        fail 'External options are only for external.'
    [[ $tmp_root != "$out" && $tmp_root != "$out/"* ]] || fail 'TMPDIR cannot be within the kernel output.'
    need_file "$out/vmlinux.o"
    need_file "$out/modules.order"
    if ((${#module_names[@]})); then
        resolve_modules "$out/modules.order"
        validate_targets
    fi
    for t in "${targets[@]}"; do
        grep -Fxq -e "$t" -e "${t%.ko}.o" "$out/modules.order" ||
            fail "Not a configured module: $t (check 'list', set its config to m, and rebuild the kernel)."
    done
    make_work kbuild-in-tree
    output_tree=$work_path/kernel
    # Single-target Kbuild can replace Module.symvers and remove modules.order.
    # Do not run it in the canonical output tree or hard-link its artifacts.
    run cp -a --reflink=auto -- "$out" "$output_tree"
    kmake[3]="O=$output_tree"
    if (( build_package )); then
        run "${kmake[@]}" M= modules
    else
        run "${kmake[@]}" M= "${targets[@]}"
    fi
fi

if (( all && ! dry )); then
    need_file "$output_tree/modules.order"
    while IFS= read -r target; do
        target=${target#"$output_tree/"}
        [[ $target == *.o ]] && target=${target%.o}.ko
        relative_path "$target" && [[ $target == *.ko ]] || fail "Unexpected modules.order entry: $target"
        targets+=("$target")
    done < "$output_tree/modules.order"
fi
if (( ! dry )); then
    for t in "${targets[@]}"; do need_file "$output_tree/$t"; done
fi
run mkdir -p -- "$(dirname -- "$dist")"
run mkdir -- "$dist"
for t in "${targets[@]}"; do
    run mkdir -p -- "$(dirname -- "$dist/$t")"
    run cp -- "$output_tree/$t" "$dist/$t"
done
if [[ $mode == external ]] && { (( dry )) || [[ -f $output_tree/Module.symvers ]]; }; then
    run cp -- "$output_tree/Module.symvers" "$dist/Module.symvers"
fi
printf 'Artifacts: %s\n' "$dist"
