#!/bin/sh
# init-embedded.sh — embedded profile: red, SSH, shell y tools de fs (base netinstall)
PROFILE_NAME="embedded"
PROFILE_REQUIRES="bash dropbear dropbearkey wpa_supplicant wpa_cli wpa_passphrase zstd btrfs mkfs.btrfs mkfs.ext4 fsck.ext4"

show_ip() {
    echo ""
    echo -e "${BLUE}═════════════════════════════════════════${NC}"
    echo -e "${GREEN}   NEONATOX EMBEDDED - SYSROOT${NC}"
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
    echo -e "${GREEN}   NEONATOX EMBEDDED - QUICK GUIDE${NC}"
    echo -e "${BLUE}════════════════════════════════════════════${NC}"
    echo ""
    echo " Este esqueleto es una BASE arrancable sin kernel:"
    echo "   - red (DHCP), SSH (dropbear), shell y tools de fs"
    echo "   - añade TU kernel y módulos sobre esta sysroot"
    echo "   - sustituye /init por tu propio PID 1 / servicios"
    echo ""
    echo -e " ${YELLOW}Docs:${NC} https://github.com/cargabsj175/neonatox-live-boot"
    echo ""
}

dhcp_all() {
    echo -e "${YELLOW}[INFO]${NC} Bringing up network (DHCP)..."
    for iface in $(ip -o link | awk -F': ' '{print $2}' | grep -v lo); do
        # Skip WiFi (handled by wifi_config). Also skip interfaces
        # whose name starts with wl (predictable naming) or wlan
        case "$iface" in wl*|wlan*|Wi-Fi*) continue ;; esac
        ip link set "$iface" up 2>/dev/null || true
        # udhcpc -n: exit if no lease, -q: quit after lease
        udhcpc -i "$iface" -s /usr/share/udhcpc/default.script -n -q -t 3 -T 2 2>/dev/null || true
        if ip -4 addr show "$iface" | grep -q 'inet '; then
            echo -e "  ${GREEN}[OK]${NC} $iface has IP"
        else
            echo -e "  ${RED}[FAIL]${NC} $iface no DHCP lease"
        fi
    done
}

wifi_config() {
    HAS_DHCP="$(ip -4 addr | grep 'inet ' | grep -v 127.0.0.1 | head -1)"
    if [ -z "$HAS_DHCP" ] && [ -x /wifi-config.sh ]; then
        echo -e "${YELLOW}[INFO]${NC} No DHCP via cable, starting WiFi config..."
        /wifi-config.sh
    fi
}

ntp_sync() {
    HAS_IP="$(ip -4 addr | grep 'inet ' | grep -v 127.0.0.1 | head -1)"
    if [ -n "$HAS_IP" ]; then
        echo -e "${YELLOW}[INFO]${NC} Setting time via NTP..."
        ntpd -n -q -p pool.ntp.org 2>/dev/null && echo -e "${GREEN}[OK]${NC} time synced" || \
            echo -e "${YELLOW}[WARN]${NC} NTP sync failed (non-fatal)"
    fi
}

setup_ssh() {
    mkdir -p /etc
    echo "root:x:0:0:root:/root:/bin/sh" > /etc/passwd
    ROOT_HASH="$(printf '%s' 'neonatox' | cryptpw -m sha512)"
    echo "root:$ROOT_HASH:1:0:99999:7:::" > /etc/shadow
    echo -e "${GREEN}[OK]${NC} root password: neonatox"
    mkdir -p /etc/dropbear
    # Host keys horneadas por imagen (hook pre-pack/55-ssh-hostkeys).
    # Solo se regeneran como fallback si la imagen no las trae.
    if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
        echo -e "${YELLOW}[WARN]${NC} no baked host key, generating..."
        dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key > /dev/null 2>&1
    fi
    if [ ! -f /etc/dropbear/dropbear_rsa_host_key ]; then
        dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key > /dev/null 2>&1
    fi
    dropbear 2>/dev/null && echo -e "${GREEN}[OK]${NC} dropbear running" || \
        echo -e "${RED}[ERROR]${NC} dropbear failed to start"
}