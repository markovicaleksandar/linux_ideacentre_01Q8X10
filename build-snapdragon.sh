#!/usr/bin/env bash
set -euo pipefail

# Build a mainline arm64 kernel for the Lenovo IdeaCentre Mini X (X1E80100).
#
# Pipeline:
#   1. Check + apt-install missing dependencies
#   2. Shallow-clone torvalds/linux master into ./linux (skip if present)
#   3. Apply Bjorn's v2 IdeaCentre patches (idempotent)
#   4. Copy ../fix-kernel-config.sh into ./linux and run it
#      (config + pcie3 disable in the board DTS)
#   5. Build Image + dtbs
#   6. Print absolute paths to Image and DTB for the PXE server
#
# Usage:
#   ./build-snapdragon.sh           # full build
#   ./build-snapdragon.sh -c        # revert linux/ tree to freshly-cloned state

###

info()  { echo -e "\n\033[1;34m>>> $*\033[0m"; }
warn()  { echo -e "\033[33mWARNING: $*\033[0m" >&2; }
error() { echo -e "\n\033[1;31mERROR: $*\033[0m" >&2; }

###

# --- Argument parsing
DO_CLEAN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--clean)     DO_CLEAN=true; shift ;;
        -h|--help)
            sed -n '4,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) error "unknown option: $1"; exit 1 ;;
    esac
done

###

# --- Locations
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FIX_CONFIG_SRC="$SCRIPT_DIR/fix-kernel-config.sh"
LINUX_DIR="$PWD/linux"
GIT_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
MBOX_URL="https://patchew.org/linux/20260401-ideacentre-v2-0-5745fe2c764e@oss.qualcomm.com/mbox"
MBOX_FILE="/tmp/ideacentre-v2.mbox"
DTS_BASENAME="hamoa-lenovo-ideacentre-mini-01q8x10.dts"

[[ -f "$FIX_CONFIG_SRC" ]] || { error "fix-kernel-config.sh not found at $FIX_CONFIG_SRC"; exit 1; }

CROSS=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
MODULES_STAGE="$PWD/modules-stage"
MODULES_TAR="$PWD/modules.tar.gz"
###

check_dependencies() {
    info "Checking build dependencies"

    # Map: command -> apt package providing it
    declare -A pkg_for=(
        [aarch64-linux-gnu-gcc]="gcc-aarch64-linux-gnu"
        [flex]="flex"
        [bison]="bison"
        [bc]="bc"
        [make]="make"
        [git]="git"
        [wget]="wget"
        [filterdiff]="patchutils"
        [pkg-config]="pkg-config"
        [depmod]="kmod"
    )

    # These commands map to dev libraries (no command to check directly)
    # Verified via dpkg-query.
    local dev_pkgs=(libssl-dev libdw-dev debhelper)

    local missing=()
    for cmd in "${!pkg_for[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("${pkg_for[$cmd]}")
        fi
    done

    for pkg in "${dev_pkgs[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing missing packages: ${missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y "${missing[@]}"
    else
        info "All dependencies present"
    fi
}

###

fetch_kernel() {
    if [[ -d "$LINUX_DIR/.git" ]]; then
        info "Kernel tree already at $LINUX_DIR, skipping clone"
        return 0
    fi

    if [[ -e "$LINUX_DIR" ]]; then
        error "$LINUX_DIR exists but is not a git repo — refusing to overwrite"
        exit 1
    fi

    info "Shallow-cloning torvalds/linux master (this is the slow step)"
    # --depth 1 + --single-branch keeps the clone under ~300MB and ~1-2 min
    # on a fast link. We don't need history; patches are applied by hand.
    git clone --depth 1 --single-branch --branch master "$GIT_URL" "$LINUX_DIR"
}

###

apply_patches() {
    cd "$LINUX_DIR"

    # Sanity check: hamoa.dtsi must exist or the patches won't apply
    if [[ ! -f arch/arm64/boot/dts/qcom/hamoa.dtsi ]]; then
        error "hamoa.dtsi not found — kernel base is too old"
        exit 1
    fi
    info "hamoa.dtsi present — kernel base is good"

    # Idempotency: if the IdeaCentre DTS already exists, patches were applied
    if [[ -f "arch/arm64/boot/dts/qcom/$DTS_BASENAME" ]]; then
        info "IdeaCentre DTS already in tree, skipping patch application"
        cd - >/dev/null
        return 0
    fi

    if [[ ! -f "$MBOX_FILE" ]]; then
        info "Downloading Bjorn's v2 patches"
        wget -q -O "$MBOX_FILE" "$MBOX_URL"
    else
        info "Mbox already cached at $MBOX_FILE"
    fi

    # Load the mbox into am state, extract the IdeaCentre DTS bits via
    # filterdiff, apply, then clean up the am state. This pattern works
    # regardless of whether sibling patches in the series (yaml binding,
    # qseecom) conflict with the current tree.
    git am "$MBOX_FILE" || true
    git am --show-current-patch=diff \
        | filterdiff -i '*/hamoa-lenovo*' \
        | git apply
    git am --abort 2>/dev/null || true
    info "DTS patch applied"

    # Add compatible string to qcom.yaml binding doc.
    # Match-based (not line-number-based) so it survives kernel version drift.
    local yaml="Documentation/devicetree/bindings/arm/qcom.yaml"
    if ! grep -q "lenovo,ideacentre-mini-01q8x10" "$yaml"; then
        info "Adding compatible string to $yaml"
        # Insert after the hp,omnibook-x14 line (alphabetical neighbor).
        sed -i '/hp,omnibook-x14/a\              - lenovo,ideacentre-mini-01q8x10' "$yaml"

        if ! grep -q "lenovo,ideacentre-mini-01q8x10" "$yaml"; then
            error "yaml insertion silently failed — anchor 'hp,omnibook-x14' not found"
            exit 1
        fi
    else
        info "qcom.yaml already lists ideacentre compatible"
    fi

    # Verify the DTS landed in Makefile (auto-added by patches usually,
    # but worth confirming so build doesn't silently skip the DTB).
    if ! grep -q "${DTS_BASENAME%.dts}" arch/arm64/boot/dts/qcom/Makefile; then
        warn "DTS not in Makefile — adding"
        echo "dtb-\$(CONFIG_ARCH_QCOM) += ${DTS_BASENAME%.dts}.dtb" \
            >> arch/arm64/boot/dts/qcom/Makefile
    fi

    cd - >/dev/null
}

###

configure_kernel() {
    info "Copying fix-kernel-config.sh into kernel tree"
    cp "$FIX_CONFIG_SRC" "$LINUX_DIR/fix-kernel-config.sh"
    chmod +x "$LINUX_DIR/fix-kernel-config.sh"

    info "Running fix-kernel-config.sh"
    cd "$LINUX_DIR"
    ./fix-kernel-config.sh
    cd - >/dev/null
}

###

has_modules() { grep -q '^CONFIG_MODULES=y' "$LINUX_DIR/.config"; }

build_kernel() {
    local targets=(Image dtbs)
    if has_modules; then
        targets+=(modules)
    else
        warn "CONFIG_MODULES unset: no modules, initrd must be fully built-in"
    fi
    info "Building ${targets[*]} (-j$(nproc))"
    cd "$LINUX_DIR"
    make "${CROSS[@]}" -j"$(nproc)" "${targets[@]}"
    cd - >/dev/null
}

###

package_modules() {
    has_modules || return 0
    info "Packaging modules"
    cd "$LINUX_DIR"
    rm -rf "$MODULES_STAGE"
    make "${CROSS[@]}" INSTALL_MOD_PATH="$MODULES_STAGE" \
        INSTALL_MOD_STRIP=1 modules_install
    tar -C "$MODULES_STAGE" \
        --exclude='lib/modules/*/build' --exclude='lib/modules/*/source' \
        -czf "$MODULES_TAR" lib/modules
    echo -e "  \033[32mModules\033[0m: $MODULES_TAR ($(make -s kernelrelease))"
    cd - >/dev/null
}

###

report_artifacts() {
    local image="$LINUX_DIR/arch/arm64/boot/Image"
    local dtb="$LINUX_DIR/arch/arm64/boot/dts/qcom/${DTS_BASENAME%.dts}.dtb"

    info "Build complete. Artifacts for PXE:"

    if [[ -f "$image" ]]; then
        echo -e "  \033[32mImage\033[0m: $image"
        echo "    size: $(du -h "$image" | cut -f1)"
    else
        error "Image not found at $image"
        exit 1
    fi

    if [[ -f "$dtb" ]]; then
        echo -e "  \033[32mDTB  \033[0m: $dtb"
        echo "    size: $(du -h "$dtb" | cut -f1)"
    else
        error "DTB not found at $dtb"
        exit 1
    fi
}

###

clean_tree() {
    if [[ ! -d "$LINUX_DIR/.git" ]]; then
        info "No kernel tree at $LINUX_DIR — nothing to clean"
        return 0
    fi

    info "Reverting tree to clean state (as if freshly cloned)"
    cd "$LINUX_DIR"

    # Abort any half-applied am state from a previous failed run
    git am --abort 2>/dev/null || true

    # Discard tracked-file modifications (DTS, yaml binding, Makefile edits)
    git reset --hard HEAD

    # Remove untracked + ignored files: .config, build outputs, copied
    # fix-kernel-config.sh, all *.o, Image, dtbs, etc.
    git clean -fdx

    cd - >/dev/null
    info "Tree clean"
}

###

main() {
    if $DO_CLEAN; then
        clean_tree
        exit 0
    fi

    check_dependencies
    fetch_kernel
    apply_patches
    configure_kernel
    build_kernel
    package_modules
    report_artifacts
}

main "$@"