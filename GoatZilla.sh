
#!/usr/bin/env bash
# ============================================
#          ZILLA GOAT SCRIPT
#      Linux Hosting Optimization Tool
# ============================================

set -Eeuo pipefail

VERSION="1.0"
SWAP_FILE="/swapfile"
SYSCTL_FILE="/etc/sysctl.d/99-zilla-goat.conf"
ZRAM_CONFIG="/etc/default/zramswap"

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

pause() {
    echo
    read -rp "Press Enter to return to the menu..."
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Run this script as root: sudo bash zilla-goat.sh"
        exit 1
    fi
}

check_os() {
    if [[ ! -r /etc/os-release ]]; then
        error "Cannot identify your Linux distribution."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
        error "This script supports Ubuntu and Debian only."
        exit 1
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        error "APT package manager not found."
        exit 1
    fi
}

install_zram() {
    info "Installing ZRAM tools..."

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools

    # Configure ZRAM to use up to 50% of physical RAM.
    # ZRAM is compressed memory, not disk-backed swap.
    if [[ -f "$ZRAM_CONFIG" ]]; then
        cp -a "$ZRAM_CONFIG" "${ZRAM_CONFIG}.zilla-backup"
    fi

    cat > "$ZRAM_CONFIG" <<'EOF'
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF

    systemctl enable zramswap

    if ! systemctl restart zramswap; then
        warn "ZRAM service failed. Check: systemctl status zramswap"
        return 1
    fi

    success "ZRAM configured and service started."
}

configure_swappiness() {
    local value="$1"

    if [[ ! "$value" =~ ^[0-9]{1,3}$ ]] ||
       (( value < 0 || value > 200 )); then
        error "Swappiness must be an integer from 0 to 200."
        return 1
    fi

    mkdir -p /etc/sysctl.d

    cat > "$SYSCTL_FILE" <<EOF
# Zilla Goat Script - persistent swap configuration
vm.swappiness=$value
EOF

    sysctl -w "vm.swappiness=$value" >/dev/null
    success "Swappiness set to $value and saved persistently."
}

create_swap() {
    local size_gb="$1"
    local size_mb

    if [[ ! "$size_gb" =~ ^[0-9]+$ ]] ||
       (( size_gb < 1 || size_gb > 1024 )); then
        error "Enter a whole number between 1 and 1024 GB."
        return 1
    fi

    size_mb=$((size_gb * 1024))

    if swapon --show=NAME --noheadings | grep -Fxq "$SWAP_FILE"; then
        warn "$SWAP_FILE is already active. Leaving it unchanged."
        return 0
    fi

    if [[ -e "$SWAP_FILE" ]]; then
        warn "$SWAP_FILE already exists. Refusing to overwrite it."
        warn "Inspect it manually with: ls -lh $SWAP_FILE"
        return 1
    fi

    local available_kb
    available_kb=$(df -Pk / | awk 'NR==2 {print $4}')

    if (( available_kb < size_mb * 1024 + 1048576 )); then
        error "Not enough free space on /. Leave at least 1 GB free."
        return 1
    fi

    info "Creating a ${size_gb} GB swap file..."

    if ! fallocate -l "${size_gb}G" "$SWAP_FILE"; then
        rm -f "$SWAP_FILE"
        error "Could not allocate swap file."
        return 1
    fi

    chmod 600 "$SWAP_FILE"

    if ! mkswap "$SWAP_FILE"; then
        rm -f "$SWAP_FILE"
        error "Could not format swap file."
        return 1
    fi

    if ! swapon "$SWAP_FILE"; then
        rm -f "$SWAP_FILE"
        error "Could not enable swap file."
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab; then
        echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    fi

    success "${size_gb} GB swap file created and enabled."
}

auto_optimize() {
    local ram_gb

    echo
    echo "Enter the server's RAM amount in GB."
    echo "The disk swap file will be the same size."
    echo "Example: 8 means 8 GB RAM and an 8 GB swap file."
    echo

    read -rp "RAM amount (GB): " ram_gb

    if [[ ! "$ram_gb" =~ ^[0-9]+$ ]] ||
       (( ram_gb < 1 || ram_gb > 1024 )); then
        error "Enter a whole number between 1 and 1024."
        return 1
    fi

    echo
    warn "This will install ZRAM and create a ${ram_gb} GB disk swap file."
    warn "It will also set vm.swappiness=150."
    read -rp "Continue? [y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || {
        info "Cancelled."
        return 0
    }

    install_zram || return 1
    create_swap "$ram_gb" || return 1
    configure_swappiness 150 || return 1

    success "Zilla Goat optimization completed!"
}

custom_optimize() {
    local ram_gb swappiness

    echo
    read -rp "RAM amount in GB (swap file will match): " ram_gb
    read -rp "Custom swappiness (0-200): " swappiness

    if [[ ! "$ram_gb" =~ ^[0-9]+$ ]] ||
       (( ram_gb < 1 || ram_gb > 1024 )); then
        error "Invalid RAM amount."
        return 1
    fi

    if [[ ! "$swappiness" =~ ^[0-9]+$ ]] ||
       (( swappiness > 200 )); then
        error "Swappiness must be from 0 to 200."
        return 1
    fi

    echo
    warn "This will install ZRAM, create a ${ram_gb} GB swap file,"
    warn "and configure swappiness to ${swappiness}."
    read -rp "Continue? [y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || {
        info "Cancelled."
        return 0
    }

    install_zram || return 1
    create_swap "$ram_gb" || return 1
    configure_swappiness "$swappiness" || return 1

    success "Custom optimization completed!"
}

show_status() {
    echo
    echo "========== ZILLA GOAT STATUS =========="
    echo
    echo "--- Memory ---"
    free -h
    echo
    echo "--- Swap devices ---"
    swapon --show
    echo
    echo "--- Current swappiness ---"
    sysctl vm.swappiness
    echo
    echo "--- ZRAM service ---"
    systemctl --no-pager --full status zramswap 2>/dev/null \
        | head -n 12 || true
    echo
    echo "--- ZRAM devices ---"

    if command -v zramctl >/dev/null 2>&1; then
        zramctl || true
    else
        echo "zramctl is not installed."
    fi
    echo
    echo "======================================="
}

main_menu() {
    while true; do
        clear || true

        echo -e "${CYAN}"
        cat <<'EOF'
 _____ ___ _     _        ____             _
|__  // __| |__ (_)__ _  / ___| ___   __ _| |_
  / /| (__| '_ \| / _` | \___ \/ _ \ / _` | __|
 / /__\___|_.__// \__,_|  ___) | (_) | (_| | |_
/_____|      |__/         |____/ \___/ \__,_|\__|

             ZILLA GOAT SCRIPT
             Hosting Optimizer
EOF
        echo -e "${RESET}"
        echo "Version: $VERSION"
        echo
        echo "1. Auto Optimize (Swappiness 150)"
        echo "2. Custom Swappiness"
        echo "3. Check System Status"
        echo "4. Exit"
        echo

        read -rp "Select an option [1-4]: " choice

        case "$choice" in
            1) auto_optimize || warn "Operation incomplete."; pause ;;
            2) custom_optimize || warn "Operation incomplete."; pause ;;
            3) show_status; pause ;;
            4) echo "Thanks for using Zilla Goat!"; exit 0 ;;
            *) error "Invalid option."; sleep 1 ;;
        esac
    done
}

check_root
check_os
main_menu
