#!/usr/bin/env bash

set -Eeuo pipefail

SECONDS=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$SCRIPT_DIR/kernel-source}"
DEVICE="${DEVICE:-r8q}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/out/$DEVICE}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$SCRIPT_DIR/llvm-21}"
JOBS="${JOBS:-$(nproc)}"
STOCK_CONFIG_SOURCE="${STOCK_CONFIG_SOURCE:-$SCRIPT_DIR/stock_R8Q}"

DEFCONFIG="${DEFCONFIG:-r8q_generated_defconfig}"
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh}"
KSU_REF="${KSU_REF:-master}"
CLANG_TOOLCHAIN_URL="${CLANG_TOOLCHAIN_URL:-https://github.com/Ylarod/setup-ndk-clang/releases/download/prebuilt/clang-linux-x86-ndk-r29-r563880c.tar.zst}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

die() {
    echo -e "${RED}ERROR: $*${NC}" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

for cmd in make curl git tar python3 find sort awk sed; do
    need_cmd "$cmd"
done
need_cmd nproc

[[ "$DEVICE" == "r8q" ]] || die "This builder only supports DEVICE=r8q (got: $DEVICE)"
[[ -f "$KERNEL_DIR/Makefile" ]] || die "Kernel source not found: $KERNEL_DIR"
[[ -f "$KERNEL_DIR/arch/arm64/configs/vendor/kona-sec-perf_defconfig" ]] || \
    die "Missing Kona base defconfig"
[[ -f "$KERNEL_DIR/arch/arm64/configs/vendor/samsung/r8q.config" ]] || \
    die "Missing r8q config fragment"
[[ -x "$KERNEL_DIR/tools/dtc" ]] || die "Missing executable: $KERNEL_DIR/tools/dtc"
[[ -x "$KERNEL_DIR/tools/mkdtimg" ]] || die "Missing executable: $KERNEL_DIR/tools/mkdtimg"
[[ -f "$KERNEL_DIR/mkbootimg/mkbootimg.py" ]] || die "Missing mkbootimg submodule"
[[ -f "$KERNEL_DIR/boot/ramdisk" ]] || die "Missing source boot ramdisk"

if [[ ! -s "$STOCK_CONFIG_SOURCE" && -s "$KERNEL_DIR/stock_R8Q" ]]; then
    STOCK_CONFIG_SOURCE="$KERNEL_DIR/stock_R8Q"
fi
[[ -s "$STOCK_CONFIG_SOURCE" ]] || \
    die "Stock kernel config not found: $STOCK_CONFIG_SOURCE"

chmod -R u+rwX "$KERNEL_DIR"

rm -rf -- "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo -e "${BLUE}Kernel source : $KERNEL_DIR${NC}"
echo -e "${BLUE}Output        : $OUT_DIR${NC}"
echo -e "${BLUE}Device        : $DEVICE${NC}"
echo -e "${BLUE}KSU ref       : $KSU_REF${NC}"

if [[ -x "$TOOLCHAIN_DIR/bin/clang" ]]; then
    CLANG_BIN="$TOOLCHAIN_DIR/bin/clang"
else
    need_cmd zstd
    echo -e "${YELLOW}Downloading Prime toolchain...${NC}"
    mkdir -p "$TOOLCHAIN_DIR"
    TOOLCHAIN_ARCHIVE="$OUT_DIR/llvm.tar.zst"
    curl -fL --retry 3 "$CLANG_TOOLCHAIN_URL" -o "$TOOLCHAIN_ARCHIVE"
    tar --zstd -xf "$TOOLCHAIN_ARCHIVE" -C "$TOOLCHAIN_DIR"
    rm -f -- "$TOOLCHAIN_ARCHIVE"
    CLANG_BIN="$TOOLCHAIN_DIR/bin/clang"
fi

[[ -x "$CLANG_BIN" ]] || die "Clang was not found: $CLANG_BIN"
TOOLCHAIN_BIN="$(dirname "$CLANG_BIN")"
export PATH="$TOOLCHAIN_BIN:$PATH"

CCACHE_PREFIX=""
if command -v ccache >/dev/null 2>&1; then
    unset CCACHE_HARDLINK
    export CCACHE_DIR="${CCACHE_DIR:-$OUT_DIR/ccache}"
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
    export CCACHE_SLOPPINESS="${CCACHE_SLOPPINESS:-file_macro,time_macros,include_file_mtime,include_file_ctime}"
    CCACHE_PREFIX="ccache "
fi

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export LOCALVERSION="-27223811"
export KBUILD_BUILD_USER="dpi"
export KBUILD_BUILD_HOST="21DKGA22"
export KBUILD_BUILD_VERSION="1"
export KBUILD_BUILD_TIMESTAMP="Tue Sep 30 19:38:09 KST 2025"
export KCFLAGS="${KCFLAGS:--w}"

MAKE_ARGS=(
    -C "$KERNEL_DIR"
    O="$OUT_DIR"
    ARCH=arm64
    CROSS_COMPILE="$CROSS_COMPILE"
    LLVM=1
    LLVM_IAS=1
    CC="${CCACHE_PREFIX}clang"
    CXX="${CCACHE_PREFIX}clang++"
    HOSTCC="${CCACHE_PREFIX}clang"
    HOSTCXX="${CCACHE_PREFIX}clang++"
    HOSTCFLAGS="${HOSTCFLAGS:--w}"
    HOSTCXXFLAGS="${HOSTCXXFLAGS:--w}"
    KCFLAGS="$KCFLAGS"
)

is_ksu_symbol() {
    grep -Rqs --exclude-dir=.git -- "^[[:space:]]*config[[:space:]]+$1[[:space:]]*$" \
        "$KERNEL_DIR/drivers/kernelsu" "$KERNEL_DIR/KernelSU/kernel" 2>/dev/null
}

remove_in_tree_kernelsu() {
    local ksu_dir="$KERNEL_DIR/drivers/kernelsu"

    if [[ -e "$ksu_dir" || -L "$ksu_dir" ]]; then
        mv -- "$ksu_dir" "$OUT_DIR/in-tree-kernelsu"
    fi

    sed -E -i \
        '/^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu\/[[:space:]]*$/d' \
        "$KERNEL_DIR/drivers/Makefile"
    sed -E -i \
        '/^[[:space:]]*source[[:space:]]+"drivers\/kernelsu\/Kconfig"[[:space:]]*$/d' \
        "$KERNEL_DIR/drivers/Kconfig"
}

install_external_kernelsu() {
    echo -e "${YELLOW}Installing external KernelSU ($KSU_REF)...${NC}"
    remove_in_tree_kernelsu

    (
        cd "$KERNEL_DIR"
        curl -fLSs "$KSU_SETUP_URL" | bash -s "$KSU_REF"
    )

    [[ -d "$KERNEL_DIR/KernelSU" ]] || die "External KernelSU clone was not created"
    [[ -L "$KERNEL_DIR/drivers/kernelsu" ]] || die "KernelSU driver symlink was not created"
    grep -Fq 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_DIR/drivers/Makefile" || \
        die "KernelSU Makefile entry was not added"
    grep -Fq 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig" || \
        die "KernelSU Kconfig entry was not added"

    KSU_GIT_VERSION="$(git -C "$KERNEL_DIR/KernelSU" rev-list --count HEAD)"
    [[ "$KSU_GIT_VERSION" =~ ^[0-9]+$ ]] || \
        die "Invalid KernelSU commit count: $KSU_GIT_VERSION"

    # Keep the version calculation used by the previous builder. The raw
    # commit count is useful for auditing, but it is not the KernelSU version
    # shown in the old build output.
    KERNELSU_VERSION=$((KSU_GIT_VERSION + 30000 - 84))
    echo -e "${GREEN}KernelSU git commits: $KSU_GIT_VERSION${NC}"
    echo -e "${GREEN}KernelSU version: $KERNELSU_VERSION${NC}"
}

TEMP_DEFCONFIG="$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG"
cleanup() {
    rm -f -- "$TEMP_DEFCONFIG"
}
trap cleanup EXIT

install_external_kernelsu

echo -e "${YELLOW}Generating r8q configuration...${NC}"
cat \
    "$KERNEL_DIR/arch/arm64/configs/vendor/kona-sec-perf_defconfig" \
    "$KERNEL_DIR/arch/arm64/configs/vendor/samsung/r8q.config" \
    > "$TEMP_DEFCONFIG"

cat >> "$TEMP_DEFCONFIG" <<EOF
CONFIG_THINLTO=y
# CONFIG_LTO_NONE is not set
CONFIG_LTO_CLANG=y
CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y
CONFIG_LOCALVERSION="$LOCALVERSION"
EOF

# Keep the last assignment for each symbol, matching the Prime builder
# without producing a wall of harmless Kconfig override warnings.
awk '
{
    line = $0; sym = ""
    if (match(line, /^CONFIG_[A-Za-z0-9_]+=/)) {
        sym = substr(line, 1, RLENGTH - 1)
    } else if (match(line, /^# CONFIG_[A-Za-z0-9_]+ is not set$/)) {
        sym = line
        sub(/^# /, "", sym)
        sub(/ is not set$/, "", sym)
    }
    if (sym != "") last[sym] = NR
    lines[NR] = line
    symbols[NR] = sym
}
END {
    for (i = 1; i <= NR; i++) {
        if (symbols[i] == "" || last[symbols[i]] == i)
            print lines[i]
    }
}' "$TEMP_DEFCONFIG" > "$TEMP_DEFCONFIG.dedup"
mv -f -- "$TEMP_DEFCONFIG.dedup" "$TEMP_DEFCONFIG"

echo -e "${YELLOW}Preparing $DEFCONFIG...${NC}"
make "${MAKE_ARGS[@]}" "$DEFCONFIG"

CONFIG_CMD=(bash "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config")
[[ -f "$KERNEL_DIR/scripts/config" ]] || die "Missing scripts/config"

"${CONFIG_CMD[@]}" \
    --enable KSU \
    --disable KSU_TAMPER_SYSCALL_TABLE \
    --enable KSU_LSM_SECURITY_HOOKS \
    --enable KSU_FEATURE_SULOG \
    --enable KSU_FEATURE_ADBROOT \
    --disable KSU_DEBUG

# Keep KernelSU's ADB-root support available, but never enable it by default.
# The option is version-dependent, so only touch it when this KernelSU tree
# exposes the symbol.
if is_ksu_symbol KSU_FEATURE_ADBROOT_DEFAULT_ENABLE; then
    "${CONFIG_CMD[@]}" --disable KSU_FEATURE_ADBROOT_DEFAULT_ENABLE
fi

for optional_symbol in \
    KSU_HACK_ARM64_BRANCH_LINK \
    KSU_HOSTSREDIRECT \
    KSU_ENABLE_FULL_UID_CHECKS \
    KSU_THRONE_TRACKER_ALWAYS_THREADED \
    KSU_NOPRINTK \
    KSU_SHELL_HAS_SU_ALWAYS \
    KSU_SUSFS \
    KSU_SUSFS_SUS_PATH \
    KSU_SUSFS_SUS_MOUNT \
    KSU_SUSFS_SUS_KSTAT \
    KSU_SUSFS_SUS_OVERLAYFS \
    KSU_SUSFS_TRY_UMOUNT \
    KSU_SUSFS_SPOOF_UNAME \
    KSU_SUSFS_ENABLE_LOG \
    KSU_SUSFS_OPEN_REDIRECT; do
    if is_ksu_symbol "$optional_symbol"; then
        case "$optional_symbol" in
            # The kernel keeps its own manual hooks (execve, faccessat,
            # newfstatat, reboot and slow_avc_audit). Do not use the
            # branch-link fallback on top of those hooks.
            KSU_HACK_ARM64_BRANCH_LINK|KSU_ENABLE_FULL_UID_CHECKS|KSU_NOPRINTK)
                "${CONFIG_CMD[@]}" --disable "$optional_symbol" ;;
            *)
                "${CONFIG_CMD[@]}" --enable "$optional_symbol" ;;
        esac
    fi
done

make "${MAKE_ARGS[@]}" olddefconfig

grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config" || die "External KernelSU is not enabled in .config"
grep -q '^CONFIG_LTO_CLANG=y$' "$OUT_DIR/.config" || die "CONFIG_LTO_CLANG is not enabled"
grep -q '^CONFIG_BUILD_ARM64_DT_OVERLAY=y$' "$OUT_DIR/.config" || \
    die "CONFIG_BUILD_ARM64_DT_OVERLAY is not enabled"
grep -q '^CONFIG_MACH_R8Q_EUR_OPEN=y$' "$OUT_DIR/.config" || \
    die "CONFIG_MACH_R8Q_EUR_OPEN is not enabled"
if is_ksu_symbol KSU_HACK_ARM64_BRANCH_LINK; then
    grep -Eq '^# CONFIG_KSU_HACK_ARM64_BRANCH_LINK is not set$|^CONFIG_KSU_HACK_ARM64_BRANCH_LINK=n$' \
        "$OUT_DIR/.config" || die "KSU_HACK_ARM64_BRANCH_LINK must remain disabled"
fi
if is_ksu_symbol KSU_FEATURE_ADBROOT_DEFAULT_ENABLE; then
    grep -Eq '^# CONFIG_KSU_FEATURE_ADBROOT_DEFAULT_ENABLE is not set$|^CONFIG_KSU_FEATURE_ADBROOT_DEFAULT_ENABLE=n$' \
        "$OUT_DIR/.config" || die "KSU_FEATURE_ADBROOT_DEFAULT_ENABLE must remain disabled"
fi

echo -e "${YELLOW}Embedding stock_R8Q as /proc/config.gz...${NC}"
STOCK_CONFIG="$KERNEL_DIR/arch/arm64/configs/stock_R8Q"
cp -- "$STOCK_CONFIG_SOURCE" "$STOCK_CONFIG"

grep -q '^CONFIG_IKCONFIG=y$' "$OUT_DIR/.config" || \
    die "CONFIG_IKCONFIG=y is required for embedded /proc/config.gz"
grep -q '^CONFIG_IKCONFIG_PROC=y$' "$OUT_DIR/.config" || \
    die "CONFIG_IKCONFIG_PROC=y is required for /proc/config.gz"

KERNEL_MAKEFILE="$KERNEL_DIR/kernel/Makefile"
[[ -f "$KERNEL_MAKEFILE" ]] || die "Kernel Makefile not found: $KERNEL_MAKEFILE"
sed -i 's|\$(KCONFIG_CONFIG)|$(srctree)/arch/arm64/configs/stock_R8Q|g' \
    "$KERNEL_MAKEFILE"

echo -e "${YELLOW}Building Image and DTBs...${NC}"
BUILD_STDERR="$OUT_DIR/build.stderr.log"
if ! make -j"$JOBS" "${MAKE_ARGS[@]}" Image dtbs 2>"$BUILD_STDERR"; then
    echo -e "${RED}Kernel build failed; relevant diagnostics:${NC}" >&2
    grep -E 'error:|fatal error:|LLVM ERROR|undefined symbol|ld\.lld: error|make(\[[0-9]+\])?: \*\*\*' \
        "$BUILD_STDERR" | tail -n 160 >&2 || tail -n 160 "$BUILD_STDERR" >&2
    echo -e "${YELLOW}Full stderr log: $BUILD_STDERR${NC}" >&2
    exit 1
fi

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
[[ -f "$IMAGE" ]] || die "Kernel Image was not generated"

DTB_DIR="$OUT_DIR/arch/arm64/boot/dts"
DTB_OUT="$DTB_DIR/dtb"
DTB_FILES=(
    "$DTB_DIR/vendor/qcom/kona.dtb"
    "$DTB_DIR/vendor/qcom/kona-v2.dtb"
    "$DTB_DIR/vendor/qcom/kona-v2.1.dtb"
)
for dtb in "${DTB_FILES[@]}"; do
    [[ -f "$dtb" ]] || die "Required DTB was not generated: $dtb"
done
cat "${DTB_FILES[@]}" > "$DTB_OUT"

DTBO_DIR="$DTB_DIR/samsung/r8q"
mapfile -t DTBO_FILES < <(
    find "$DTBO_DIR" -maxdepth 1 -type f \
        -name 'kona-sec-r8q-eur-overlay-*.dtbo' -print | sort -V
)
[[ "${#DTBO_FILES[@]}" -gt 0 ]] || die "No EUR r8q DTBO files were generated"
[[ "${#DTBO_FILES[@]}" -eq 11 ]] || \
    die "Expected 11 EUR r8q DTBO files, found ${#DTBO_FILES[@]}"

DTBOIMG="$OUT_DIR/dtbo.img"
echo -e "${BLUE}Packing ${#DTBO_FILES[@]} EUR r8q DTBO files...${NC}"
"$KERNEL_DIR/tools/mkdtimg" create "$DTBOIMG" --page_size=4096 "${DTBO_FILES[@]}"

PACK_DIR="$OUT_DIR/pack"
mkdir -p "$PACK_DIR"
BOOTIMG="$PACK_DIR/boot.img"

echo -e "${YELLOW}Packing boot.img with the source repository's ramdisk...${NC}"
python3 "$KERNEL_DIR/mkbootimg/mkbootimg.py" \
    --header_version 2 \
    --kernel "$IMAGE" \
    --ramdisk "$KERNEL_DIR/boot/ramdisk" \
    --dtb "$DTB_OUT" \
    --cmdline "${BOOT_CMDLINE:-console=null androidboot.hardware=qcom androidboot.memcg=1 lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 androidboot.usbcontroller=a600000.dwc3 swiotlb=2048 printk.devkmsg=on firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7}" \
    --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x02000000 \
    --second_offset 0x00000000 \
    --dtb_offset 0x01f00000 \
    --tags_offset 0x01e00000 \
    --board SRPUB26A012 \
    --pagesize 4096 \
    --os_version "${OS_VERSION:-16.0.0}" \
    --os_patch_level "${OS_PATCH_LEVEL:-$(date +%Y-%m)}" \
    --output "$BOOTIMG"

[[ -s "$BOOTIMG" ]] || die "boot.img was not generated"
cp -- "$DTBOIMG" "$PACK_DIR/dtbo.img"

BUILD_TAG="${BUILD_TAG:-$(TZ='Asia/Makassar' date +%Y%m%d-%H%M)}"
TAR_NAME="${DEVICE}-${BUILD_TAG}-kernel.tar"
tar -cf "$OUT_DIR/$TAR_NAME" -C "$PACK_DIR" boot.img dtbo.img

echo -e "${GREEN}Done: $OUT_DIR/$TAR_NAME${NC}"
echo -e "${GREEN}Completed in $((SECONDS / 60))m $((SECONDS % 60))s${NC}"
