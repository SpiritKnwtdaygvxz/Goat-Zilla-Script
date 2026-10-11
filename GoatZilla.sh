
#!/usr/bin/env bash
# =========================================================
#                  ZILLA GOAT SCRIPT
#            Linux Hosting Optimization Tool
#                         v2.0
# =========================================================

set -Eeuo pipefail

VERSION="2.0"
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
        error "Run as root: sudo bash zilla-goat.sh"
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
        error "Only Ubuntu and Debian are supported."
        exit 1
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        error "APT package manager not found."
        exit 1
    fi

    for cmd in swapon swapoff mkswap sysctl df grep awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "Required command missing: $cmd"
            exit 1
        fi
    done
}

# ---------------------------------------------------------
# ZRAM
# Preserve provider-configured or already active ZRAM.
# Never change compression on an existing ZRAM device.
# ---------------------------------------------------------

install_zram() {
    info "Checking ZRAM..."

    # Case 1: ZRAM is already active as swap.
    if swapon --noheadings --raw --show=NAME |
        grep -Eq '^/dev/zram[0-9]+$'; then
        success "ZRAM is already active. Keeping existing configuration."

        if command -v zramctl >/dev/null 2>&1; then
            zramctl || true
        fi

        return 0
    fi

    # Case 2: A ZRAM device has already been initialized,
    # but it is not active as swap. Do not reset it blindly.
    local sysfile size
    for sysfile in /sys/block/zram*/disksize; do
        [[ -e "$sysfile" ]] || continue
        size=$(cat "$sysfile" 2>/dev/null || echo 0)

        if [[ "$size" =~ ^[0-9]+$ ]] && (( size > 0 )); then
            warn "ZRAM device is initialized but not active as swap."
            warn "Not resetting or reconfiguring it automatically."
            warn "Inspect with: zramctl && swapon --show"
            return 1
        fi
    done

    info "No active or initialized ZRAM device detected."
    info "Installing ZRAM tools..."

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools

    # Preserve the existing package configuration.
    if [[ -f "$ZRAM_CONFIG" ]]; then
        cp -n "$ZRAM_CONFIG" "${ZRAM_CONFIG}.zilla-backup"
    fi

    # Do not force an algorithm or overwrite provider settings.
    if systemctl restart zramswap; then
        success "ZRAM service started."

        if command -v zramctl >/dev/null 2>&1; then
            zramctl || true
        fi
    else
        error "ZRAM service failed."
        journalctl -u zramswap -n 30 --no-pager || true
        return 1
    fi
}

# ---------------------------------------------------------
# SWAPPINESS
# ---------------------------------------------------------

configure_swappiness() {
    local value="$1"

    if [[ ! "$value" =~ ^[0-9]{1,3}$ ]] ||
       (( 10#$value > 200 )); then
        error "Swappiness must be an integer from 0 to 200."
        return 1
    fi

    mkdir -p /etc/sysctl.d

    cat > "$SYSCTL_FILE" <<EOF
# Zilla Goat Script - persistent configuration
vm.swappiness=$((10#$value))
EOF

    if ! sysctl -w "vm.swappiness=$((10#$value))"; then
        error "Failed to apply swappiness."
        return 1
    fi

    success "Swappiness set to $((10#$value)) and saved persistently."
}

# ---------------------------------------------------------
# DISK SWAP
# ---------------------------------------------------------

create_swap() {
    local size_gb="$1"
    local size_mb available_kb

    if [[ ! "$size_gb" =~ ^[0-9]{1,4}$ ]] ||
       (( 10#$size_gb < 1 || 10#$size_gb > 1024 )); then
        error "Swap size must be between 1 and 1024 GB."
        return 1
    fi

    size_gb=$((10#$size_gb))
    size_mb=$((size_gb * 1024))

    # If the existing file is already active, leave it alone.
    if swapon --noheadings --raw --show=NAME |
        grep -Fxq "$SWAP_FILE"; then
        warn "$SWAP_FILE is already active. Leaving it unchanged."
        swapon --show
        return 0
    fi

    # Never overwrite a pre-existing file.
    if [[ -e "$SWAP_FILE" ]]; then
        warn "$SWAP_FILE already exists but is not active."
        warn "Inspect it manually before deciding what to do."
        return 1
    fi

    available_kb=$(df -Pk "$(dirname "$SWAP_FILE")" |
        awk 'NR==2 {print $4}')

    if [[ ! "$available_kb" =~ ^[0-9]+$ ]] ||
       (( available_kb < size_mb * 1024 + 1048576 )); then
        error "Insufficient free disk space. Leave at least 1 GB free."
        return 1
    fi

    info "Creating ${size_gb} GB disk swap..."

    # Create file. Fall back to dd if fallocate is unsupported.
    if ! fallocate -l "${size_gb}G" "$SWAP_FILE"; then
        warn "fallocate failed; trying dd. This may take longer."

        rm -f "$SWAP_FILE"

        if ! dd if=/dev/zero of="$SWAP_FILE" \
            bs=1M count="$size_mb" status=progress conv=fsync; then
            rm -f "$SWAP_FILE"
            error "Could not create swap file."
            return 1
        fi
    fi

    chmod 600 "$SWAP_FILE"

    if ! mkswap "$SWAP_FILE"; then
        rm -f "$SWAP_FILE"
        error "Could not format swap file."
        return 1
    fi

    if ! swapon "$SWAP_FILE"; then
        rm -f "$SWAP_FILE"
        error "Could not activate swap file."
        return 1
    fi

    # Avoid duplicate fstab entries.
    if ! awk '$1 == "/swapfile" {found=1} END {exit !found}' \
        /etc/fstab; then
        if ! printf '%s\n' "$SWAP_FILE none swap sw 0 0" >> /etc/fstab; then
            warn "Could not update /etc/fstab; swap is active for now."
            return 1
        fi
    fi

    success "${size_gb} GB disk swap created and enabled."
}

# ---------------------------------------------------------
# INPUT VALIDATION
# ---------------------------------------------------------

read_swap_size() {
    local prompt="$1"
    local value

    read -rp "$prompt" value

    if [[ ! "$value" =~ ^[0-9]{1,4}$ ]] ||
       (( 10#$value < 1 || 10#$value > 1024 )); then
        error "Enter a whole number from 1 to 1024."
        return 1
    fi

    REPLY=$((10#$value))
}

read_swappiness() {
    local value

    read -rp "Swappiness (0-200): " value

    if [[ ! "$value" =~ ^[0-9]{1,3}$ ]] ||
       (( 10#$value > 200 )); then
        error "Enter a whole number from 0 to 200."
        return 1
    fi

    REPLY=$((10#$value))
}

# ---------------------------------------------------------
# OPTIMIZATION MODES
# ---------------------------------------------------------

auto_optimize() {
    local swap_gb

    echo
    echo "Default swappiness: 150"
    echo "Choose disk swap size in GB."
    echo "Enter your desired swap size; it need not equal RAM."
    echo

    read_swap_size "Disk swap size (GB): " || return 1
    swap_gb="$REPLY"

    echo
    warn "ZRAM will be preserved if already active."
    warn "Disk swap target: ${swap_gb} GB"
    warn "Swappiness: 150"
    read -rp "Continue? [y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || {
        info "Cancelled."
        return 0
    }

    install_zram || return 1
    create_swap "$swap_gb" || return 1
    configure_swappiness 150 || return 1

    success "Zilla Goat optimization completed."
}

custom_optimize() {
    local swap_gb swap_value

    echo
    read_swap_size "Disk swap size (GB): " || return 1
    swap_gb="$REPLY"

    read_swappiness || return 1
    swap_value="$REPLY"

    echo
    warn "ZRAM will be preserved if already active."
    warn "Disk swap target: ${swap_gb} GB"
    warn "Swappiness: ${swap_value}"
    read -rp "Continue? [y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || {
        info "Cancelled."
        return 0
    }

    install_zram || return 1
    create_swap "$swap_gb" || return 1
    configure_swappiness "$swap_value" || return 1

    success "Custom optimization completed."
}

zram_only() {
    echo
    warn "This option only checks or installs ZRAM."
    warn "It will not create a disk swap file."
    read -rp "Continue? [y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    install_zram
}

# ---------------------------------------------------------
# STATUS
# ---------------------------------------------------------

show_status() {
    echo
    echo "========== ZILLA GOAT STATUS =========="
    echo

    echo "--- Operating system ---"
    if [[ -r /etc/os-release ]]; then
        grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release || true
    fi

    echo
    echo "--- Memory ---"
    free -h

    echo
    echo "--- Swap devices ---"
    swapon --show

    echo
    echo "--- Swappiness ---"
    sysctl vm.swappiness

    echo
    echo "--- ZRAM devices ---"
    if command -v zramctl >/dev/null 2>&1; then
        zramctl || true
    else
        echo "zramctl is not installed."
    fi

    echo
    echo "--- ZRAM service ---"
    systemctl --no-pager --full status zramswap 2>/dev/null |
        head -n 12 || true

    echo
    echo "--- Persistent swappiness configuration ---"
    if [[ -f "$SYSCTL_FILE" ]]; then
        cat "$SYSCTL_FILE"
    else
        echo "Zilla Goat configuration file not found."
    fi

    echo
    echo "======================================="
}

# ---------------------------------------------------------
# MAIN MENU
# ---------------------------------------------------------

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
        echo "3. ZRAM Setup / Check Only"
        echo "4. Check System Status"
        echo "5. Exit"
        echo

        read -rp "Select an option [1-5]: " choice

        case "$choice" in
            1)
                auto_optimize || warn "Operation incomplete; check the messages above."
                pause
                ;;
            2)
                custom_optimize || warn "Operation incomplete; check the messages above."
                pause
                ;;
            3)
                zram_only || warn "ZRAM operation incomplete; check the messages above."
                pause
                ;;
            4)
                show_status
                pause
                ;;
            5)
                echo "Thanks for using Zilla Goat!"
                exit 0
                ;;
            *)
                error "Invalid option."
                sleep 1
                ;;
        esac
    done
}

check_root
check_os
main_menu
