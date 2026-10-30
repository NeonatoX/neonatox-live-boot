# init-common.sh — shared functions for all profiles
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
HOME=/root; TERM=linux
NLB_VERSION="v0.10"

trap 'echo -e "\n${YELLOW}[SIGINT]${NC} Emergency shell"; run_shell' INT

run_shell() {
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

emergency_shell() {
    echo -e "${RED}[EMERGENCY]${NC} $*"
    run_shell
}

debug_shell() {
    local level="${initrd_debug:-0}"
    [ "$level" -ge "${1:-1}" ] || return 0
    echo -e "${YELLOW}[DEBUG]${NC} $2"
    run_shell
}

phase_kill_children() {
    kill $(jobs -p) 2>/dev/null
    wait 2>/dev/null
}

show_banner() {
    echo -e "${YELLOW}========${NC} ${GREEN}Neonatox Live Boot - ${NLB_VERSION} Carlos Sanchez - 2007-2026 ${YELLOW}========${NC}"
    echo -e "${YELLOW}==========${NC} https://github.com/cargabsj175/neonatox-live-boot ${YELLOW}=========${NC}"
}
