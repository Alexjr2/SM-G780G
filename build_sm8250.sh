#!/usr/bin/env bash

set -Eeuo pipefail

SECONDS=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="${KERNEL_DIR:-$SCRIPT_DIR}"
DEVICE="${DEVICE:-r8q}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/out/$DEVICE}"
TOOLCHAIN_DIR="${TOOLCHAIN_DIR:-$SCRIPT_DIR/clang-toolchain}"
MAGISKBOOT_DIR="${MAGISKBOOT_DIR:-$OUT_DIR/magiskboot}"
DEFCONFIG="${DEFCONFIG:-vendor/r8q_eur_open_defconfig}"
JOBS="${JOBS:-$(nproc)}"
STOCK_CONFIG_SOURCE="${STOCK_CONFIG_SOURCE:-$SCRIPT_DIR/stock_R8Q}"
KSU_SETUP_URL="${KSU_SETUP_URL:-https://raw.githubusercontent.com/backslashxx/KernelSU/master/kernel/setup.sh}"
KSU_REF="${KSU_REF:-master}"
CLANG_TOOLCHAIN_URL="${CLANG_TOOLCHAIN_URL:-}"

ORIGIN_BOOTIMG_URL="${ORIGIN_BOOTIMG_URL:-https://github.com/Alexjr2/SM-G780G/releases/download/originalboot/boot.img}"
MAGISKBOOT_REPO="${MAGISKBOOT_REPO:-xiaoxindada/magisk_bins_ndk}"

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

for cmd in make curl jq tar 7z git; do
    need_cmd "$cmd"
done

[[ -f "$KERNEL_DIR/Makefile" ]] || die "Kernel source not found: $KERNEL_DIR"
[[ -f "$KERNEL_DIR/arch/arm64/configs/$DEFCONFIG" ]] || \
    die "Defconfig not found: arch/arm64/configs/$DEFCONFIG"
[[ -x "$KERNEL_DIR/tools/mkdtimg" ]] || die "Missing executable: $KERNEL_DIR/tools/mkdtimg"
[[ -x "$KERNEL_DIR/tools/dtc" ]] || die "Missing executable: $KERNEL_DIR/tools/dtc"
[[ -f "$KERNEL_DIR/scripts/gcc-wrapper.py" ]] || die "Missing compiler wrapper: $KERNEL_DIR/scripts/gcc-wrapper.py"
[[ -f "$KERNEL_DIR/scripts/mkcompile_h" ]] || die "Missing compile header generator: $KERNEL_DIR/scripts/mkcompile_h"

# The release archive contains read-only source files. KernelSU and the
# reproducible-build adjustments below must be able to edit this tree.
chmod -R u+rwX "$KERNEL_DIR"

# This Samsung 4.19 tree invokes gcc-wrapper.py directly when CONFIG_CFP=y.
# Its old Python 2 shebang is not available on Ubuntu 24.04; the wrapper code
# is Python 3 compatible, so fix only the interpreter line in the extracted tree.
sed -i '1s|python2|python3|' "$KERNEL_DIR/scripts/gcc-wrapper.py"

# This vendor wrapper promotes every compiler warning to a fatal error. That
# policy is incompatible with the newer Clang used on GitHub Actions: this
# 4.19 tree contains harmless legacy warnings such as unused-but-set globals.
# Keep the wrapper available, but make its forbidden-warning check opt-in.
if grep -Fq 'if m and m.group(2) not in allowed_warnings:' "$KERNEL_DIR/scripts/gcc-wrapper.py"; then
    sed -i 's|if m and m.group(2) not in allowed_warnings:|if os.environ.get("KBUILD_STRICT_WARNINGS", "0") == "1" and m and m.group(2) not in allowed_warnings:|' \
        "$KERNEL_DIR/scripts/gcc-wrapper.py"
else
    die "Unsupported gcc-wrapper.py: warning gate was not found"
fi
# The vendor wrapper reprinted compiler stderr on stdout. That bypassed the
# build log capture below and made every warning visible in Actions. Keep the
# diagnostics on stderr, where they can be summarized only when the build
# actually fails.
sed -i 's|^[[:space:]]*print(line)$|            print(line, file=sys.stderr, end="")|' \
    "$KERNEL_DIR/scripts/gcc-wrapper.py"
export KBUILD_STRICT_WARNINGS="0"

# Keep the kernel identity equal to the stock build, even when the actual
# build uses a downloaded Clang toolchain.
sed -i "/LINUX_COMPILER/c\\  echo '#define LINUX_COMPILER \"clang version 10.0.6 for Android NDK\"'" \
    "$KERNEL_DIR/scripts/mkcompile_h"

export LOCALVERSION="-27223811"
export KBUILD_BUILD_USER="dpi"
export KBUILD_BUILD_HOST="21DKGA22"
export KBUILD_BUILD_VERSION="1"
export KBUILD_BUILD_TIMESTAMP="Tue Sep 30 19:38:09 KST 2025"
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export CROSS_COMPILE_ARM32="${CROSS_COMPILE_ARM32:-arm-linux-gnueabi-}"
export CLANG_TRIPLE="${CLANG_TRIPLE:-aarch64-linux-gnu-}"
# Keep CI output readable. `-w` suppresses warnings only; real compiler errors
# remain visible and still stop the build.
export KCFLAGS="${KCFLAGS:--w -fno-builtin-stpcpy -Wno-error=pointer-to-enum-cast -Wno-error=int-conversion -Wno-error=strict-prototypes -Wno-unused-variable -Wno-unused-function}"

if [[ -n "${CLANG_BIN:-}" ]]; then
    [[ -x "$CLANG_BIN" ]] || die "CLANG_BIN is not executable: $CLANG_BIN"
elif [[ -x "$TOOLCHAIN_DIR/bin/clang" ]]; then
    CLANG_BIN="$TOOLCHAIN_DIR/bin/clang"
elif [[ "${DOWNLOAD_TOOLCHAIN:-1}" != "1" ]] && command -v clang >/dev/null 2>&1; then
    CLANG_BIN="$(command -v clang)"
else
    need_cmd zstd

    echo -e "${YELLOW}Clang toolchain not found; downloading the latest Neutron toolchain...${NC}"
    mkdir -p "$TOOLCHAIN_DIR"
    TOOLCHAIN_URL="${CLANG_TOOLCHAIN_URL:-}"
    if [[ -z "$TOOLCHAIN_URL" ]]; then
        TOOLCHAIN_URL="$(curl -fsSL "https://api.github.com/repos/Neutron-Toolchains/clang-build-catalogue/releases/latest" \
            | jq -r '[.assets[] | select(.name | endswith(".tar.zst"))][0].browser_download_url // empty')"
    fi
    [[ -n "$TOOLCHAIN_URL" ]] || die "Could not find a .tar.zst Clang release"
    curl -fL --retry 3 "$TOOLCHAIN_URL" \
        | tar --zstd -x -C "$TOOLCHAIN_DIR" --strip-components=1
    CLANG_BIN="$TOOLCHAIN_DIR/bin/clang"
fi

[[ -x "$CLANG_BIN" ]] || die "Clang was not found: $CLANG_BIN"
TOOLCHAIN_BIN="$(dirname "$CLANG_BIN")"
export PATH="$TOOLCHAIN_BIN:$PATH"

echo -e "${BLUE}Kernel source : $KERNEL_DIR${NC}"
echo -e "${BLUE}Output        : $OUT_DIR${NC}"
echo -e "${BLUE}Clang         : $CLANG_BIN${NC}"
echo -e "${BLUE}Defconfig     : $DEFCONFIG${NC}"

rm -rf -- "$OUT_DIR"
mkdir -p "$OUT_DIR"

# The vendor CFP post-link instrumenter derives objdump/nm from CROSS_COMPILE.
# With a Clang toolchain prepended to PATH, those names can resolve to LLVM
# binaries. This old Python instrumenter uses stdout pipes that LLVM's tools
# do not tolerate when it stops reading a stream, producing a fatal-looking
# `LLVM ERROR: IO failure on output stream: Broken pipe` after vmlinux links.
# Keep Clang for compilation, but force CFP to use GNU ARM64 binutils.
is_gnu_binutils() {
    local tool_version
    tool_version="$("$1" --version 2>&1 | sed -n '1p')"
    [[ "$tool_version" == *GNU* && "$tool_version" != *LLVM* ]]
}

CFP_CROSS_COMPILE="${CFP_CROSS_COMPILE:-}"
if [[ -z "$CFP_CROSS_COMPILE" ]]; then
    for candidate in /usr/bin/aarch64-linux-gnu- /usr/local/bin/aarch64-linux-gnu-; do
        if [[ -x "${candidate}objdump" && -x "${candidate}nm" ]] && \
           is_gnu_binutils "${candidate}objdump" && is_gnu_binutils "${candidate}nm"; then
            CFP_CROSS_COMPILE="$candidate"
            break
        fi
    done
fi

if [[ -z "$CFP_CROSS_COMPILE" ]]; then
    CFP_OBJDUMP_BIN="$(command -v "${CROSS_COMPILE}objdump" || true)"
    CFP_NM_BIN="$(command -v "${CROSS_COMPILE}nm" || true)"
    if [[ -n "$CFP_OBJDUMP_BIN" && -n "$CFP_NM_BIN" ]] && \
       is_gnu_binutils "$CFP_OBJDUMP_BIN" && is_gnu_binutils "$CFP_NM_BIN"; then
        CFP_CROSS_COMPILE="${CFP_OBJDUMP_BIN%objdump}"
    fi
fi

[[ -n "$CFP_CROSS_COMPILE" ]] || \
    die "GNU ARM64 binutils required by CFP (aarch64-linux-gnu-objdump/nm) were not found"
[[ -x "${CFP_CROSS_COMPILE}objdump" && -x "${CFP_CROSS_COMPILE}nm" ]] || \
    die "Invalid CFP_CROSS_COMPILE: $CFP_CROSS_COMPILE"
is_gnu_binutils "${CFP_CROSS_COMPILE}objdump" || \
    die "CFP objdump is not GNU binutils: ${CFP_CROSS_COMPILE}objdump"
is_gnu_binutils "${CFP_CROSS_COMPILE}nm" || \
    die "CFP nm is not GNU binutils: ${CFP_CROSS_COMPILE}nm"
export CFP_CROSS_COMPILE

CFP_INSTRUMENT="$KERNEL_DIR/scripts/cfp/instrument.py"
[[ -f "$CFP_INSTRUMENT" ]] || die "Missing CFP instrumenter: $CFP_INSTRUMENT"
if grep -Fq "CROSS_COMPILE = os.environ.get('CROSS_COMPILE')" "$CFP_INSTRUMENT"; then
    sed -i "s|CROSS_COMPILE = os.environ.get('CROSS_COMPILE')|CROSS_COMPILE = os.environ.get('CFP_CROSS_COMPILE', os.environ.get('CROSS_COMPILE'))|" \
        "$CFP_INSTRUMENT"
elif ! grep -Fq "os.environ.get('CFP_CROSS_COMPILE'" "$CFP_INSTRUMENT"; then
    die "Unsupported CFP instrumenter: cannot select GNU binutils"
fi
echo -e "${BLUE}CFP binutils  : ${CFP_CROSS_COMPILE}objdump / ${CFP_CROSS_COMPILE}nm${NC}"

# Use the ARM64 GNU assembler for old vDSO assembly syntax. Put it behind a
# plain `as` name in a private tool directory so Clang cannot fall back to the
# host /usr/bin/as when -no-integrated-as is enabled by this old kernel tree.
CROSS_AS="$(command -v "${CROSS_COMPILE}as" || true)"
[[ -n "$CROSS_AS" ]] || die "ARM64 assembler not found: ${CROSS_COMPILE}as"
AS_TOOL_DIR="$OUT_DIR/assembler-bin"
mkdir -p "$AS_TOOL_DIR"
ln -sfn "$CROSS_AS" "$AS_TOOL_DIR/as"
export PATH="$AS_TOOL_DIR:$PATH"
if grep -q -- '-no-integrated-as' "$KERNEL_DIR/Makefile"; then
    # Keep C compilation on Clang IAS; apply the legacy external assembler
    # only to KBUILD_AFLAGS used by .S/vDSO files.
    sed -E -i "s|^[[:space:]]*CLANG_FLAGS[[:space:]]*\+=[[:space:]]*-no-integrated-as|CLANG_FLAGS +=|" \
        "$KERNEL_DIR/Makefile"
    sed -i "/^CLANG_FLAGS +=$/a KBUILD_AFLAGS += -no-integrated-as -B${AS_TOOL_DIR}/" \
        "$KERNEL_DIR/Makefile"
fi

# genksyms in this 4.19 tree cannot parse the packed return type of the helper
# immediately preceding gsi_write_channel_scratch(). That makes genksyms omit
# the CRC, after which ld.lld fails on __crc_gsi_write_channel_scratch. The
# returned union remains packed; __packed is only removed from the return-type
# spelling, so its layout and ABI are unchanged.
GSI_HEADER="$KERNEL_DIR/include/linux/msm_gsi.h"
GSI_SOURCE="$KERNEL_DIR/drivers/platform/msm/gsi/gsi.c"
[[ -f "$GSI_HEADER" && -f "$GSI_SOURCE" ]] || die "GSI sources not found"
sed -i 's/static union __packed gsi_channel_scratch __gsi_update_mhi_channel_scratch/static union gsi_channel_scratch __gsi_update_mhi_channel_scratch/' \
    "$GSI_SOURCE"

# This Samsung tree was normally built from a larger Android checkout. In the
# standalone kernel archive the Android helper secgetspf is absent; make its
# optional feature probes return empty instead of emitting command-not-found
# noise during every make invocation.
SECGETSPF_FILES=(
    "$KERNEL_DIR/Makefile"
    "$KERNEL_DIR/drivers/net/wireless/qualcomm/qca6390/qcacld-3.0/Kbuild"
)
for secgetspf_file in "${SECGETSPF_FILES[@]}"; do
    [[ -f "$secgetspf_file" ]] || continue
    sed -i \
        -e 's|\$(shell secgetspf SEC_PRODUCT_FEATURE_BIOAUTH_CONFIG_FINGERPRINT_TZ)|\$(shell if command -v secgetspf >/dev/null 2>\&1; then secgetspf SEC_PRODUCT_FEATURE_BIOAUTH_CONFIG_FINGERPRINT_TZ; fi)|g' \
        -e 's|\$(shell secgetspf SEC_PRODUCT_FEATURE_COMMON_CONFIG_SEP_VERSION)|\$(shell if command -v secgetspf >/dev/null 2>\&1; then secgetspf SEC_PRODUCT_FEATURE_COMMON_CONFIG_SEP_VERSION; fi)|g' \
        -e 's|\$(shell secgetspf SEC_PRODUCT_FEATURE_WLAN_SUPPORT_MIMO)|\$(shell if command -v secgetspf >/dev/null 2>\&1; then secgetspf SEC_PRODUCT_FEATURE_WLAN_SUPPORT_MIMO; fi)|g' \
        "$secgetspf_file"
done

# kperfmon already ships the needed perflog.h inside this kernel archive. Its
# Makefile nevertheless unconditionally copies a header from the absent
# Android system/core checkout; use the in-tree header as the fallback.
KPERFMON_MAKEFILE="$KERNEL_DIR/drivers/kperfmon/Makefile"
if [[ -f "$KPERFMON_MAKEFILE" ]]; then
    sed -i \
        -e 's#\$(shell \[ -e \$(srctree)/../../system/core/liblog/include/log/perflog.h \] \&\& echo exist)#\$(shell if [ -e \$(srctree)/../../system/core/liblog/include/log/perflog.h ] || [ -e \$(srctree)/include/linux/perflog.h ]; then echo exist; fi)#g' \
        -e 's#\$(shell cp -f \$(srctree)/../../system/core/liblog/include/log/perflog.h  \$(srctree)/include/linux/)#\$(shell if [ -e \$(srctree)/../../system/core/liblog/include/log/perflog.h ]; then cp -f \$(srctree)/../../system/core/liblog/include/log/perflog.h \$(srctree)/include/linux/; fi)#g' \
        "$KPERFMON_MAKEFILE"
fi

echo -e "${YELLOW}Adding backslashxx KernelSU...${NC}"
(
    cd "$KERNEL_DIR"
    curl -LSs "$KSU_SETUP_URL" | bash -s "$KSU_REF"
)
[[ -d "$KERNEL_DIR/KernelSU" ]] || die "KernelSU setup did not create $KERNEL_DIR/KernelSU"
[[ -L "$KERNEL_DIR/drivers/kernelsu" ]] || die "KernelSU driver symlink was not created"
grep -Fq 'obj-$(CONFIG_KSU) += kernelsu/' "$KERNEL_DIR/drivers/Makefile" || \
    die "KernelSU Makefile entry was not added"
grep -Fq 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig" || \
    die "KernelSU Kconfig entry was not added"
KSU_GIT_VERSION="$(git -C "$KERNEL_DIR/KernelSU" rev-list --count HEAD)"
KERNELSU_VERSION=$((KSU_GIT_VERSION + 30000 - 84))
echo -e "${GREEN}KernelSU version: $KERNELSU_VERSION${NC}"

MAKE_ARGS=(
    -C "$KERNEL_DIR"
    O="$OUT_DIR"
    ARCH=arm64
    CROSS_COMPILE="$CROSS_COMPILE"
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32"
    CFLAGS_KERNEL="$KCFLAGS"
    CFLAGS_MODULE="$KCFLAGS"
    REAL_CC="$CLANG_BIN"
    CFP_CC="$CLANG_BIN"
    CLANG_TRIPLE="$CLANG_TRIPLE"
    DTC_EXT="$KERNEL_DIR/tools/dtc"
    CONFIG_BUILD_ARM64_DT_OVERLAY=y
    HOSTCC=clang
    HOSTCXX=clang++
    HOSTCFLAGS=-w
    HOSTCXXFLAGS=-w
    PYTHON=python3
    PYTHON2=python3
    PYTHON3=python3
    LD=ld.lld
    AR=llvm-ar
    NM=llvm-nm
    STRIP=llvm-strip
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    OBJSIZE=llvm-size
    READELF=llvm-readelf
    LLVM=1
    LLVM_IAS=1
)

echo -e "${YELLOW}Preparing $DEFCONFIG...${NC}"
make "${MAKE_ARGS[@]}" "$DEFCONFIG"

echo -e "${YELLOW}Applying KernelSU configuration...${NC}"
[[ -f "$KERNEL_DIR/scripts/config" ]] || die "Missing config helper: $KERNEL_DIR/scripts/config"
bash "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    --enable KSU \
    --enable KSU_HACK_ARM64_BRANCH_LINK \
    --disable KSU_TAMPER_SYSCALL_TABLE \
    --enable KSU_LSM_SECURITY_HOOKS \
    --enable KSU_FEATURE_SULOG \
    --enable KSU_FEATURE_ADBROOT \
    --disable KSU_FEATURE_ADBROOT_DEFAULT_ENABLE \
    --enable KSU_HOSTSREDIRECT \
    --disable KSU_ENABLE_FULL_UID_CHECKS \
    --enable KSU_THRONE_TRACKER_ALWAYS_THREADED \
    --disable KSU_NOPRINTK \
    --enable KSU_SHELL_HAS_SU_ALWAYS \
    --disable KSU_DEBUG \
    --enable KSU_HEURISTIC_IN_TREE_BUILD
make "${MAKE_ARGS[@]}" olddefconfig

echo -e "${YELLOW}Embedding stock_R8Q as /proc/config.gz...${NC}"
STOCK_CONFIG="$KERNEL_DIR/arch/arm64/configs/stock_R8Q"
if [[ ! -s "$STOCK_CONFIG_SOURCE" && -s "$KERNEL_DIR/stock_R8Q" ]]; then
    STOCK_CONFIG_SOURCE="$KERNEL_DIR/stock_R8Q"
fi
[[ -s "$STOCK_CONFIG_SOURCE" ]] || die "Local stock_R8Q not found: $STOCK_CONFIG_SOURCE"
cp -- "$STOCK_CONFIG_SOURCE" "$STOCK_CONFIG"
[[ -f "$KERNEL_DIR/kernel/Makefile" ]] || die "Kernel Makefile not found: $KERNEL_DIR/kernel/Makefile"
sed -i 's|\$(KCONFIG_CONFIG)|$(srctree)/arch/arm64/configs/stock_R8Q|' "$KERNEL_DIR/kernel/Makefile"

echo -e "${YELLOW}Building Image and DTB/DTBO files...${NC}"
# Keep compiler stderr in a file so legacy dtc/compiler warnings do not flood
# Actions. There is no pipe in the compiler path, so parallel Clang jobs cannot
# fail with a misleading broken-pipe diagnostic. On failure, print only the
# actionable error lines and retain the complete stderr log for inspection.
BUILD_STDERR="$OUT_DIR/build.stderr.log"
if ! make -j"$JOBS" "${MAKE_ARGS[@]}" Image dtbs 2>"$BUILD_STDERR"; then
    echo -e "${RED}Kernel build failed; relevant diagnostics:${NC}" >&2
    if grep -Eq 'error:|fatal error:|LLVM ERROR|undefined symbol|ld\.lld: error|make(\[[0-9]+\])?: \*\*\*' \
        "$BUILD_STDERR"; then
        grep -E 'error:|fatal error:|LLVM ERROR|undefined symbol|ld\.lld: error|make(\[[0-9]+\])?: \*\*\*' \
            "$BUILD_STDERR" | tail -n 120 >&2
    else
        tail -n 120 "$BUILD_STDERR" >&2
    fi
    echo -e "${YELLOW}Full stderr log: $BUILD_STDERR${NC}" >&2
    exit 1
fi

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
[[ -f "$IMAGE" ]] || die "Kernel Image was not generated"

mapfile -t DTB_FILES < <(find "$OUT_DIR/arch/arm64/boot/dts" -type f -name '*.dtb' -print | sort -V)
[[ "${#DTB_FILES[@]}" -gt 0 ]] || die "No DTB files were generated"
cat "${DTB_FILES[@]}" > "$OUT_DIR/dtb"

DTBO_DIR="$OUT_DIR/arch/arm64/boot/dts/samsung/$DEVICE"
mapfile -t DTBO_FILES < <(find "$DTBO_DIR" -type f -name '*.dtbo' -print 2>/dev/null | sort -V)
[[ "${#DTBO_FILES[@]}" -gt 0 ]] || die "No DTBO files were generated in $DTBO_DIR"

DTBOIMG="$OUT_DIR/dtbo.img"
echo -e "${BLUE}Packing ${#DTBO_FILES[@]} DTBO files...${NC}"
chmod +x "$KERNEL_DIR/tools/mkdtimg"
"$KERNEL_DIR/tools/mkdtimg" create "$DTBOIMG" --page_size=4096 "${DTBO_FILES[@]}"

mkdir -p "$MAGISKBOOT_DIR"
MAGISKBOOT="$MAGISKBOOT_DIR/magiskboot"
if [[ ! -x "$MAGISKBOOT" ]]; then
    MAGISKBOOT_URL="${MAGISKBOOT_URL:-}"
    if [[ -z "$MAGISKBOOT_URL" ]]; then
        MAGISKBOOT_URL="$(curl -fsSL "https://api.github.com/repos/$MAGISKBOOT_REPO/releases/latest" \
            | jq -r '[.assets[] | select(.name | endswith(".7z"))][0].browser_download_url // empty')"
    fi
    [[ -n "$MAGISKBOOT_URL" ]] || die "Could not find a Magiskboot .7z release"
    MAGISKBOOT_ARCHIVE="$OUT_DIR/magiskboot.7z"
    curl -fL --retry 3 "$MAGISKBOOT_URL" -o "$MAGISKBOOT_ARCHIVE"
    7z e -y "$MAGISKBOOT_ARCHIVE" native/out/x86_64/magiskboot "-o$MAGISKBOOT_DIR" >/dev/null
    rm -f -- "$MAGISKBOOT_ARCHIVE"
fi
[[ -x "$MAGISKBOOT" ]] || die "Magiskboot was not extracted: $MAGISKBOOT"

PACK_DIR="$OUT_DIR/pack"
rm -rf -- "$PACK_DIR"
mkdir -p "$PACK_DIR"

echo -e "${YELLOW}Downloading original boot image...${NC}"
curl -fL --retry 3 "$ORIGIN_BOOTIMG_URL" -o "$PACK_DIR/original-boot.img"

echo -e "${YELLOW}Replacing kernel and DTB in boot image...${NC}"
(
    cd "$PACK_DIR"
    "$MAGISKBOOT" unpack original-boot.img
    cp "$IMAGE" kernel
    cp "$OUT_DIR/dtb" dtb
    "$MAGISKBOOT" repack original-boot.img
)
[[ -f "$PACK_DIR/new-boot.img" ]] || die "Magiskboot did not create new-boot.img"
mv -- "$PACK_DIR/new-boot.img" "$PACK_DIR/boot.img"
cp "$DTBOIMG" "$PACK_DIR/dtbo.img"

BUILD_TAG="${BUILD_TAG:-$(TZ='Asia/Shanghai' date +%Y%m%d%H)}"
TAR_NAME="${DEVICE}-${BUILD_TAG}-kernel.tar"
tar -cf "$OUT_DIR/$TAR_NAME" -C "$PACK_DIR" boot.img dtbo.img

echo -e "${GREEN}Done: $OUT_DIR/$TAR_NAME${NC}"
echo -e "${GREEN}Completed in $((SECONDS / 60))m $((SECONDS % 60))s${NC}"
