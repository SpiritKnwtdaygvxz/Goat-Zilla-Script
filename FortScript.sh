
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# ZILLA GOAT SCRIPT v3.2
# Ubuntu / Debian Swap, ZRAM and Swappiness Manager
# ============================================================

VERSION="3.2"
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
    if (( EUID != 0 )); then
        error "Run as root: sudo bash $0"
        exit 1
    fi
}

check_os() {
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

install_zram_tools() {
    if ! command -v zramswap >/dev/null 2>&1; then
        info "Installing zram-tools..."
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools
    fi

    mkdir -p /etc/default
    touch "$ZRAM_CONFIG"
}

# Replace active or commented values for one config key.
# Other settings, including ALGO and PRIORITY, are preserved.
set_config_value() {
    local key="$1"
    local value="$2"
    local file="$3"
    local tmp

    tmp=$(mktemp)

    awk -v key="$key" '
        {
            line=$0
            testline=line
            sub(/^[[:space:]]*/, "", testline)
            sub(/^#[[:space:]]*/, "", testline)

            if (testline ~ ("^" key "[[:space:]]*=")) next
            print line
        }
    ' "$file" > "$tmp"

    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

configure_swappiness() {
    local value="$1"

    if ! [[ "$value" =~ ^[0-9]+$ ]] ||
       (( value < 0 || value > 200 )); then
        error "Swappiness must be between 0 and 200."
        return 1
    fi

    printf 'vm.swappiness = %s\n' "$value" > "$SYSCTL_FILE"

    if ! sysctl -w "vm.swappiness=$value" >/dev/null; then
        error "Could not apply swappiness."
        return 1
    fi

    success "Swappiness set to $value."
}

configure_disk_swap() {
    local size_gb="$1"
    local available_kb old_kb=0 required_kb

    if ! [[ "$size_gb" =~ ^[0-9]+$ ]] ||
       (( size_gb < 1 || size_gb > 4096 )); then
        error "Disk swap size must be between 1 and 4096 GB."
        return 1
    fi

    available_kb=$(df -Pk / | awk 'NR==2 {print $4}')
    required_kb=$((size_gb * 1048576))

    if [[ -f "$SWAPFILE" ]]; then
        old_kb=$(du -sk "$SWAPFILE" 2>/dev/null | awk '{print $1}')
        old_kb=${old_kb:-0}
        available_kb=$((available_kb + old_kb))
    fi

    if (( available_kb < required_kb )); then
        error "Not enough disk space for ${size_gb} GB swap."
        return 1
    fi

    if swapon --noheadings --raw --output=NAME 2>/dev/null |
       grep -Fxq "$SWAPFILE"; then
        info "Disabling current disk swap..."
        if ! swapoff "$SWAPFILE"; then
            error "Could not disable $SWAPFILE. No changes made."
            return 1
        fi
    fi

    rm -f "$SWAPFILE"

    info "Creating ${size_gb} GB disk swap..."

    if ! fallocate -l "${size_gb}G" "$SWAPFILE" 2>/dev/null; then
        if ! dd if=/dev/zero of="$SWAPFILE" \
            bs=1M count=$((size_gb * 1024)) \
            status=progress conv=fsync; then
            rm -f "$SWAPFILE"
            error "Could not create the swapfile."
            return 1
        fi
    fi

    chmod 600 "$SWAPFILE"

    if ! mkswap "$SWAPFILE" >/dev/null; then
        error "Could not format the swapfile."
        return 1
    fi

    if ! swapon "$SWAPFILE"; then
        error "Could not activate the swapfile."
        return 1
    fi

    if grep -Fq "$SWAPFILE" /etc/fstab; then
        sed -i "\|$SWAPFILE|d" /etc/fstab
    fi

    printf '%s none swap sw 0 0\n' "$SWAPFILE" >> /etc/fstab

    success "Disk swap configured: ${size_gb} GB."
}

# Accept both /dev/zram0 and zram0 naming formats.
zram_swap_active() {
    swapon --noheadings --raw --output=NAME 2>/dev/null |
        awk '$NF ~ /(^|\/)zram[0-9]+$/ { found=1 }
             END { exit !found }'
}

zram_device_exists() {
    local device

    for device in /sys/block/zram[0-9]*; do
        [[ -e "$device/disksize" ]] && return 0
    done

    return 1
}

configure_zram_percent() {
    local percent="$1"
    local device

    if ! [[ "$percent" =~ ^[0-9]+$ ]] ||
       (( percent < 1 || percent > 400 )); then
        error "ZRAM percentage must be between 1 and 400."
        return 1
    fi

    install_zram_tools

    # Back up the existing configuration.
    cp -a "$ZRAM_CONFIG" "${ZRAM_CONFIG}.zilla-backup"

    # Write the new target BEFORE restarting the service.
    set_config_value "PERCENT" "$percent" "$ZRAM_CONFIG"

    info "Setting ZRAM to ${percent}% of system RAM."

    # Turn off ZRAM swap safely before stopping its service.
    while read -r device; do
        [[ "$device" =~ (^|/)zram[0-9]+$ ]] || continue

        if ! swapoff "$device"; then
            error "Could not disable $device."
            error "ZRAM configuration saved, but service was not restarted."
            return 1
        fi
    done < <(
        swapon --noheadings --raw --output=NAME 2>/dev/null || true
    )

    info "Stopping zramswap..."

    # zramswap may remove /dev/zram0 itself. That is normal.
    systemctl stop zramswap || warn "Service stop returned an error."

    if zram_swap_active; then
        error "ZRAM swap is still active. Aborting restart."
        swapon --show
        return 1
    fi

    # Reset only devices that STILL exist after the service stops.
    # Never reset a device that the service has already removed.
    for device in /sys/block/zram[0-9]*; do
        [[ -e "$device/disksize" ]] || continue

        local dev="/dev/${device##*/}"

        if [[ -b "$dev" ]]; then
            if ! zramctl --reset "$dev"; then
                if [[ -e "$device/disksize" && -b "$dev" ]]; then
                    error "Could not reset existing inactive device $dev."
                    error "Check zramctl and the zramswap service logs."
                    return 1
                fi
            fi
        fi
    done

    systemctl enable zramswap >/dev/null 2>&1 || true

    info "Starting zramswap with the updated configuration..."

    if ! systemctl start zramswap; then
        error "zramswap failed to start."
        journalctl -u zramswap -n 40 --no-pager || true
        return 1
    fi

    # Check the actual device and active swap independently.
    # Do not rely on the systemd service's active/exited status.
    if ! zram_device_exists; then
        error "Service finished, but no ZRAM device exists."
        journalctl -u zramswap -n 40 --no-pager || true
        return 1
    fi

    if ! zram_swap_active; then
        error "ZRAM device exists but is not active as swap."
        zramctl || true
        swapon --show || true
        journalctl -u zramswap -n 40 --no-pager || true
        return 1
    fi

    success "ZRAM configured and active."
    zramctl || true
    swapon --show
}

configure_zram_size_gb() {
    local size_gb="$1"
    local ram_kb percent

    if ! [[ "$size_gb" =~ ^[0-9]+$ ]] ||
       (( size_gb < 1 || size_gb > 4096 )); then
        error "ZRAM size must be between 1 and 4096 GB."
        return 1
    fi

    ram_kb=$(get_ram_kb)

    if [[ -z "$ram_kb" ]] || (( ram_kb < 1 )); then
        error "Could not determine physical RAM."
        return 1
    fi

    # PERCENT represents a percentage of physical RAM.
    # Round upward to avoid rounding below the requested size.
    percent=$(( (size_gb * 104857600 + ram_kb - 1) / ram_kb ))

    (( percent < 1 )) && percent=1

    configure_zram_percent "$percent"
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
        grep -E '^[[:space:]]*(ALGO|PERCENT|SIZE|PRIORITY)=' \
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
            return
        fi

        warn "Enter a whole number."
    done
}

auto_optimize() {
    local ram_kb disk_gb

    ram_kb=$(get_ram_kb)
    disk_gb=$(( (ram_kb + 2097151) / 2097152 ))
    (( disk_gb < 1 )) && disk_gb=1

    echo
    echo "Automatic configuration:"
    echo "  Disk swap: approximately 50% of RAM (${disk_gb} GB)"
    echo "  ZRAM: 50% of RAM"
    echo "  Swappiness: 150"
    echo

    read -r -p "Continue? [y/N]: " answer
    [[ "${answer,,}" == "y" ]] || return 0

    configure_disk_swap "$disk_gb" || return 1
    configure_swappiness 150 || return 1
    configure_zram_percent 50
}

custom_optimize() {
    local disk_gb swappiness

    echo
    ask_number "Disk swap size in GB (0 to cancel): "
    disk_gb="$REPLY"
    (( disk_gb == 0 )) && return 0

    ask_number "Swappiness (0-200): "
    swappiness="$REPLY"

    if (( swappiness > 200 )); then
        error "Swappiness must be between 0 and 200."
        return 1
    fi

    configure_disk_swap "$disk_gb" || return 1
    configure_swappiness "$swappiness"
}

manual_menu() {
    local choice value

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
                value="$REPLY"
                (( value == 0 )) && continue
                configure_disk_swap "$value" || true
                pause
                ;;
            2)
                read -r -p "Swappiness 0-200 (q to cancel): " value
                [[ "${value,,}" == "q" ]] && continue

                if [[ "$value" =~ ^[0-9]+$ ]] &&
                   (( value <= 200 )); then
                    configure_swappiness "$value" || true
                else
                    error "Enter a number from 0 to 200."
                fi
                pause
                ;;
            3)
                ask_number "ZRAM size in GB (0 to return): "
                value="$REPLY"
                (( value == 0 )) && continue
                configure_zram_size_gb "$value" || true
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
