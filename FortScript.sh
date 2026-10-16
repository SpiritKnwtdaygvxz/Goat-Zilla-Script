
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Zilla Goat Script v3.1
# Ubuntu / Debian VPS Swap and ZRAM Manager
# ============================================================

VERSION="3.1"
SWAPFILE="/swapfile"
SYSCTL_FILE="/etc/sysctl.d/99-zilla-goat.conf"
ZRAM_CONFIG="/etc/default/zramswap"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

pause() {
    echo
    read -r -p "Press Enter to continue..." _
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "Run this script as root: sudo bash $0"
        exit 1
    fi
}

check_os() {
    if [[ ! -r /etc/os-release ]]; then
        error "Cannot identify operating system."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        ubuntu|debian) ;;
        *)
            error "Only Ubuntu and Debian are supported."
            exit 1
            ;;
    esac
}

get_ram_kb() {
    awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo
}

get_ram_gb_ceil() {
    local ram_kb
    ram_kb=$(get_ram_kb)
    echo $(( (ram_kb + 1048575) / 1048576 ))
}

install_zram_tools() {
    if ! command -v zramswap >/dev/null 2>&1; then
        info "Installing zram-tools..."
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools
    fi

    if [[ ! -f "$ZRAM_CONFIG" ]]; then
        touch "$ZRAM_CONFIG"
    fi
}

set_config_value() {
    local key="$1"
    local value="$2"
    local file="$3"

    if grep -Eq "^[[:space:]]*${key}=" "$file"; then
        sed -i -E \
            "s|^[[:space:]]*${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

configure_swappiness() {
    local value="$1"

    if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 0 || value > 200 )); then
        error "Swappiness must be between 0 and 200."
        return 1
    fi

    mkdir -p /etc/sysctl.d
    printf 'vm.swappiness = %s\n' "$value" > "$SYSCTL_FILE"

    if ! sysctl -w "vm.swappiness=$value" >/dev/null; then
        error "Could not apply swappiness."
        return 1
    fi

    success "Swappiness set to $value and saved permanently."
}

configure_disk_swap() {
    local size_gb="$1"
    local available_kb required_kb

    if ! [[ "$size_gb" =~ ^[0-9]+$ ]] || (( size_gb < 1 )); then
        error "Swap size must be at least 1 GB."
        return 1
    fi

    if (( size_gb > 4096 )); then
        error "Swap size cannot exceed 4096 GB."
        return 1
    fi

    # Refuse to destroy an existing swapfile if it cannot be
    # safely disabled.
    if swapon --noheadings --raw --output=NAME 2>/dev/null |
        grep -Fxq "$SWAPFILE"; then
        info "Disabling existing disk swap..."
        if ! swapoff "$SWAPFILE"; then
            error "Could not disable $SWAPFILE. No changes made."
            return 1
        fi
    fi

    # Account for space currently occupied by the old swapfile.
    available_kb=$(df -Pk / | awk 'NR==2 {print $4}')
    if [[ -e "$SWAPFILE" ]]; then
        local old_kb
        old_kb=$(du -sk "$SWAPFILE" 2>/dev/null | awk '{print $1}')
        available_kb=$((available_kb + ${old_kb:-0}))
    fi

    required_kb=$((size_gb * 1048576))
    if (( available_kb < required_kb )); then
        error "Not enough free disk space for ${size_gb} GB of swap."
        warn "Available space, including the old swapfile: $((available_kb / 1048576)) GB."
        return 1
    fi

    rm -f "$SWAPFILE"

    info "Creating ${size_gb} GB disk swap..."

    if ! fallocate -l "${size_gb}G" "$SWAPFILE" 2>/dev/null; then
        if ! dd if=/dev/zero of="$SWAPFILE" \
            bs=1M count=$((size_gb * 1024)) \
            status=progress conv=fsync; then
            rm -f "$SWAPFILE"
            error "Could not create swapfile."
            return 1
        fi
    fi

    chmod 600 "$SWAPFILE"

    if ! mkswap "$SWAPFILE" >/dev/null; then
        rm -f "$SWAPFILE"
        error "Could not format swapfile."
        return 1
    fi

    if ! swapon "$SWAPFILE"; then
        error "Could not activate disk swap."
        return 1
    fi

    # Replace only the swapfile entry; preserve other fstab entries.
    if grep -Fq "$SWAPFILE" /etc/fstab; then
        sed -i "\|$SWAPFILE|d" /etc/fstab
    fi

    printf '%s none swap sw 0 0\n' "$SWAPFILE" >> /etc/fstab

    success "Disk swap configured: ${size_gb} GB."
}

configure_zram_gb() {
    local size_gb="$1"
    local ram_kb percent dev sysdev active

    if ! [[ "$size_gb" =~ ^[0-9]+$ ]] ||
        (( size_gb < 1 || size_gb > 4096 )); then
        error "ZRAM size must be between 1 and 4096 GB."
        return 1
    fi

    install_zram_tools

    ram_kb=$(get_ram_kb)
    if [[ -z "$ram_kb" ]] || (( ram_kb <= 0 )); then
        error "Could not determine system RAM."
        return 1
    fi

    # zram-tools PERCENT is a percentage of physical RAM.
    # Round upward so the requested size is not rounded down.
    percent=$(( (size_gb * 104857600 + ram_kb - 1) / ram_kb ))

    if (( percent < 1 )); then
        percent=1
    fi

    # Back up the configuration before changing it.
    if [[ -f "$ZRAM_CONFIG" ]]; then
        cp -a "$ZRAM_CONFIG" "${ZRAM_CONFIG}.zilla-backup"
    fi

    # Update the target size BEFORE stopping/restarting the service.
    # Preserve ALGO, PRIORITY and other existing settings.
    set_config_value "PERCENT" "$percent" "$ZRAM_CONFIG"

    info "Requested ZRAM size: ${size_gb} GB (PERCENT=${percent})."

    # Disable any active ZRAM swap devices first.
    while read -r dev; do
        [[ "$dev" == /dev/zram* ]] || continue

        active=0
        if swapon --noheadings --raw --output=NAME 2>/dev/null |
            grep -Fxq "$dev"; then
            active=1
        fi

        if (( active )); then
            info "Disabling active ZRAM swap: $dev"
            if ! swapoff "$dev"; then
                error "Could not disable $dev."
                error "The ZRAM service was not restarted."
                return 1
            fi
        fi
    done < <(zramctl --noheadings --raw --output=NAME 2>/dev/null || true)

    # The service may remove /dev/zram0 when stopped. That is normal.
    # Never unconditionally reset a device that may no longer exist.
    info "Stopping zramswap service..."
    if ! systemctl stop zramswap; then
        warn "Service stop returned an error; checking device state."
    fi

    # Ensure no ZRAM device is still being used as swap.
    if swapon --noheadings --raw --output=NAME 2>/dev/null |
        grep -Eq '^/dev/zram[0-9]+'; then
        error "A ZRAM device is still active after stopping the service."
        error "Not starting another ZRAM device to avoid conflicts."
        return 1
    fi

    # If the service left an inactive device behind, reset it only
    # while it still exists. If it disappeared, simply continue.
    for sysdev in /sys/block/zram*; do
        [[ -e "$sysdev/disksize" ]] || continue

        dev="/dev/${sysdev##*/}"

        if [[ -b "$dev" ]]; then
            if ! zramctl --reset "$dev"; then
                # The service/device may have disappeared meanwhile.
                if [[ -e "$sysdev/disksize" && -b "$dev" ]]; then
                    error "Could not reset existing inactive device $dev."
                    error "Inspect: zramctl; journalctl -u zramswap -n 50"
                    return 1
                fi
            fi
        fi
    done

    systemctl enable zramswap >/dev/null 2>&1 || true

    info "Starting zramswap with the new configuration..."
    if ! systemctl start zramswap; then
        error "Could not start zramswap."
        journalctl -u zramswap -n 30 --no-pager || true
        return 1
    fi

    # Confirm the service created an active ZRAM swap device.
    if ! swapon --noheadings --raw --output=NAME 2>/dev/null |
        grep -Eq '^/dev/zram[0-9]+'; then
        error "zramswap started, but no active ZRAM swap was found."
        journalctl -u zramswap -n 30 --no-pager || true
        return 1
    fi

    success "ZRAM configured and activated."
    zramctl || true
}

show_status() {
    echo
    echo "========== ZILLA GOAT STATUS =========="
    echo

    echo "--- Memory ---"
    free -h || true

    echo
    echo "--- Active Swap ---"
    swapon --show || true

    echo
    echo "--- ZRAM Devices ---"
    zramctl || true

    echo
    echo "--- Swappiness ---"
    sysctl vm.swappiness || true

    echo
    echo "--- ZRAM Configuration ---"
    if [[ -f "$ZRAM_CONFIG" ]]; then
        grep -E '^[[:space:]]*(ALGO|PERCENT|PRIORITY)=' \
            "$ZRAM_CONFIG" || true
    else
        echo "zram-tools configuration not found."
    fi

    echo
    echo "======================================="
}

ask_number() {
    local prompt="$1"
    local result

    while true; do
        read -r -p "$prompt" result

        if [[ "$result" =~ ^[0-9]+$ ]]; then
            REPLY="$result"
            return 0
        fi

        warn "Enter a whole number."
    done
}

auto_optimize() {
    local ram_kb disk_gb

    ram_kb=$(get_ram_kb)
    disk_gb=$(( (ram_kb + 2097152 - 1) / 2097152 ))

    (( disk_gb < 1 )) && disk_gb=1

    echo
    info "Automatic configuration:"
    info "Disk swap: ${disk_gb} GB (approximately 50% of RAM)"
    info "ZRAM: 50% of RAM"
    info "Swappiness: 150"
    echo

    read -r -p "Continue? [y/N]: " answer
    [[ "${answer,,}" == "y" ]] || return 0

    configure_disk_swap "$disk_gb" || return 1
    configure_swappiness 150 || return 1

    # Set ZRAM to approximately 50% of physical RAM.
    # PERCENT is the native setting understood by zram-tools.
    install_zram_tools
    if [[ -f "$ZRAM_CONFIG" ]]; then
        cp -a "$ZRAM_CONFIG" "${ZRAM_CONFIG}.zilla-backup"
    fi
    set_config_value "PERCENT" 50 "$ZRAM_CONFIG"

    # Convert the 50%-of-RAM target into an integer GB request
    # for the common configuration path.
    local zram_gb
    zram_gb=$(( (ram_kb + 1048575) / 2097152 ))
    (( zram_gb < 1 )) && zram_gb=1

    configure_zram_gb "$zram_gb"
}

custom_optimize() {
    local disk_gb swapness

    echo
    echo "Enter 0 at the first prompt to return."
    ask_number "Disk swap size in GB: "
    disk_gb="$REPLY"

    (( disk_gb == 0 )) && return 0

    ask_number "Swappiness (0-200): "
    swapness="$REPLY"

    if (( swapness > 200 )); then
        error "Swappiness must be between 0 and 200."
        return 1
    fi

    configure_disk_swap "$disk_gb" || return 1
    configure_swappiness "$swapness"
}

manual_menu() {
    local choice size value

    while true; do
        echo
        echo "========== MANUAL SETTINGS =========="
        echo "1) Set disk swap size"
        echo "2) Set swappiness"
        echo "3) Set ZRAM size"
        echo "4) Show current values"
        echo "0) Return to main menu"
        echo "====================================="

        read -r -p "Select an option: " choice

        case "$choice" in
            1)
                ask_number "Disk swap size in GB (0 to return): "
                size="$REPLY"
                (( size == 0 )) && continue
                configure_disk_swap "$size" || true
                pause
                ;;
            2)
                ask_number "Swappiness 0-200 (0 to return): "
                value="$REPLY"
                (( value == 0 )) && continue

                if (( value > 200 )); then
                    error "Swappiness must be between 0 and 200."
                else
                    configure_swappiness "$value" || true
                fi
                pause
                ;;
            3)
                ask_number "ZRAM size in GB (0 to return): "
                size="$REPLY"
                (( size == 0 )) && continue
                configure_zram_gb "$size" || true
                pause
                ;;
            4)
                show_status
                pause
                ;;
            0)
                return
                ;;
            *)
                warn "Invalid option."
                ;;
        esac
    done
}

main_menu() {
    local choice

    while true; do
        clear 2>/dev/null || true

        echo -e "${CYAN}"
        echo "========================================"
        echo "          ZILLA GOAT SCRIPT"
        echo "                 v${VERSION}"
        echo "========================================"
        echo -e "${RESET}"
        echo "1) Auto Optimize"
        echo "2) Custom Optimize"
        echo "X) Set Values Manually"
        echo "3) Show Status"
        echo "4) Exit"
        echo

        read -r -p "Select an option: " choice

        case "${choice,,}" in
            1)
                auto_optimize || true
                pause
                ;;
            2)
                custom_optimize || true
                pause
                ;;
            x)
                manual_menu
                ;;
            3)
                show_status
                pause
                ;;
            4)
                echo "Exiting Zilla Goat Script."
                exit 0
                ;;
            *)
                warn "Invalid option."
                sleep 1
                ;;
        esac
    done
}

require_root
check_os
main_menu
