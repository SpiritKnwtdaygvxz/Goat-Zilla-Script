
#!/usr/bin/env bash
# ==========================================================
#                  ZILLA GOAT SCRIPT
#             Linux Hosting Optimization
#                        v3.0
# ==========================================================

set -Eeuo pipefail

VERSION="3.0"
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
    read -rp "Press Enter to continue..."
}

confirm() {
    local answer
    read -rp "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Run with root privileges: sudo bash zilla-goat.sh"
        exit 1
    fi
}

check_os() {
    if [[ ! -r /etc/os-release ]]; then
        error "Cannot identify Linux distribution."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
        error "Only Ubuntu and Debian are supported."
        exit 1
    fi

    for cmd in free swapon swapoff mkswap sysctl df awk grep; do
        command -v "$cmd" >/dev/null 2>&1 || {
            error "Missing required command: $cmd"
            exit 1
        }
    done
}

# ----------------------------------------------------------
# INPUT HELPERS
# ----------------------------------------------------------

read_gb() {
    local value
    read -rp "$1" value

    if [[ ! "$value" =~ ^[0-9]{1,4}$ ]] ||
       (( 10#$value < 1 || 10#$value > 1024 )); then
        error "Enter a whole number from 1 to 1024 GB."
        return 1
    fi

    REPLY=$((10#$value))
}

read_swappiness() {
    local value
    read -rp "Swappiness value (0-200): " value

    if [[ ! "$value" =~ ^[0-9]{1,3}$ ]] ||
       (( 10#$value > 200 )); then
        error "Enter a whole number from 0 to 200."
        return 1
    fi

    REPLY=$((10#$value))
}

ram_gb() {
    awk '/MemTotal:/ {
        printf "%d\n", int($2 / 1048576)
        exit
    }' /proc/meminfo
}

# ----------------------------------------------------------
# SWAPPINESS
# ----------------------------------------------------------

configure_swappiness() {
    local value="$1"

    if [[ ! "$value" =~ ^[0-9]{1,3}$ ]] ||
       (( 10#$value > 200 )); then
        error "Swappiness must be from 0 to 200."
        return 1
    fi

    value=$((10#$value))
    mkdir -p /etc/sysctl.d

    if [[ -f "$SYSCTL_FILE" ]]; then
        cp -n "$SYSCTL_FILE" "${SYSCTL_FILE}.zilla-backup"
    fi

    cat > "$SYSCTL_FILE" <<EOF
# Zilla Goat Script
vm.swappiness=$value
EOF

    if ! sysctl -w "vm.swappiness=$value"; then
        error "Could not apply swappiness."
        return 1
    fi

    success "Swappiness set to $value and saved persistently."
}

# ----------------------------------------------------------
# DISK SWAP
# ----------------------------------------------------------

create_swap() {
    local size_gb="$1"
    local target_bytes available_kb existing_bytes
    local temp_file="/swapfile.zilla-new"

    if [[ ! "$size_gb" =~ ^[0-9]{1,4}$ ]] ||
       (( 10#$size_gb < 1 || 10#$size_gb > 1024 )); then
        error "Swap size must be between 1 and 1024 GB."
        return 1
    fi

    size_gb=$((10#$size_gb))
    target_bytes=$((size_gb * 1073741824))

    # Keep an existing swap file if its size is already correct.
    if [[ -f "$SWAP_FILE" ]]; then
        existing_bytes=$(stat -c %s "$SWAP_FILE")

        if (( existing_bytes == target_bytes )) &&
           swapon --noheadings --raw --show=NAME |
               grep -Fxq "$SWAP_FILE"; then
            success "Disk swap is already ${size_gb} GB."
            return 0
        fi

        warn "An existing $SWAP_FILE was found."
        warn "Changing its size requires disabling it temporarily."

        if ! confirm "Resize the existing swap file to ${size_gb} GB?"; then
            info "Existing swap left unchanged."
            return 1
        fi

        if swapon --noheadings --raw --show=NAME |
            grep -Fxq "$SWAP_FILE"; then
            if ! swapoff "$SWAP_FILE"; then
                error "Could not disable existing swap. Nothing was deleted."
                return 1
            fi
        fi

        rm -f "$SWAP_FILE"
    fi

    # Avoid overwriting a previous temporary file.
    if [[ -e "$temp_file" ]]; then
        error "$temp_file already exists. Inspect it manually first."
        return 1
    fi

    available_kb=$(df -Pk / | awk 'NR==2 {print $4}')

    if [[ ! "$available_kb" =~ ^[0-9]+$ ]] ||
       (( available_kb < size_gb * 1048576 + 1048576 )); then
        error "Not enough free disk space. Leave at least 1 GB free."
        return 1
    fi

    info "Creating ${size_gb} GB disk swap..."

    if ! fallocate -l "${size_gb}G" "$temp_file"; then
        rm -f "$temp_file"

        if ! dd if=/dev/zero of="$temp_file" \
            bs=1M count="$((size_gb * 1024))" \
            status=progress conv=fsync; then
            rm -f "$temp_file"
            error "Failed to allocate swap file."
            return 1
        fi
    fi

    chmod 600 "$temp_file"

    if ! mkswap "$temp_file"; then
        rm -f "$temp_file"
        error "Failed to initialize swap file."
        return 1
    fi

    mv "$temp_file" "$SWAP_FILE"

    if ! swapon "$SWAP_FILE"; then
        rm -f "$SWAP_FILE"
        error "Could not activate swap. Check filesystem support."
        return 1
    fi

    # Add exactly one persistent fstab entry.
    local fstab_tmp
    fstab_tmp=$(mktemp)

    awk '$1 != "/swapfile" {print}' /etc/fstab > "$fstab_tmp"
    printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> "$fstab_tmp"
    cat "$fstab_tmp" > /etc/fstab
    rm -f "$fstab_tmp"

    success "Disk swap configured: ${size_gb} GB."
}

# ----------------------------------------------------------
# ZRAM
# Uses the Debian/Ubuntu zram-tools service and config.
# PERCENT is calculated from physical RAM.
# ----------------------------------------------------------

configure_zram() {
    local size_gb="$1"
    local total_kb percent active_dev algo

    if [[ ! "$size_gb" =~ ^[0-9]{1,4}$ ]] ||
       (( 10#$size_gb < 1 || 10#$size_gb > 1024 )); then
        error "ZRAM size must be from 1 to 1024 GB."
        return 1
    fi

    size_gb=$((10#$size_gb))
    total_kb=$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo)

    # zram-tools uses PERCENT rather than a fixed GB value.
    # Round to the nearest whole percentage.
    percent=$(( (size_gb * 1048576 * 100 + total_kb / 2) / total_kb ))

    if (( percent < 1 )); then
        percent=1
    fi

    if (( percent > 200 )); then
        error "This zram-tools configuration supports at most 200% RAM."
        return 1
    fi

    info "Requested ZRAM: ${size_gb} GB."
    info "zram-tools percentage: ${percent}% of physical RAM."
    warn "The resulting device size is approximate."

    # Install the standard Debian/Ubuntu service if necessary.
    if ! command -v zramswap >/dev/null 2>&1; then
        info "Installing zram-tools..."
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools
    fi

    mkdir -p /etc/default

    if [[ ! -f "$ZRAM_CONFIG" ]]; then
        touch "$ZRAM_CONFIG"
    fi

    # Back up the package config once.
    cp -n "$ZRAM_CONFIG" "${ZRAM_CONFIG}.zilla-backup"

    active_dev=$(swapon --noheadings --raw --show=NAME |
        grep -E '^/dev/zram[0-9]+$' || true)

    if [[ -n "$active_dev" ]]; then
        if [[ "$active_dev" == *$'\n'* ]]; then
            error "Multiple active ZRAM devices found."
            error "This script will not resize multiple devices automatically."
            return 1
        fi

        local dev_bytes target_bytes
        dev_bytes=$(cat "/sys/block/${active_dev##*/}/disksize" 2>/dev/null || echo 0)
        target_bytes=$((size_gb * 1073741824))

        if [[ "$dev_bytes" =~ ^[0-9]+$ ]] &&
           (( dev_bytes == target_bytes )); then
            success "Active ZRAM already has the requested size."
            return 0
        fi

        warn "Active ZRAM will need to be disabled and recreated."
        warn "Swapped pages must move elsewhere; this may fail under memory pressure."

        if ! confirm "Attempt to resize ${active_dev} to ${size_gb} GB?"; then
            info "Existing ZRAM left unchanged."
            return 1
        fi

        if ! swapoff "$active_dev"; then
            error "Could not disable ZRAM. It has not been reset."
            return 1
        fi

        # Stop the standard service before resetting the device.
        systemctl stop zramswap 2>/dev/null || true

        if ! zramctl --reset "$active_dev"; then
            error "Could not reset the inactive ZRAM device."
            error "Inspect zramctl and the service logs before proceeding."
            return 1
        fi
    else
        # A device may be initialized but not currently enabled as swap.
        for dev in /sys/block/zram*; do
            [[ -e "$dev/disksize" ]] || continue

            local current_size
            current_size=$(cat "$dev/disksize" 2>/dev/null || echo 0)

            if [[ "$current_size" =~ ^[0-9]+$ ]] &&
               (( current_size > 0 )); then
                warn "Found initialized ZRAM: ${dev##*/}."
                warn "Not resetting an inactive, initialized device automatically."
                warn "Inspect it with zramctl before trying again."
                return 1
            fi
        done
    fi

    # Preserve ALGO, PRIORITY, and other existing settings.
    # Change only PERCENT.
    sed -i -E '/^[[:space:]]*PERCENT=/d' "$ZRAM_CONFIG"
    printf '\n# Zilla Goat requested ZRAM size\nPERCENT=%s\n' \
        "$percent" >> "$ZRAM_CONFIG"

    # Load the module if needed.
    if ! modprobe zram; then
        error "Could not load the ZRAM kernel module."
        return 1
    fi

    systemctl enable zramswap

    if ! systemctl restart zramswap; then
        error "ZRAM service failed to start."
        journalctl -u zramswap -n 30 --no-pager || true
        return 1
    fi

    success "ZRAM service started with PERCENT=${percent}."
    zramctl || true
}

# ----------------------------------------------------------
# AUTOMATIC OPTIMIZER
# Disk swap = 50% RAM
# ZRAM = 50% of disk swap
# Swappiness = 150
# ----------------------------------------------------------

auto_optimize() {
    local ram swap_size zram_size

    ram=$(ram_gb)

    if (( ram < 2 )); then
        error "Could not determine enough physical RAM for auto mode."
        return 1
    fi

    swap_size=$((ram / 2))
    zram_size=$((swap_size / 2))

    (( swap_size < 1 )) && swap_size=1
    (( zram_size < 1 )) && zram_size=1

    echo
    echo "Detected physical RAM: ${ram} GB (rounded down)"
    echo "Target disk swap:      ${swap_size} GB"
    echo "Target ZRAM:            ${zram_size} GB"
    echo "Swappiness:             150"
    echo

    warn "Existing swap may need to be resized."
    read -rp "Continue with automatic configuration? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 0

    create_swap "$swap_size" || return 1
    configure_zram "$zram_size" || return 1
    configure_swappiness 150 || return 1

    success "Automatic configuration completed."
}

custom_optimize() {
    local swap_size swappiness

    echo
    read_gb "Disk swap size (GB): " || return 1
    swap_size="$REPLY"

    read_swappiness || return 1
    swappiness="$REPLY"

    create_swap "$swap_size" || return 1
    configure_swappiness "$swappiness" || return 1

    success "Custom disk swap and swappiness configured."
}

# ----------------------------------------------------------
# MANUAL CONFIGURATION MENU
# 0 returns to the main menu.
# ----------------------------------------------------------

manual_menu() {
    local value

    while true; do
        clear || true

        echo -e "${CYAN}"
        echo "========================================"
        echo "       ZILLA GOAT - MANUAL CONFIG"
        echo "========================================"
        echo -e "${RESET}"

        echo "1. Set Disk Swap Size"
        echo "2. Set Swappiness"
        echo "3. Set ZRAM Size"
        echo "4. Show Current Values"
        echo "0. Back to Main Menu"
        echo

        read -rp "Select an option [0-4]: " choice

        case "$choice" in
            1)
                echo
                read_gb "Desired disk swap size (GB): " || {
                    pause
                    continue
                }
                value="$REPLY"

                if confirm "Configure disk swap to ${value} GB?"; then
                    create_swap "$value" || true
                fi
                pause
                ;;
            2)
                echo
                read_swappiness || {
                    pause
                    continue
                }
                value="$REPLY"

                if confirm "Set swappiness to ${value}?"; then
                    configure_swappiness "$value" || true
                fi
                pause
                ;;
            3)
                echo
                read_gb "Desired ZRAM size (GB): " || {
                    pause
                    continue
                }
                value="$REPLY"

                if confirm "Configure ZRAM to approximately ${value} GB?"; then
                    configure_zram "$value" || true
                fi
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
                error "Invalid option."
                sleep 1
                ;;
        esac
    done
}

# ----------------------------------------------------------
# STATUS
# ----------------------------------------------------------

show_status() {
    echo
    echo "========== ZILLA GOAT STATUS =========="
    echo

    echo "--- Physical RAM ---"
    free -h

    echo
    echo "--- Swap devices ---"
    swapon --show

    echo
    echo "--- ZRAM devices ---"
    if command -v zramctl >/dev/null 2>&1; then
        zramctl || true
    else
        echo "zramctl not installed."
    fi

    echo
    echo "--- Swappiness ---"
    sysctl vm.swappiness

    echo
    echo "--- Persistent Zilla Goat settings ---"
    if [[ -f "$SYSCTL_FILE" ]]; then
        cat "$SYSCTL_FILE"
    else
        echo "No Zilla Goat swappiness file found."
    fi

    echo
    echo "--- ZRAM service ---"
    systemctl --no-pager --full status zramswap 2>/dev/null |
        head -n 12 || true

    echo
    echo "======================================="
}

# ----------------------------------------------------------
# MAIN MENU
# ----------------------------------------------------------

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
        echo "1. Auto Optimize (50% RAM swap, 50% of swap for ZRAM)"
        echo "2. Custom Optimize (disk swap + swappiness)"
        echo "X. Set Values Manually"
        echo "3. Check System Status"
        echo "4. Exit"
        echo

        read -rp "Select an option: " choice

        case "$choice" in
            1)
                auto_optimize || warn "Operation incomplete."
                pause
                ;;
            2)
                custom_optimize || warn "Operation incomplete."
                pause
                ;;
            [xX])
                manual_menu
                ;;
            3)
                show_status
                pause
                ;;
            4)
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
