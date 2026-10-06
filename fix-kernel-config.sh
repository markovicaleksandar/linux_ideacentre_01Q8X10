#!/usr/bin/env bash
set -euo pipefail

# Configure the upstream arm64 kernel for the IdeaCentre Mini X (X1E80100).
#
# Strategy: always start from a fresh `make ARCH=arm64 defconfig` (the
# same baseline Bjorn Andersson tests against). That config builds NVMe,
# USB PHYs and pmic-glink as modules. We're booting via NFS root with no
# initramfs, so we flip everything we need before rootfs to =y, then add
# the bits defconfig leaves off (USB-C retimer, UCSI, NFS root, debug).
#
# Also disables pcie3 (1bd0000) in the board DTS: probing it warm-resets
# the SoC. The primary NVMe slot (pcie6a, 1bf8000) is unaffected.
#
# Any change to .config goes through this script — the script owns the
# pipeline. If you ran menuconfig and want to keep changes, save them
# as a fragment and add them here first.
#
# Usage:
#   ./fix-kernel-config.sh
#
# Run from kernel tree root.

###

info()  { echo -e "\033[1;34m>>> $*\033[0m"; }
warn()  { echo -e "\033[33mWARNING: $*\033[0m" >&2; }
error() { echo -e "\033[31mERROR: $*\033[0m" >&2; }

usage() {
    cat <<EOF
Usage: ${0##*/} [-h]
  -h, --help        show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)      usage; exit 0 ;;
        *)              error "unknown option: $1"; usage >&2; exit 1 ;;
    esac
done

###

# Pre-flight: must be in a kernel tree root.
for f in Makefile scripts/config arch/arm64/configs/defconfig; do
    if [[ ! -e "$f" ]]; then
        error "not in a kernel tree root (missing $f)"
        exit 1
    fi
done

CROSS=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)

###

# Always start from a fresh defconfig. This script is the single
# source of truth for our .config; any local edits will be lost.
if [[ -f .config ]]; then
    warn "existing .config will be overwritten by 'make defconfig'"
fi

info "Generating fresh arm64 defconfig"
make "${CROSS[@]}" defconfig

###

# Group 1: configs that must be =y (built-in)
# Many of these are =m in upstream defconfig; we flip them because we
# have no initramfs to load modules from before rootfs is mounted.

configs=(
    CONFIG_MODULES
    # --- SoC / pinctrl (defconfig: =y already) ---
    CONFIG_PINCTRL_X1E80100
    CONFIG_PINCTRL_QCOM_SPMI_PMIC
    CONFIG_PINCTRL_QCOM_SSBI_PMIC

    # --- SPMI / PMIC (defconfig: =y) ---
    CONFIG_SPMI
    CONFIG_SPMI_MSM_PMIC_ARB
    CONFIG_MFD_SPMI_PMIC
    CONFIG_REGMAP_SPMI
    CONFIG_REGULATOR_FIXED_VOLTAGE
    CONFIG_REGULATOR_QCOM_RPMH
    CONFIG_REGULATOR_QCOM_SPMI
    CONFIG_QCOM_PBS
    CONFIG_QCOM_SPMI_TEMP_ALARM
    CONFIG_NVMEM_SPMI_SDAM

    # --- Power / clock / reset infrastructure ---
    CONFIG_COMMON_CLK_QCOM
    CONFIG_QCOM_CLK_RPMH
    CONFIG_QCOM_RPMH
    CONFIG_QCOM_RPMHPD
    CONFIG_QCOM_COMMAND_DB
    CONFIG_QCOM_GDSC
    CONFIG_QCOM_AOSS_QMP
    CONFIG_RESET_QCOM_AOSS
    CONFIG_QCOM_SCM
    CONFIG_QCOM_TZMEM
    CONFIG_QCOM_LLCC
    CONFIG_QCOM_PDC
    CONFIG_QCOM_IPCC
    CONFIG_QCOM_SMEM
    CONFIG_QCOM_UBWC_CONFIG
    CONFIG_HWSPINLOCK_QCOM

    # --- Interconnect (defconfig: built-in) ---
    CONFIG_INTERCONNECT
    CONFIG_INTERCONNECT_QCOM
    CONFIG_INTERCONNECT_QCOM_RPMH
    CONFIG_INTERCONNECT_QCOM_BCM_VOTER
    CONFIG_INTERCONNECT_QCOM_X1E80100

    # --- GLINK / RPMSG / pmic-glink (defconfig: =m, we need =y) ---
    # pmic-glink owns USB-C orientation, role, altmode and battery on this SoC.
    # Without it built-in, the USB-C connector never enumerates.
    CONFIG_RPMSG
    CONFIG_RPMSG_QCOM_GLINK
    CONFIG_RPMSG_QCOM_GLINK_RPM
    CONFIG_RPMSG_QCOM_GLINK_SMEM
    CONFIG_QCOM_PMIC_GLINK
    CONFIG_BATTERY_QCOM_BATTMGR

    # --- Type-C / UCSI (defconfig: =m, we need =y) ---
    # The Parade PS8833 retimer is on i2c3 and routes the SuperSpeed
    # lanes from the SoC's QMP combo PHY to the USB-C connector.
    # NOTE: driver was renamed PS8830 -> PS883X around kernel 6.15
    # (covers both PS8830 and PS8833). Using the old name silently
    # no-ops in scripts/config --enable.
    CONFIG_TYPEC
    CONFIG_TYPEC_UCSI
    CONFIG_UCSI_PMIC_GLINK
    CONFIG_TYPEC_MUX_PS883X
    CONFIG_TYPEC_DP_ALTMODE

    # --- Shared GPIO proxy (defconfig: =m, we need =y) ---
    # GPIO 18 enables both NVMe 3.3V rails. gpiolib routes GPIOs with
    # multiple DT consumers through this proxy; as a module it never
    # loads and both NVMe regulators defer forever.
    CONFIG_GPIO_SHARED_PROXY

    # --- QSEECOM (Bjorn's patch 3/3 already merged; defconfig: =y) ---
    CONFIG_QCOM_QSEECOM
    CONFIG_QCOM_QSEECOM_UEFISECAPP

    # --- PCIe (defconfig: =y) ---
    CONFIG_PCI
    CONFIG_PCIEPORTBUS
    CONFIG_PCIEAER
    CONFIG_PCI_MSI
    CONFIG_PCIE_QCOM
    CONFIG_PCIE_QCOM_COMMON

    # --- PHYs (defconfig: all =m, we need =y) ---
    # PCIe and USB SuperSpeed both live on the QMP combo PHY family.
    # eUSB2 repeater is for the USB-C HS path; PTN3222 is the eUSB
    # redriver for the 5 USB-A ports going through &usb_mp.
    CONFIG_PHY_QCOM_QMP
    CONFIG_PHY_QCOM_QMP_PCIE
    CONFIG_PHY_QCOM_QMP_COMBO
    CONFIG_PHY_QCOM_QMP_USB
    CONFIG_PHY_QCOM_QMP_UFS
    CONFIG_PHY_QCOM_EUSB2_REPEATER
    CONFIG_PHY_QCOM_QUSB2
    CONFIG_PHY_QCOM_USB_SNPS_FEMTO_V2
    CONFIG_PHY_QCOM_M31_USB
    CONFIG_PHY_QCOM_M31_EUSB
    CONFIG_PHY_NXP_PTN3222

    # --- USB host stack (defconfig: =m, we need =y) ---
    # Since 2021, USB_DWC3 no longer selects USB_XHCI_PLATFORM — must be
    # explicit. USB_STORAGE for installing from USB sticks later.
    CONFIG_USB
    CONFIG_USB_XHCI_HCD
    CONFIG_USB_XHCI_PLATFORM
    CONFIG_USB_DWC3
    CONFIG_USB_DWC3_QCOM
    CONFIG_USB_STORAGE

    # --- I2C / SPI / Serial (defconfig: I2C/SPI =m, we need =y for retimer) ---
    CONFIG_I2C
    CONFIG_I2C_QCOM_GENI
    CONFIG_SPI
    CONFIG_SPI_QCOM_GENI
    CONFIG_QCOM_GENI_SE
    CONFIG_SERIAL_QCOM_GENI
    CONFIG_SERIAL_QCOM_GENI_CONSOLE

    # --- IOMMU ---
    CONFIG_ARM_SMMU
    CONFIG_ARM_SMMU_QCOM

    # --- Remoteproc / subsystem helpers ---
    CONFIG_QCOM_Q6V5_PAS
    CONFIG_QCOM_Q6V5_COMMON
    CONFIG_QCOM_PIL_INFO
    CONFIG_QCOM_MDT_LOADER
    CONFIG_QCOM_SYSMON
    CONFIG_QCOM_QMI_HELPERS
    CONFIG_QCOM_PDR_HELPERS
    CONFIG_QCOM_RPROC_COMMON
    CONFIG_QCOM_SMP2P
    CONFIG_QCOM_SMSM
    CONFIG_QCOM_APR

    # --- NVMEM ---
    CONFIG_NVMEM_QCOM_QFPROM

    # --- Ethernet (defconfig: r8169/stmmac =m, we need =y) ---
    # IdeaCentre wires Ethernet behind PCIe5 to a Realtek NIC; the r8169
    # driver covers both RTL8111 and RTL8125 families. STMMAC/EthQoS are
    # kept for completeness but the SoC's EMAC isn't used here.
    CONFIG_R8169
    CONFIG_REALTEK_PHY
    CONFIG_PHYLIB
    CONFIG_FIXED_PHY

    # --- NVMe (defconfig: =m, we need =y) ---
    CONFIG_NVME_CORE
    CONFIG_BLK_DEV_NVME

    # --- Device-mapper (defconfig: =m, we need =y) ---
    # Ubuntu userspace (multipathd, lvm2-monitor) expects /dev/mapper/control.
    # SNAPSHOT for LVM snapshots, CRYPT for LUKS on a later NVMe install.
    CONFIG_MD
    CONFIG_BLK_DEV_DM
    CONFIG_DM_MULTIPATH
    CONFIG_DM_SNAPSHOT
    CONFIG_DM_CRYPT

    # --- NFS root boot ---
    CONFIG_ROOT_NFS
    CONFIG_NFS_FS
    CONFIG_NFS_V3
    CONFIG_IP_PNP
    CONFIG_IP_PNP_DHCP
    CONFIG_IP_PNP_BOOTP

    # --- Debug output ---
    CONFIG_EFI_EARLYCON
    CONFIG_FB_EFI
    CONFIG_NETCONSOLE
    CONFIG_NETCONSOLE_DYNAMIC

    # --- Initramfs + squashfs/overlay root (casper) ---
    CONFIG_BLK_DEV_INITRD
    CONFIG_RD_GZIP
    CONFIG_RD_ZSTD
    CONFIG_BINFMT_SCRIPT
    CONFIG_TMPFS
    CONFIG_DEVTMPFS
    CONFIG_DEVTMPFS_MOUNT
    CONFIG_BLK_DEV_LOOP
    CONFIG_SQUASHFS
    CONFIG_SQUASHFS_ZLIB
    CONFIG_SQUASHFS_XZ
    CONFIG_OVERLAY_FS

    # --- Extra
    CONFIG_FTRACE
    CONFIG_EVENT_TRACING
    CONFIG_HIST_TRIGGERS
    CONFIG_DEBUG_KERNEL
    CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT

    CONFIG_DRM
    CONFIG_PROC_KCORE

)

# Debug info is a choice group: the default member (NONE) must be
# off before DWARF_TOOLCHAIN_DEFAULT can stick.
scripts/config --disable CONFIG_DEBUG_INFO_NONE

info "Enabling ${#configs[@]} configs as built-in (=y)"
for cfg in "${configs[@]}"; do
    scripts/config --enable "$cfg"
done

###

info "Running olddefconfig"
make "${CROSS[@]}" olddefconfig

###

# Sanity check: every symbol we asked for should appear in .config
# (either =y/=m/=value or "# ... is not set"). If it's missing entirely,
# the symbol either doesn't exist (renamed/typo) or its Kconfig deps
# are unmet. Both are bugs — silent skips have bitten us before.
info "Checking for unknown / dep-unmet symbols"
unknown=()
for cfg in "${configs[@]}"; do
    if ! grep -qE "^(${cfg}=|# ${cfg} is not set)" .config; then
        unknown+=("$cfg")
    fi
done

if [[ ${#unknown[@]} -gt 0 ]]; then
    warn "${#unknown[@]} symbols not present in .config (likely renamed or unmet deps):"
    for cfg in "${unknown[@]}"; do
        echo -e "  \033[31m?\033[0m $cfg"
    done
    warn "Check current Kconfig — symbol may have been renamed or removed."
fi

###

info "Verifying critical configs"

# Anything in this list must end up =y or we warn loudly.
critical=(
    CONFIG_MODULES
    # Boot path
    CONFIG_SPMI_MSM_PMIC_ARB
    CONFIG_MFD_SPMI_PMIC
    CONFIG_REGULATOR_QCOM_RPMH
    CONFIG_REGULATOR_QCOM_SPMI
    CONFIG_QCOM_CLK_RPMH
    CONFIG_QCOM_RPMHPD
    CONFIG_QCOM_COMMAND_DB
    CONFIG_QCOM_GDSC
    CONFIG_INTERCONNECT_QCOM_X1E80100
    CONFIG_PINCTRL_X1E80100
    CONFIG_PCI
    CONFIG_PCIE_QCOM
    CONFIG_QCOM_SMEM
    CONFIG_QCOM_PDC
    CONFIG_QCOM_IPCC
    CONFIG_QCOM_LLCC

    # NVMe (the original concern)
    CONFIG_NVME_CORE
    CONFIG_BLK_DEV_NVME
    CONFIG_GPIO_SHARED_PROXY

    # Device-mapper
    CONFIG_BLK_DEV_DM
    CONFIG_DM_MULTIPATH

    # USB host + USB-C (the other concern)
    CONFIG_USB_DWC3
    CONFIG_USB_DWC3_QCOM
    CONFIG_USB_XHCI_HCD
    CONFIG_USB_XHCI_PLATFORM
    CONFIG_PHY_QCOM_QMP_COMBO
    CONFIG_PHY_QCOM_QMP_USB
    CONFIG_PHY_QCOM_EUSB2_REPEATER
    CONFIG_PHY_NXP_PTN3222
    CONFIG_QCOM_PMIC_GLINK
    CONFIG_TYPEC_MUX_PS883X
    CONFIG_UCSI_PMIC_GLINK

    # Ethernet + NFS boot
    CONFIG_R8169
    CONFIG_ROOT_NFS
    CONFIG_IP_PNP_DHCP

    # Glink (needed for pmic-glink)
    CONFIG_RPMSG_QCOM_GLINK

    # Squashfs
    CONFIG_BLK_DEV_INITRD
    CONFIG_SQUASHFS
    CONFIG_OVERLAY_FS
    CONFIG_BLK_DEV_LOOP

    # --- Extra
    CONFIG_HIST_TRIGGERS
    CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT

    CONFIG_DRM
    CONFIG_PROC_KCORE
)

missing=0
for cfg in "${critical[@]}"; do
    val=$(grep -E "^(${cfg}=|# ${cfg} is not set)" .config 2>/dev/null || echo "NOT FOUND")
    if echo "$val" | grep -q "=y"; then
        echo -e "  \033[32m✓\033[0m $cfg"
    elif echo "$val" | grep -q "=m"; then
        echo -e "  \033[33m~\033[0m $cfg  (=m, needs =y for NFS root)"
        missing=$((missing + 1))
    else
        echo -e "  \033[31m✗\033[0m $cfg  ($val)"
        missing=$((missing + 1))
    fi
done

if [[ $missing -gt 0 ]]; then
    warn "$missing critical configs not =y. Check Kconfig dependencies."
else
    echo -e "\n\033[32mAll critical configs verified as built-in.\033[0m"
fi

###

DTS=arch/arm64/boot/dts/qcom/hamoa-lenovo-ideacentre-mini-01q8x10.dts
DTSI=arch/arm64/boot/dts/qcom/hamoa.dtsi
PCIE3_MARKER="/* fix-kernel-config.sh: pcie3 disabled */"

# DTS override: disable pcie3 (1bd0000).
#
# Probing pcie3 warm-resets the SoC (verified by bisecting with fdtput:
# only pcie3 enabled -> reboot loop; only pcie6a enabled -> boots, NVMe up).
# Appending &label overrides at the end of the board DTS wins over the
# earlier status = "okay". Idempotent via marker comment.

if [[ ! -f "$DTS" ]]; then
    error "DTS not found at $DTS"
    error "(make sure Bjorn's v2 patch series is applied)"
    exit 1
fi

if grep -qF "$PCIE3_MARKER" "$DTS"; then
    info "pcie3 already disabled in $DTS"
else
    # Labels must exist, or dtc fails later with an unhelpful error.
    for label in pcie3 pcie3_phy; do
        if ! grep -qE "^[[:space:]]*${label}:" "$DTSI"; then
            error "label '$label' not found in $DTSI — SoC dtsi changed?"
            exit 1
        fi
    done

    info "Disabling pcie3 in $DTS"
    cat >> "$DTS" <<EOF

$PCIE3_MARKER
&pcie3 {
	status = "disabled";
};

&pcie3_phy {
	status = "disabled";
};
EOF
fi

###

info "Done. Build with:"
echo "    make ${CROSS[*]} -j\$(nproc) Image dtbs"