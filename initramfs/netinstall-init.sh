#!/bin/sh
PATH=/sbin:/bin:/usr/bin:/usr/sbin
NLB_VERSION="v0.9"

# netinstall-init.sh — DEPRECATED
# Desde v0.10 el init unificado (initramfs/init + lib/ + libexec/) cubre el
# perfil netinstall detectándolo por cmdline (netinstall=1). Este archivo se
# conserva como respaldo y se eliminará en v1.0.
# build.sh y hooks/pre-pack/60-netinstall-config ya no lo inyectan (P10).

[ "$debug" = "1" ] && set -x

# --------------------------------------------------
# Config
# --------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

HOME=/root
TERM=linux

# --------------------------------------------------
# Shell launcher (choose bash if available)
# --------------------------------------------------
run_shell() {
    # Usamos setsid para crear una nueva sesión y forzar terminal de control
    if [ -x /bin/bash ]; then
        exec setsid /bin/bash --login "$@" </dev/tty1 >/dev/tty1 2>/dev/tty1
    else
        if /bin/sh -l -c 'true' 2>/dev/null; then
            exec setsid /bin/sh -l "$@" </dev/tty1 >/dev/tty1 2>/dev/tty1
        else
            exec setsid - /bin/sh "$@" </dev/tty1 >/dev/tty1 2>/dev/tty1
        fi
    fi
}

# --------------------------------------------------
# Core functions
# --------------------------------------------------
emergency_shell() {
    echo -e "${RED}[EMERGENCY]${NC} Dropping to shell"
    run_shell
}

show_ip() {
    echo ""
    echo -e "${BLUE}═════════════════════════════════════════${NC}"
    echo -e "${GREEN}   NET INSTALL - NEONATOX LIVE BOOT${NC}"
    echo -e "${BLUE}═════════════════════════════════════════${NC}"
    echo ""

    echo -e "${YELLOW}Network interfaces:${NC}"
    for iface in $(ip link | grep -o '^[0-9]*: [^:]*' | cut -d' ' -f2 | grep -v lo); do
        IP=$(ip -4 addr show "$iface" 2>/dev/null | grep 'inet ' | awk '{print $2}')
        if [ -n "$IP" ]; then
            echo -e "  ${GREEN}$iface${NC}: $IP"
        else
            echo -e "  ${YELLOW}$iface${NC}: no DHCP"
        fi
    done

    echo ""
    echo -e "  ${YELLOW}SSH:${NC} ssh root@${IP%/*}"
    echo -e "  ${YELLOW}Pass:${NC} neonatox"
}

show_guide() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   NEONATOX NET INSTALL - QUICK GUIDE${NC}"
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
    echo ""
    echo " 1. Prepare target disk:"
    echo "      fdisk /dev/sda            (partition)"
    echo "      mkfs.ext4 /dev/sda1       (format)"
    echo "      mount /dev/sda1 /mnt      (mount)"
    echo " 2. Run base installer:"
    echo "      neonatox-bootstrap -L /mnt core"
    echo " 3. (Optional) Install desktop:"
    echo "      neonatox-bootstrap -L /mnt -p mypassword xfce"
    echo ""
    echo -e " ${YELLOW}Docs:${NC} https://github.com/cargabsj175/neonatox-bootstrap"
    echo ""
    echo -e "${YELLOW}[INFO]${NC} WiFi: only ath5k/ath9k without firmware included"
    echo -e "${YELLOW}[INFO]${NC} For other chipsets, load modules manually after install"
    echo ""
}

echo -e "${YELLOW}========${NC} ${GREEN}Neonatox Live Boot - Net Install - ${NLB_VERSION} Carlos Sanchez - 2007-2026 ${YELLOW}========${NC}"
echo -e "${YELLOW}==========${NC} https://github.com/cargabsj175/neonatox-live-boot ${YELLOW}=========${NC}"

# --------------------------------------------------
# 1. Console and virtual filesystem
# --------------------------------------------------
mount -t proc proc /proc
mount -t sysfs sysfs /sys
sleep 1
mdev -s
mount -t tmpfs tmpfs /run

CMDLINE="$(cat /proc/cmdline)"

mkdir -p /dev/pts
mount -t devpts devpts -o gid=5,mode=0620 /dev/pts 2>/dev/null || true

ln -sf /proc/self/fd/0 /dev/stdin
ln -sf /proc/self/fd/1 /dev/stdout
ln -sf /proc/self/fd/2 /dev/stderr

echo -e "${GREEN}[OK]${NC} basic mounts ready"

# --------------------------------------------------
# 2. Create loop devices
# --------------------------------------------------
for i in $(seq 0 15); do
    [ -b /dev/loop$i ] || mknod /dev/loop$i b 7 $i
done

# --------------------------------------------------
# 3. Load modules
# --------------------------------------------------
FILESYSTEMS="ext2 ext3 ext4 vfat fat exfat ntfs3 btrfs xfs"
MEDIA="loop scsi_mod sd_mod sr_mod cdrom \
       usbcore usb_common usb-storage uas \
       xhci_hcd ehci_hcd uhci_hcd \
       xhci_pci ehci_pci ohci_pci \
       ahci libata zram"
LEGACY="ata_piix pata_generic"
NVME="nvme nvme_core"
HID="hid-generic usbhid i8042 atkbd libps2"
NET="virtio_net e1000 e1000e r8169 tg3"
WIFI="ath5k ath9k"

for m in $FILESYSTEMS $MEDIA $LEGACY $NVME $HID $NET $WIFI; do
    modprobe $m 2>/dev/null
done

sleep 1
mdev -s

echo -e "${GREEN}[OK]${NC} modules loaded"

# --------------------------------------------------
# 4. Initramfs debug
# --------------------------------------------------
[ "$initrd_debug" = "1" ] && emergency_shell

# --------------------------------------------------
# 5. Network: DHCP
# --------------------------------------------------
echo -e "${YELLOW}[INFO]${NC} Bringing up network (DHCP)..."

for iface in $(ip link | grep -o '^[0-9]*: [^:]*' | cut -d' ' -f2 | grep -v lo); do
    # Debug: ip link show "$iface"
    ip link set "$iface" up
    # Debug: echo -e "  ${YELLOW}[DHCP]${NC} $iface (waiting)..."
    sleep 2
    # Debug: ip link show "$iface" | head -2
    udhcpc -i "$iface" -s /usr/share/udhcpc/default.script -t 5 -T 2 2>/dev/null || true
    if ip -4 addr show "$iface" | grep -q 'inet '; then
        echo -e "  ${GREEN}[OK]${NC} $iface has IP"
    else
        echo -e "  ${RED}[FAIL]${NC} $iface no DHCP lease"
    fi
done

# --------------------------------------------------
# 6. WiFi config (if no DHCP and wifi-config exists)
# --------------------------------------------------
HAS_DHCP="$(ip -4 addr | grep 'inet ' | grep -v 127.0.0.1 | head -1)"
if [ -z "$HAS_DHCP" ] && [ -x /wifi-config.sh ]; then
    echo -e "${YELLOW}[INFO]${NC} No DHCP via cable, starting WiFi config..."
    /wifi-config.sh
fi

# --------------------------------------------------
# 7. Time sync (if we have IP)
# --------------------------------------------------
HAS_IP="$(ip -4 addr | grep 'inet ' | grep -v 127.0.0.1 | head -1)"
if [ -n "$HAS_IP" ]; then
    echo -e "${YELLOW}[INFO]${NC} Setting time via NTP..."
    ntpd -n -q -p pool.ntp.org 2>/dev/null && echo -e "${GREEN}[OK]${NC} time synced" || \
        echo -e "${YELLOW}[WARN]${NC} NTP sync failed (non-fatal)"
fi

# --------------------------------------------------
# 8. Root password for SSH
# --------------------------------------------------
mkdir -p /etc
echo "root:x:0:0:root:/root:/bin/sh" > /etc/passwd
ROOT_HASH="$(printf '%s' 'neonatox' | cryptpw -m sha512)"
echo "root:$ROOT_HASH:1:0:99999:7:::" > /etc/shadow
echo -e "${GREEN}[OK]${NC} root password: neonatox"

# --------------------------------------------------
# 9. Start dropbear
# --------------------------------------------------
echo -e "${YELLOW}[INFO]${NC} Generating dropbear host keys..."
mkdir -p /etc/dropbear

if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
    dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key > /dev/null 2>&1
fi

if [ ! -f /etc/dropbear/dropbear_rsa_host_key ]; then
    dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key > /dev/null 2>&1
fi

dropbear 2>/dev/null && echo -e "${GREEN}[OK]${NC} dropbear running" || echo -e "${RED}[ERROR]${NC} dropbear failed to start"

# --------------------------------------------------
# 10. Show connection info
# --------------------------------------------------
show_ip

# --------------------------------------------------
# 11. Show installation guide
# --------------------------------------------------
show_guide

# --------------------------------------------------
# 12. Shell (now uses the same logic as emergency)
# --------------------------------------------------
echo -e "${YELLOW}[INFO]${NC} Netinstall environment ready"
echo ""

# Reemplazar el antiguo 'exec sh' por el lanzador condicional
run_shell
