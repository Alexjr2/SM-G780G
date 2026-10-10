#!/usr/bin/env bash

set -Eeuo pipefail

SECONDS=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$SCRIPT_DIR/kernel-source}"
DEVICE="${DEVICE:-r8q}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/out/$DEVICE}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$SCRIPT_DIR/tc/clang}"
JOBS="${JOBS:-$(nproc)}"
STOCK_CONFIG_SOURCE="${STOCK_CONFIG_SOURCE:-$SCRIPT_DIR/stock_R8Q}"

DEFCONFIG="${DEFCONFIG:-r8q_generated_defconfig}"
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh}"
KSU_REF="${KSU_REF:-master}"
CLANG_TOOLCHAIN_URL="${CLANG_TOOLCHAIN_URL:-}"
ORIGIN_BOOTIMG_URL="${ORIGIN_BOOTIMG_URL:-https://github.com/Alexjr2/SM-G780G/releases/download/originalboot/boot.img}"
# Match the stock Samsung kernel identity in uname/proc/version. The source
# tree is based on 4.19.325, but the stock r8q kernel reports 4.19.113.
STOCK_KERNEL_VERSION="4.19.113"
STOCK_KERNEL_COMPILER="clang version 10.0.6 for Android NDK"
# Pin a known release asset so Actions does not depend on the anonymous
# GitHub API rate limit. Override MAGISKBOOT_URL when a newer binary is needed.
MAGISKBOOT_URL="${MAGISKBOOT_URL:-https://github.com/xiaoxindada/magisk_bins_ndk/releases/download/magisk_bins-31000-f7ddbcdebe5765417b5ae4560b7d327a04149846/magisk_bins.7z}"
MAGISKBOOT_DIR="${MAGISKBOOT_DIR:-$OUT_DIR/magiskboot}"
# r8q boot partition budget. This is a limit check only; boot.img is not
# padded because Android boot images are valid at their actual packed size.
BOOT_PARTITION_SIZE="${BOOT_PARTITION_SIZE:-67108864}"

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

for cmd in make curl jq git tar 7z python3 find sort awk sed; do
    need_cmd "$cmd"
done
need_cmd nproc

[[ "$DEVICE" == "r8q" ]] || die "This builder only supports DEVICE=r8q (got: $DEVICE)"
[[ -f "$KERNEL_DIR/Makefile" ]] || die "Kernel source not found: $KERNEL_DIR"
[[ -f "$KERNEL_DIR/arch/arm64/configs/vendor/kona-perf_defconfig" ]] || \
    die "Missing Kona base defconfig"
[[ -f "$KERNEL_DIR/arch/arm64/configs/vendor/samsung/kona-sec-common.config" ]] || \
    die "Missing Samsung common config fragment"
[[ -f "$KERNEL_DIR/arch/arm64/configs/vendor/samsung/r8q.config" ]] || \
    die "Missing r8q config fragment"
[[ -f "$KERNEL_DIR/tools/dtc" ]] || die "Missing tool: $KERNEL_DIR/tools/dtc"
[[ -f "$KERNEL_DIR/tools/mkdtimg" ]] || die "Missing tool: $KERNEL_DIR/tools/mkdtimg"

if [[ ! -s "$STOCK_CONFIG_SOURCE" && -s "$KERNEL_DIR/stock_R8Q" ]]; then
    STOCK_CONFIG_SOURCE="$KERNEL_DIR/stock_R8Q"
fi
[[ -s "$STOCK_CONFIG_SOURCE" ]] || \
    die "Stock kernel config not found: $STOCK_CONFIG_SOURCE"

chmod -R u+rwX "$KERNEL_DIR"
chmod +x "$KERNEL_DIR/tools/dtc" "$KERNEL_DIR/tools/mkdtimg"

# Keep the built kernel's base version equal to stock. This affects the
# kernel release string, vermagic, and the Linux version shown by Android.
KERNEL_MAKEFILE="$KERNEL_DIR/Makefile"
MKCOMPILE_H="$KERNEL_DIR/scripts/mkcompile_h"
[[ -f "$MKCOMPILE_H" ]] || die "Missing compile header generator: $MKCOMPILE_H"

if grep -Eq '^SUBLEVEL[[:space:]]*=' "$KERNEL_MAKEFILE"; then
    sed -E -i "s|^SUBLEVEL[[:space:]]*=.*$|SUBLEVEL = ${STOCK_KERNEL_VERSION##*.}|" \
        "$KERNEL_MAKEFILE"
else
    die "Unsupported kernel Makefile: SUBLEVEL assignment was not found"
fi

# The source tree appends its own compiler identity and a project message:
#   (not_kernel: It's about a girl in a box.)
# Replace that generated field with the stock compiler string exactly.
if grep -Eq '^[[:space:]]*MESSAGE=' "$MKCOMPILE_H" && \
   grep -Eq '^[[:space:]]*printf .*LINUX_COMPILER' "$MKCOMPILE_H"; then
    sed -E -i 's|^[[:space:]]*MESSAGE=.*$|MESSAGE=""|' "$MKCOMPILE_H"
    sed -i "/^[[:space:]]*printf .*LINUX_COMPILER/c\\  echo '#define LINUX_COMPILER \"clang version 10.0.6 for Android NDK\"'" \
        "$MKCOMPILE_H"
else
    die "Unsupported scripts/mkcompile_h: compiler identity line was not found"
fi

echo -e "${BLUE}Stock kernel identity: ${STOCK_KERNEL_VERSION}; compiler: ${STOCK_KERNEL_COMPILER}${NC}"

# Ignore release suffixes shipped by the source tree. The builder controls the
# release suffix through the explicit LOCALVERSION exported above.
rm -f -- \
    "$KERNEL_DIR/localversion" \
    "$KERNEL_DIR/localversion-cip" \
    "$KERNEL_DIR/localversion-st" \
    "$KERNEL_DIR/arch/arm64/configs/vendor/not/localversion.config"

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
    echo -e "${YELLOW}Downloading latest Neutron toolchain...${NC}"
    mkdir -p "$TOOLCHAIN_DIR"
    TOOLCHAIN_ARCHIVE="$OUT_DIR/llvm.tar.zst"
    if [[ -z "$CLANG_TOOLCHAIN_URL" ]]; then
        CLANG_TOOLCHAIN_URL="$(curl -fsSL \
            "https://api.github.com/repos/Neutron-Toolchains/clang-build-catalogue/releases/latest" \
            | jq -r '[.assets[] | select(.name | endswith(".tar.zst"))][0].browser_download_url // empty')"
    fi
    [[ -n "$CLANG_TOOLCHAIN_URL" ]] || die "Could not find a Neutron Clang release"
    curl -fL --retry 3 "$CLANG_TOOLCHAIN_URL" -o "$TOOLCHAIN_ARCHIVE"
    tar --zstd -xf "$TOOLCHAIN_ARCHIVE" -C "$TOOLCHAIN_DIR" --strip-components=1
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
export CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"
export LOCALVERSION="-27223811"
KERNEL_LOCALVERSION="$LOCALVERSION"
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
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32"
    LLVM=1
    LLVM_IAS=1
    CC="${CCACHE_PREFIX}clang"
    CXX="${CCACHE_PREFIX}clang++"
    LD=ld.lld
    AS=llvm-as
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
    # The standalone shallow clone cannot satisfy the WLAN driver's optional
    # git-log build tag generation. It is metadata only, not kernel behavior.
    WLAN_DISABLE_BUILD_TAG=y
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

remove_vendor_integrations() {
    echo -e "${YELLOW}Removing vendor submodule integrations...${NC}"

    # Do not run the source repository's blanket `git submodule update`: it
    # would restore the old Baseband-guard, NoMount and sKernelSU trees.
    rm -rf -- \
        "$KERNEL_DIR/Baseband-guard" \
        "$KERNEL_DIR/NoMount" \
        "$KERNEL_DIR/KernelSU"

    # Remove the symlinks committed by the source repository as well.
    rm -f -- \
        "$KERNEL_DIR/security/baseband-guard" \
        "$KERNEL_DIR/fs/nomount" \
        "$KERNEL_DIR/drivers/kernelsu"

    # Remove Kconfig/Kbuild references before configuration. Leaving these
    # references behind would make Kconfig follow missing symlinks.
    sed -E -i \
        '/^[[:space:]]*source[[:space:]]+"security\/baseband-guard\/Kconfig"[[:space:]]*$/d' \
        "$KERNEL_DIR/security/Kconfig"
    sed -E -i \
        '/^[[:space:]]*obj-\$\(CONFIG_BBG\).*baseband-guard\//d' \
        "$KERNEL_DIR/security/Makefile"
    sed -E -i \
        '/^[[:space:]]*source[[:space:]]+"fs\/nomount\/Kconfig"[[:space:]]*$/d' \
        "$KERNEL_DIR/fs/Kconfig"
    sed -E -i \
        '/^[[:space:]]*obj-\$\(CONFIG_NOMOUNT\).*nomount\//d' \
        "$KERNEL_DIR/fs/Makefile"

    # Baseband-guard was also selected through the LSM order in the Kona
    # defconfig. Remove only that LSM entry; keep the other Samsung LSMs.
    sed -E -i \
        -e 's/,baseband_guard//g' \
        -e 's/baseband_guard,//g' \
        -e 's/baseband_guard//g' \
        "$KERNEL_DIR/arch/arm64/configs/vendor/kona-perf_defconfig"

    # Remove the source repository's in-tree KernelSU wiring. The setup
    # script below will add the fresh external KernelSU clone back cleanly.
    sed -E -i \
        '/^[[:space:]]*obj-\$\(CONFIG_KSU\)[[:space:]]*\+=[[:space:]]*kernelsu\/[[:space:]]*$/d' \
        "$KERNEL_DIR/drivers/Makefile"
    sed -E -i \
        '/^[[:space:]]*source[[:space:]]+"drivers\/kernelsu\/Kconfig"[[:space:]]*$/d' \
        "$KERNEL_DIR/drivers/Kconfig"
}

install_external_kernelsu() {
    echo -e "${YELLOW}Installing external KernelSU ($KSU_REF)...${NC}"
    remove_vendor_integrations

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
    "$KERNEL_DIR/arch/arm64/configs/vendor/kona-perf_defconfig" \
    "$KERNEL_DIR/arch/arm64/configs/vendor/samsung/kona-sec-common.config" \
    "$KERNEL_DIR/arch/arm64/configs/vendor/samsung/r8q.config" \
    "$KERNEL_DIR/arch/arm64/configs/vendor/not/ksu.config" \
    > "$TEMP_DEFCONFIG"

cat >> "$TEMP_DEFCONFIG" <<EOF
CONFIG_THINLTO=y
# CONFIG_LTO_NONE is not set
CONFIG_LTO_CLANG=y
CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y
CONFIG_LOCALVERSION="$KERNEL_LOCALVERSION"
# CONFIG_LOCALVERSION_AUTO is not set
EOF

# Keep the last assignment for each symbol, matching the source builder
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

# Do not let a config fragment or Git metadata add another release suffix.
# The only suffix used by this build is the hardcoded LOCALVERSION above,
# stored in CONFIG_LOCALVERSION so the environment cannot duplicate it.
"${CONFIG_CMD[@]}" --set-str LOCALVERSION "$KERNEL_LOCALVERSION"
"${CONFIG_CMD[@]}" --disable LOCALVERSION_AUTO
"${CONFIG_CMD[@]}" --disable LOCALVERSION_SHA
export LOCALVERSION=""

# Detect the source-level KernelSU hooks before choosing the integration mode.
# This staging source currently has none of the six manual hooks, so the
# branch-link fallback must remain enabled. If a future source revision adds
# all of them, the fallback is disabled to avoid double hooking.
MANUAL_KSU_HOOK_COUNT=0
check_manual_ksu_hook() {
    local source_file="$1"
    local symbol="$2"
    if grep -Fq -- "$symbol" "$KERNEL_DIR/$source_file"; then
        echo -e "${GREEN}Manual KSU hook found: $source_file ($symbol)${NC}"
        MANUAL_KSU_HOOK_COUNT=$((MANUAL_KSU_HOOK_COUNT + 1))
    else
        echo -e "${BLUE}Manual KSU hook absent: $source_file ($symbol)${NC}"
    fi
}
check_manual_ksu_hook fs/exec.c ksu_handle_execveat
check_manual_ksu_hook fs/open.c ksu_handle_faccessat
check_manual_ksu_hook fs/stat.c ksu_handle_stat
check_manual_ksu_hook fs/stat.c ksu_handle_newfstat_ret
check_manual_ksu_hook kernel/reboot.c ksu_handle_sys_reboot
check_manual_ksu_hook security/selinux/avc.c ksu_slow_avc_audit

if [[ "$MANUAL_KSU_HOOK_COUNT" -eq 6 ]]; then
    echo -e "${YELLOW}All manual KSU hooks found; disabling branch-link fallback.${NC}"
else
    echo -e "${YELLOW}Manual KSU hooks incomplete ($MANUAL_KSU_HOOK_COUNT/6); keeping branch-link fallback enabled.${NC}"
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
            KSU_HACK_ARM64_BRANCH_LINK)
                if [[ "$MANUAL_KSU_HOOK_COUNT" -eq 6 ]]; then
                    "${CONFIG_CMD[@]}" --disable "$optional_symbol"
                else
                    "${CONFIG_CMD[@]}" --enable "$optional_symbol"
                fi ;;
            KSU_ENABLE_FULL_UID_CHECKS|KSU_NOPRINTK)
                "${CONFIG_CMD[@]}" --disable "$optional_symbol" ;;
            *)
                "${CONFIG_CMD[@]}" --enable "$optional_symbol" ;;
        esac
    fi
done

make "${MAKE_ARGS[@]}" olddefconfig

# Verify the final result of scripts/setlocalversion. It normally combines
# localversion* files, CONFIG_LOCALVERSION, LOCALVERSION and (when enabled)
# the Git SCM version. Only the hardcoded LOCALVERSION is allowed here.
KERNEL_VERSION="$(make -s "${MAKE_ARGS[@]}" kernelversion)"
KERNEL_RELEASE="$(make -s "${MAKE_ARGS[@]}" kernelrelease)"
EXPECTED_KERNEL_RELEASE="${KERNEL_VERSION}${KERNEL_LOCALVERSION}"
[[ "$KERNEL_VERSION" == "$STOCK_KERNEL_VERSION" ]] || \
    die "Unexpected kernel base version: got '$KERNEL_VERSION', expected '$STOCK_KERNEL_VERSION'"
[[ "$KERNEL_RELEASE" == "$EXPECTED_KERNEL_RELEASE" ]] || \
    die "Unexpected kernel suffix: got '$KERNEL_RELEASE', expected '$EXPECTED_KERNEL_RELEASE'"
echo -e "${BLUE}Kernel release: $KERNEL_RELEASE${NC}"

grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config" || die "External KernelSU is not enabled in .config"
grep -q '^CONFIG_LTO_CLANG=y$' "$OUT_DIR/.config" || die "CONFIG_LTO_CLANG is not enabled"
grep -q '^CONFIG_BUILD_ARM64_DT_OVERLAY=y$' "$OUT_DIR/.config" || \
    die "CONFIG_BUILD_ARM64_DT_OVERLAY is not enabled"
grep -q '^CONFIG_MACH_R8Q_EUR_OPEN=y$' "$OUT_DIR/.config" || \
    die "CONFIG_MACH_R8Q_EUR_OPEN is not enabled"
if is_ksu_symbol KSU_HACK_ARM64_BRANCH_LINK; then
    if [[ "$MANUAL_KSU_HOOK_COUNT" -eq 6 ]]; then
        grep -Eq '^# CONFIG_KSU_HACK_ARM64_BRANCH_LINK is not set$|^CONFIG_KSU_HACK_ARM64_BRANCH_LINK=n$' \
            "$OUT_DIR/.config" || die "KSU_HACK_ARM64_BRANCH_LINK must be disabled with manual hooks"
    else
        grep -q '^CONFIG_KSU_HACK_ARM64_BRANCH_LINK=y$' "$OUT_DIR/.config" || \
            die "KSU_HACK_ARM64_BRANCH_LINK must be enabled without complete manual hooks"
    fi
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
if ! make -j"$JOBS" "${MAKE_ARGS[@]}" Image dtbs dtbo.img 2>"$BUILD_STDERR"; then
    echo -e "${RED}Kernel build failed; relevant diagnostics:${NC}" >&2
    grep -E 'error:|fatal error:|LLVM ERROR|undefined symbol|ld\.lld: error|make(\[[0-9]+\])?: \*\*\*' \
        "$BUILD_STDERR" | tail -n 160 >&2 || tail -n 160 "$BUILD_STDERR" >&2
    echo -e "${YELLOW}Full stderr log: $BUILD_STDERR${NC}" >&2
    exit 1
fi

COMPILE_H="$OUT_DIR/include/generated/compile.h"
[[ -f "$COMPILE_H" ]] || die "Generated compile header was not found: $COMPILE_H"
grep -Fq '#define LINUX_COMPILER "clang version 10.0.6 for Android NDK"' "$COMPILE_H" || \
    die "Generated compiler identity does not match stock: $COMPILE_H"
grep -Fq '#define LINUX_COMPILE_BY "dpi"' "$COMPILE_H" || \
    die "Generated compiler user does not match stock: $COMPILE_H"
grep -Fq '#define LINUX_COMPILE_HOST "21DKGA22"' "$COMPILE_H" || \
    die "Generated compiler host does not match stock: $COMPILE_H"

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
        -name 'kona-sec-r8q-*.dtbo' -print | sort -V
)
[[ "${#DTBO_FILES[@]}" -gt 0 ]] || die "No r8q DTBO files were generated"

DTBOIMG="$OUT_DIR/dtbo.img"
echo -e "${BLUE}Packing ${#DTBO_FILES[@]} EUR r8q DTBO files...${NC}"
"$KERNEL_DIR/tools/mkdtimg" create "$DTBOIMG" --page_size=4096 "${DTBO_FILES[@]}"

MAGISKBOOT="$MAGISKBOOT_DIR/magiskboot"
mkdir -p "$MAGISKBOOT_DIR"

if [[ ! -x "$MAGISKBOOT" ]]; then
    need_cmd zstd
    [[ -n "$MAGISKBOOT_URL" ]] || die "Could not find a Magiskboot .7z release"

    MAGISKBOOT_ARCHIVE="$OUT_DIR/magiskboot.7z"
    echo -e "${YELLOW}Downloading Magiskboot...${NC}"
    curl -fL --retry 3 "$MAGISKBOOT_URL" -o "$MAGISKBOOT_ARCHIVE"
    7z e -y "$MAGISKBOOT_ARCHIVE" native/out/x86_64/magiskboot \
        "-o$MAGISKBOOT_DIR" >/dev/null
    rm -f -- "$MAGISKBOOT_ARCHIVE"
fi
[[ -x "$MAGISKBOOT" ]] || die "Magiskboot was not extracted: $MAGISKBOOT"

BUILD_TAG="${BUILD_TAG:-$(TZ='Asia/Makassar' date +%Y%m%d-%H%M)}"
PACK_DIR="$OUT_DIR/pack"
rm -rf -- "$PACK_DIR"
mkdir -p "$PACK_DIR"

echo -e "${YELLOW}Downloading stock boot.img...${NC}"
curl -fL --retry 3 "$ORIGIN_BOOTIMG_URL" -o "$PACK_DIR/original-boot.img"

echo -e "${YELLOW}Replacing kernel and DTB in stock boot.img...${NC}"
(
    cd "$PACK_DIR"
    "$MAGISKBOOT" unpack original-boot.img
    [[ -f kernel ]] || { echo "Magiskboot did not extract kernel" >&2; exit 1; }
    cp -- "$IMAGE" kernel
    cp -- "$DTB_OUT" dtb
    "$MAGISKBOOT" repack original-boot.img
)

[[ -s "$PACK_DIR/new-boot.img" ]] || die "Magiskboot did not create new-boot.img"
mv -- "$PACK_DIR/new-boot.img" "$PACK_DIR/boot.img"
cp -- "$DTBOIMG" "$PACK_DIR/dtbo.img"

BOOT_SIZE_BYTES="$(wc -c < "$PACK_DIR/boot.img")"
[[ "$BOOT_SIZE_BYTES" =~ ^[0-9]+$ ]] || die "Could not determine boot.img size"
if (( BOOT_SIZE_BYTES > BOOT_PARTITION_SIZE )); then
    die "boot.img is ${BOOT_SIZE_BYTES} bytes, larger than the ${BOOT_PARTITION_SIZE}-byte boot partition budget"
fi
echo -e "${BLUE}boot.img size: ${BOOT_SIZE_BYTES} bytes; partition budget: ${BOOT_PARTITION_SIZE} bytes${NC}"

TAR_NAME="${DEVICE}-${BUILD_TAG}-kernel.tar"
tar -cf "$OUT_DIR/$TAR_NAME" -C "$PACK_DIR" boot.img dtbo.img
[[ -s "$OUT_DIR/$TAR_NAME" ]] || die "Kernel TAR was not generated"

echo -e "${GREEN}Done: $OUT_DIR/$TAR_NAME${NC}"
echo -e "${GREEN}Completed in $((SECONDS / 60))m $((SECONDS % 60))s${NC}"
