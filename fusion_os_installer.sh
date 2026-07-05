#!/usr/bin/env bash
# ============================================================================
#  Project Fusion-OS v2.0 — Ultimate Portable Encrypted Workstation Deployer
#  Single USB · 6 Arch-based distros · LUKS2 full-disk encryption
# ============================================================================
set -euo pipefail

VERSION="2.0.0"
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

# ---- Colors ---------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

# ---- Logging --------------------------------------------------------------
LOG_FILE=""
log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

init_log() {
    LOG_FILE="/tmp/fusion_os_installer_$(date +%Y%m%d_%H%M%S).log"
    touch "$LOG_FILE" 2>/dev/null || die "Failed to create log file."
    STATE_FILE=$(mktemp /tmp/fusion_os_state_XXXXXX)
    touch "${STATE_FILE}" 2>/dev/null || die "Failed to create state file."
}

info()  { echo -e "${CYAN}[INFO]${NC}  $*" >&2; [ -n "$LOG_FILE" ] && echo "$(log_ts) [INFO]  $*" >> "$LOG_FILE"; return 0; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; [ -n "$LOG_FILE" ] && echo "$(log_ts) [OK]    $*" >> "$LOG_FILE"; return 0; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; [ -n "$LOG_FILE" ] && echo "$(log_ts) [WARN]  $*" >> "$LOG_FILE"; return 0; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2;  [ -n "$LOG_FILE" ] && echo "$(log_ts) [ERROR] $*" >> "$LOG_FILE"; exit 1; }

# ---- Global variables -----------------------------------------------------
TARGET_DISK=""
DISK_NAME=""
PART_BIOS=""          # p1 — BIOS Boot (1MB, GPT type EF02)
PART_ESP=""           # p2 — ESP (GRUB EFI)
PART_ROOT=""          # p3 — LUKS2
ARCH_SIZE_MB=0
LUKS_MAPPER="fusion"
VG_NAME="fusion_vg"
LUKS_UUID=""
USER_NAME=""
USER_PASS=""
declare -A LV_MAP=( [arch]=arch_lv [cachyos]=cachyos_lv [archcraft]=archcraft_lv [biglinux]=biglinux_lv [manjaro]=manjaro_lv [mabox]=mabox_lv )

STANDALONE_GRUB_EFI=""  # Path to standalone GRUB EFI with embedded modules (set in step 4)

MNT_ROOT=""    # temp mount base

LUKS_KEYFILE="" # track keyfile for trap cleanup
cleanup_dirs=()
SELECTED_DISTROS=()

# Existing deployment detection results
EXISTING_LUKS=false
EXISTING_VG=false
DEPLOYED_DISTROS=()
WIPE_MODE=""  # "all" or "linux_only"

# ---- Profile system ---------------------------------------------------------
# Profiles are loaded from profiles/*.profile files
# Each profile defines: PROFILE_NAME, PROFILE_LABEL, PROFILE_KERNEL, PROFILE_MKINITCPIO_PRESET,
# PROFILE_EXTRA_PKGS, PROFILE_KEYRING_URL, PROFILE_REPO_CONF, PROFILE_KEYRING_PGP,
# PROFILE_BOOT_PARAMS, PROFILE_REMOVE_PKGS, PROFILE_POST_INSTALL_HOOKS
declare -A PROF_LABEL
declare -A PROF_KERNEL
declare -A PROF_MKINITCPIO_PRESET
declare -A PROF_EXTRA_PKGS
declare -A PROF_KEYRING_URL
declare -A PROF_REPO_CONF
declare -A PROF_KEYRING_PGP
declare -A PROF_BOOT_PARAMS
declare -A PROF_REMOVE_PKGS
declare -A PROF_POST_INSTALL_HOOKS
AVAILABLE_PROFILES=()

load_profiles() {
    local profile_dir
    profile_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/profiles"
    [ -d "${profile_dir}" ] || die "Profile directory not found: ${profile_dir}"

    local profile_file profile_name
    for profile_file in "${profile_dir}"/*.profile; do
        [ -f "${profile_file}" ] || continue
        
        # Clear profile variables before sourcing
        unset PROFILE_NAME PROFILE_LABEL PROFILE_KERNEL PROFILE_MKINITCPIO_PRESET
        unset PROFILE_EXTRA_PKGS PROFILE_KEYRING_URL PROFILE_REPO_CONF PROFILE_KEYRING_PGP
        unset PROFILE_BOOT_PARAMS PROFILE_REMOVE_PKGS PROFILE_POST_INSTALL_HOOKS
        
        # shellcheck disable=SC1090
        source "${profile_file}"
        [ -n "${PROFILE_NAME:-}" ] || { warn "Profile ${profile_file} missing PROFILE_NAME, skipping"; continue; }
        profile_name="${PROFILE_NAME}"

        AVAILABLE_PROFILES+=("${profile_name}")
        PROF_LABEL["${profile_name}"]="${PROFILE_LABEL:-${profile_name}}"
        PROF_KERNEL["${profile_name}"]="${PROFILE_KERNEL:-linux}"
        PROF_MKINITCPIO_PRESET["${profile_name}"]="${PROFILE_MKINITCPIO_PRESET:-linux}"
        PROF_EXTRA_PKGS["${profile_name}"]="${PROFILE_EXTRA_PKGS:-}"
        PROF_KEYRING_URL["${profile_name}"]="${PROFILE_KEYRING_URL:-}"
        PROF_REPO_CONF["${profile_name}"]="${PROFILE_REPO_CONF:-}"
        PROF_KEYRING_PGP["${profile_name}"]="${PROFILE_KEYRING_PGP:-}"
        PROF_BOOT_PARAMS["${profile_name}"]="${PROFILE_BOOT_PARAMS:-}"
        PROF_REMOVE_PKGS["${profile_name}"]="${PROFILE_REMOVE_PKGS:-}"
        PROF_POST_INSTALL_HOOKS["${profile_name}"]="${PROFILE_POST_INSTALL_HOOKS:-}"

        info "Loaded profile: ${profile_name} (${PROF_LABEL[${profile_name}]})"
    done

    [ ${#AVAILABLE_PROFILES[@]} -gt 0 ] || die "No valid profiles found in ${profile_dir}"
}

# Load profiles at startup
load_profiles

# ---- Helper functions ----------------------------------------------------
cleanup() {
    local exit_code=$?
    trap '' EXIT ERR INT TERM
    info "Cleaning up..."
    if [ -n "${LUKS_KEYFILE:-}" ] && [ -f "${LUKS_KEYFILE}" ]; then
        rm -f "${LUKS_KEYFILE}"
    fi
    for d in "${cleanup_dirs[@]}"; do
        mountpoint -q "$d" 2>/dev/null && umount -R "$d" 2>/dev/null || true
    done
    if [ -n "${MNT_ROOT:-}" ] && mountpoint -q "${MNT_ROOT}" 2>/dev/null; then
        umount -R "${MNT_ROOT}" 2>/dev/null || true
    fi
    if [ -e "/dev/mapper/${LUKS_MAPPER}" ]; then
        vgchange -a n "${VG_NAME}" 2>/dev/null || true
        cryptsetup close "${LUKS_MAPPER}" 2>/dev/null || true
    fi
    clear_state
    [ $exit_code -eq 0 ] && ok "Cleanup complete." || warn "Cleanup done (exit code $exit_code)."
}

trap cleanup EXIT ERR INT TERM

# Run a command, tee its output to terminal in real-time, and log it with timestamps.
# Usage: run_logged "LABEL" command [args...]
run_logged() {
    local label="$1"
    shift
    local logfile rc
    logfile=$(mktemp /tmp/fusion_log_XXXXXX)
    "$@" 2>&1 | tee "${logfile}"
    rc=${PIPESTATUS[0]}
    if [ -s "${logfile}" ]; then
        while IFS= read -r line; do
            echo "$(log_ts) [${label}] $line" >> "$LOG_FILE"
        done < "${logfile}"
    fi
    rm -f "${logfile}"
    return $rc
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${YELLOW}[INFO]${NC}  Not running as root. Re-executing with sudo..."
        local -a sudo_env=()
        [ -n "${DISPLAY:-}" ]          && sudo_env+=(DISPLAY="${DISPLAY}")
        [ -n "${WAYLAND_DISPLAY:-}" ]  && sudo_env+=(WAYLAND_DISPLAY="${WAYLAND_DISPLAY}")
        [ -n "${XAUTHORITY:-}" ]       && sudo_env+=(XAUTHORITY="${XAUTHORITY}")
        [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && sudo_env+=(DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}")
        exec sudo "${sudo_env[@]}" bash "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" "$@"
    fi
}

retry() {
    local attempts=3 delay=5 rc
    while [ $attempts -gt 0 ]; do
        "$@" && return 0
        rc=$?
        attempts=$(( attempts - 1 ))
        [ $attempts -gt 0 ] && warn "Command failed, retrying in ${delay}s... ($(( 3 - attempts ))/3)" && sleep "$delay"
    done
    return $rc
}

check_network() {
    info "Checking network connectivity..."
    if ping -c 1 -W 3 archlinux.org &>/dev/null || \
       ping -c 1 -W 3 google.com &>/dev/null || \
       curl -s --connect-timeout 5 https://archlinux.org >/dev/null 2>&1; then
        ok "Network reachable."
    else
        die "No network connectivity. Please check your internet connection."
    fi
}

optimize_mirrors() {
    info "Testing mirror speeds and selecting fastest..."

    if command -v reflector &>/dev/null; then
        cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.fusion-backup 2>/dev/null || true
        run_logged "REFLECTOR" reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
        rm -f /etc/pacman.d/mirrorlist.fusion-backup
        ok "Mirrors optimized by speed (reflector)."
    else
        warn "reflector not found — skipping mirror optimization."
        warn "Install reflector: pacman -S reflector"
    fi
}

check_deps() {
    local missing=() cmd_pkg
    for cmd_pkg in \
        curl:curl wget:wget sgdisk:gptfdisk cryptsetup:cryptsetup \
        mkfs.ext4:e2fsprogs mkfs.vfat:dosfstools \
        lsblk:util-linux blkid:util-linux \
        partprobe:parted pacstrap:arch-install-scripts \
        arch-chroot:arch-install-scripts lvm:lvm2 lvcreate:lvm2 \
        efibootmgr:efibootmgr reflector:reflector; do
        local cmd="${cmd_pkg%%:*}" pkg="${cmd_pkg##*:}"
        if ! command -v "$cmd" &>/dev/null; then missing+=("$pkg"); fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        local unique_pkgs
        unique_pkgs=$(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')
        info "Missing dependencies: ${unique_pkgs}"
        info "Installing missing packages..."
        # shellcheck disable=SC2086
        pacman -S --noconfirm $unique_pkgs || die "Failed to install dependencies."
    fi

    ok "All dependencies satisfied."
}

confirm_destructive() {
    echo -e "\n${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    echo -e "${RED}CRITICAL WARNING: ALL DATA ON ${TARGET_DISK} WILL BE WIPED!${NC}"
    echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
    echo "Target: $TARGET_DISK ($(lsblk -nd -o SIZE,MODEL "$TARGET_DISK" 2>/dev/null || echo "unknown"))"
    if [ -z "${NONINTERACTIVE:-}" ]; then
        read -rp "Type 'CONFIRM' to execute Fusion-OS deployment: " CONFIRM_INPUT
        if [ "$CONFIRM_INPUT" != "CONFIRM" ]; then
            die "Deployment aborted by user."
        fi
    fi
}

random_password() {
    if command -v openssl &>/dev/null; then
        openssl rand -base64 24 | head -c 16
    elif [ -r /dev/urandom ]; then
        head -c 32 /dev/urandom | base64 | head -c 16
    else
        die "Failed to generate random password (no /dev/urandom or openssl)."
    fi
}

# ---- State tracking (for resume support) ----------------------------------
STATE_FILE=""

save_state() {
    local step="$1"
    echo "STEP=${step}" > "${STATE_FILE}"
    echo "TARGET_DISK=${TARGET_DISK}" >> "${STATE_FILE}"
    echo "DISK_NAME=${DISK_NAME}" >> "${STATE_FILE}"
    echo "ARCH_SIZE_MB=${ARCH_SIZE_MB}" >> "${STATE_FILE}"
    echo "LUKS_UUID=${LUKS_UUID:-}" >> "${STATE_FILE}"
    echo "USER_NAME=${USER_NAME:-}" >> "${STATE_FILE}"
    echo "SELECTED_DISTROS=(${SELECTED_DISTROS[*]:-})" >> "${STATE_FILE}"
}

load_state() {
    if [ -f "${STATE_FILE}" ]; then
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
        # Preserve saved distro list for resume; main() will re-select if needed
        return 0
    fi
    return 1
}

clear_state() {
    rm -f "${STATE_FILE}"
}

get_completed_step() {
    if [ -f "${STATE_FILE}" ]; then
        grep "^STEP=" "${STATE_FILE}" 2>/dev/null | cut -d= -f2 || echo "0"
    else
        echo "0"
    fi
}

# ---- Restore LUKS/LVM state for resume ------------------------------------
restore_disk_state() {
    set_partition_vars
    if [ -e "/dev/mapper/${LUKS_MAPPER}" ]; then
        info "LUKS container already open."
    elif [ -b "${PART_ROOT}" ]; then
        info "Opening LUKS container..."
        if [ -n "${NONINTERACTIVE:-}" ]; then
            [ -z "${LUKS_PASSPHRASE:-}" ] && die "NONINTERACTIVE mode requires LUKS_PASSPHRASE to resume."
            LUKS_KEYFILE=$(mktemp)
            chmod 600 "${LUKS_KEYFILE}"
            echo -n "${LUKS_PASSPHRASE}" > "${LUKS_KEYFILE}"
            cryptsetup open "${PART_ROOT}" "${LUKS_MAPPER}" --key-file "${LUKS_KEYFILE}" || \
                die "Failed to open LUKS container for resume."
            rm -f "${LUKS_KEYFILE}"
            LUKS_KEYFILE=""
        else
            cryptsetup open "${PART_ROOT}" "${LUKS_MAPPER}" || \
                die "Failed to open LUKS container for resume."
        fi
    fi
    if vgdisplay "${VG_NAME}" >/dev/null 2>&1; then
        local vg_free_check
        vg_free_check=$(vgs "${VG_NAME}" --noheadings --nosuffix --units m -o vg_free 2>/dev/null \
            | awk '{print int($1)}' || echo "0")
        info "VG free space: ${vg_free_check}MB"
        if [ "${vg_free_check:-0}" -gt 100 ]; then
            info "Activating LVM volume group (free: ${vg_free_check}MB)..."
            vgchange -a y "${VG_NAME}" 2>/dev/null || true
        else
            warn "VG '${VG_NAME}' has only ${vg_free_check:-0}MB free — removing stale state..."
            vgchange -a n "${VG_NAME}" 2>/dev/null || true
            local existing_lvs
            existing_lvs=$(lvs "${VG_NAME}" --noheadings -o name 2>/dev/null | tr -d ' ' || true)
            for lv_name in $existing_lvs; do
                lvremove -f "${VG_NAME}/${lv_name}" 2>/dev/null || true
            done
            vgremove -f "${VG_NAME}" 2>/dev/null || true
            pvremove -f "/dev/mapper/${LUKS_MAPPER}" 2>/dev/null || true
            info "Recreating fresh PV + VG..."
            pvcreate -f "/dev/mapper/${LUKS_MAPPER}" || die "pvcreate failed on resume."
            vgcreate "${VG_NAME}" "/dev/mapper/${LUKS_MAPPER}" || die "vgcreate failed on resume."
            vgchange -a y "${VG_NAME}" 2>/dev/null || true
        fi
    else
        info "No existing VG found — creating fresh PV + VG..."
        pvcreate "/dev/mapper/${LUKS_MAPPER}" 2>/dev/null || die "pvcreate failed on resume."
        vgcreate "${VG_NAME}" "/dev/mapper/${LUKS_MAPPER}" 2>/dev/null || die "vgcreate failed on resume."
        vgchange -a y "${VG_NAME}" 2>/dev/null || true
    fi
    MNT_ROOT=$(mktemp -d)
    cleanup_dirs+=("${MNT_ROOT}")
}

# ---- Disk selection -------------------------------------------------------
select_disk() {
    local usb_devices
    usb_devices=$(lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -i "usb" | grep -v "loop" | grep -v "rom" || true)
    if [ -n "${usb_devices}" ]; then
        echo -e "\n${CYAN}Available USB storage devices:${NC}"
        echo "${usb_devices}"
    else
        echo -e "\n${YELLOW}No USB devices detected. Showing all devices:${NC}"
        lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -v "loop" | grep -v "rom" || true
    fi

    echo -e "\n[S] Show all storage devices"
    echo -e "[C] Continue with shown selection"
    read -rp "Choice: " CHOICE

    if [[ "$CHOICE" == "S" || "$CHOICE" == "s" ]]; then
        echo -e "\n${CYAN}All available storage devices:${NC}"
        lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -v "loop" | grep -v "rom" || true
    fi

    echo ""
    read -rp "Enter target disk name (e.g., sda, sdb, nvme0n1): " DISK_NAME
    DISK_NAME="${DISK_NAME#/dev/}"
    TARGET_DISK="/dev/${DISK_NAME}"
    [ -b "$TARGET_DISK" ] || die "Block device ${TARGET_DISK} does not exist."
}

# ---- Ask for Linux OS partition size -------------------------------------
ask_linux_size() {
    local disk_size_bytes
    disk_size_bytes=$(lsblk -nd --bytes -o SIZE "${TARGET_DISK}" 2>/dev/null | tr -d ' ' || true)
    [ -z "$disk_size_bytes" ] || [ "$disk_size_bytes" -le 0 ] && die "Could not determine disk size."
    local disk_size_gb=$(( disk_size_bytes / 1073741824 ))
    [ "$disk_size_gb" -lt 4 ] && die "Disk too small (${disk_size_gb}GB). Need at least 4GB."

    local bios_mb=1 esp_mb=512
    local remaining_bytes=$(( disk_size_bytes - (bios_mb * 1048576) - (esp_mb * 1048576) ))
    local remaining_gb=$(( remaining_bytes / 1073741824 ))

    echo -e "\n${CYAN}Disk size: ${disk_size_gb}GB | Available for Linux: ${remaining_gb}GB${NC}"

    echo -e "${YELLOW}How much space for encrypted Linux OS?${NC}"
    echo -e "  [1] Use all remaining space (recommended)"
    echo -e "  [2] Enter specific size in GB"
    read -rp "Choice [1]: " SIZE_CHOICE
    SIZE_CHOICE="${SIZE_CHOICE:-1}"

    case "$SIZE_CHOICE" in
        2)
            while true; do
                read -rp "Enter size in GB: " ARCH_SIZE_GB
                if [[ "$ARCH_SIZE_GB" =~ ^[0-9]+$ ]] && [ "$ARCH_SIZE_GB" -ge 4 ]; then
                    break
                fi
                echo -e "${RED}Size must be at least 4GB.${NC}"
            done
            ARCH_SIZE_MB=$(( ARCH_SIZE_GB * 1024 ))
            ;;
        *)
            ARCH_SIZE_MB=$(( remaining_gb * 1024 ))
            ;;
    esac

    echo -e "\n${GREEN}Encrypted OS will use: $(( ARCH_SIZE_MB / 1024 ))GB${NC}"
}

# ---- Distro selection -----------------------------------------------------
select_distros() {
    echo -e "\n${CYAN}Available distros:${NC}"
    local i=1
    for distro in "${AVAILABLE_PROFILES[@]}"; do
        local label="${PROF_LABEL[${distro}]:-${distro}}"
        echo -e "  ${GREEN}[${i}]${NC} ${label}"
        i=$(( i + 1 ))
    done
    echo -e "  ${YELLOW}[A]${NC} Select ALL distros"
    echo ""
    echo "Enter distro numbers separated by commas (e.g., 1,3,4) or 'A' for all:"
    read -rp "Choice: " DISTRO_CHOICE

    SELECTED_DISTROS=()
    if [[ "$DISTRO_CHOICE" == "A" || "$DISTRO_CHOICE" == "a" ]]; then
        SELECTED_DISTROS=("${AVAILABLE_PROFILES[@]}")
    else
        IFS=',' read -ra CHOICES <<< "$DISTRO_CHOICE"
        for choice in "${CHOICES[@]}"; do
            choice=$(echo "$choice" | tr -d ' ')
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#AVAILABLE_PROFILES[@]} ]; then
                local idx=$((choice - 1))
                SELECTED_DISTROS+=("${AVAILABLE_PROFILES[$idx]}")
            else
                warn "Invalid choice: ${choice} (skipped)"
            fi
        done
    fi

    [ ${#SELECTED_DISTROS[@]} -gt 0 ] || die "No distros selected."
    echo ""
    echo -e "${GREEN}Selected distros:${NC}"
    for distro in "${SELECTED_DISTROS[@]}"; do
        local label="${PROF_LABEL[${distro}]:-${distro}}"
        echo -e "  - ${label}"
    done
    echo ""
}

# ---- User setup -----------------------------------------------------------
setup_user() {
    echo -e "\n${CYAN}========================================${NC}"
    echo -e "${CYAN}  User Account Setup${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    while true; do
        read -rp "Enter username: " USER_NAME
        if [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && [ ${#USER_NAME} -ge 2 ]; then
            break
        fi
        echo -e "${RED}Invalid username. Use lowercase letters, numbers, underscore/hyphen, min 2 chars.${NC}"
    done

    while true; do
        read -rsp "Enter password for ${USER_NAME}: " USER_PASS; echo
        if [ ${#USER_PASS} -lt 4 ]; then
            echo -e "${RED}Password must be at least 4 characters.${NC}"
            continue
        fi
        local pass_confirm
        read -rsp "Confirm password: " pass_confirm; echo
        if [ "$USER_PASS" = "$pass_confirm" ]; then
            break
        fi
        echo -e "${RED}Passwords do not match. Please re-enter both.${NC}"
    done

    ok "User '${USER_NAME}' will be created on all selected distros."
}

# ---- Detect existing Fusion-OS deployment ---------------------------------
detect_existing_deployment() {
    local disk="$1"
    local found_luks=false
    local found_vg=false
    local deployed_distros=()
    local mapper_name="fusion_detect_$$"
    
    info "Checking ${disk} for existing Fusion-OS deployment..."
    
    # Check for LUKS on partition 3 (new layout: p1=BIOS, p2=ESP, p3=LUKS)
    # Also check partition 2 (old layout: p1=ESP, p2=LUKS) for backward compat
    local part_candidates=()
    if [[ "$disk" == *"nvme"* ]] || [[ "$disk" == *"mmcblk"* ]]; then
        part_candidates=("${disk}p3" "${disk}p2")
    else
        part_candidates=("${disk}3" "${disk}2")
    fi
    
    local part_checked=""
    for cand in "${part_candidates[@]}"; do
        if [ -b "$cand" ]; then
            local cand_type
            cand_type=$(blkid -s TYPE -o value "$cand" 2>/dev/null)
            if [ "$cand_type" = "crypto_LUKS" ] && [ "${WIPE_MODE:-}" != "all" ]; then
                found_luks=true
                part_checked="$cand"
                info "Found LUKS partition on ${cand}"
                break
            fi
        fi
    done
    
    if $found_luks; then
        # Try to open LUKS and check for LVM
        if cryptsetup isLuks "$part_checked" 2>/dev/null; then
            if [ -n "${LUKS_PASSPHRASE:-}" ]; then
                local luks_keyfile
                luks_keyfile=$(mktemp)
                chmod 600 "${luks_keyfile}"
                echo -n "${LUKS_PASSPHRASE}" > "${luks_keyfile}"
                run_logged "CRYPT-DETECT" cryptsetup open "$part_checked" "$mapper_name" --key-file "${luks_keyfile}" && {
                    if vgdisplay "${VG_NAME}" >/dev/null 2>&1; then
                        found_vg=true
                        info "Found LVM volume group: ${VG_NAME}"
                        for distro in "${AVAILABLE_PROFILES[@]}"; do
                            local lv="${LV_MAP[$distro]}"
                            if lvs "${VG_NAME}/${lv}" >/dev/null 2>&1; then
                                deployed_distros+=("$distro")
                            fi
                        done
                    fi
                    vgchange -a n "${VG_NAME}" 2>/dev/null || true
                    cryptsetup close "$mapper_name" 2>/dev/null || true
                }
                rm -f "${luks_keyfile}"
            fi
        fi
    fi
    
    # Return results via global variables
    EXISTING_LUKS=$found_luks
    EXISTING_VG=$found_vg
    DEPLOYED_DISTROS=("${deployed_distros[@]}")
    
    if $found_luks || [ ${#deployed_distros[@]} -gt 0 ]; then
        return 0  # found existing deployment
    fi
    return 1  # no existing deployment
}

# ---- Ask user what to do with existing deployment ------------------------
handle_existing_deployment() {
    local disk="$1"
    
    echo -e "\n${YELLOW}========================================================${NC}"
    echo -e "${YELLOW}  Existing Fusion-OS deployment detected!${NC}"
    echo -e "${YELLOW}========================================================${NC}"
    
    if [ ${#DEPLOYED_DISTROS[@]} -gt 0 ]; then
        echo -e "\n${CYAN}Installed distros:${NC}"
        for distro in "${DEPLOYED_DISTROS[@]}"; do
            local label="${PROF_LABEL[${distro}]:-${distro}}"
            echo -e "  - ${label}"
        done
    fi
    
    echo -e "\n${YELLOW}What would you like to do?${NC}"
    echo -e "  [1] Repair / Add More — fix or add more distros"
    echo -e "  [2] Wipe Everything — delete everything, fresh start"
    echo -e "  [3] Cancel"
    echo -e "  [4] Boot Repair — fix GRUB menu/display issues"
    read -rp "Choice [1]: " ACTION_CHOICE
    ACTION_CHOICE="${ACTION_CHOICE:-1}"
    
    case "$ACTION_CHOICE" in
        2)
            echo -e "\n${RED}WARNING: This will destroy ALL data on ${disk}!${NC}"
            read -rp "Type 'WIPE' to confirm: " WIPE_CONFIRM
            if [ "$WIPE_CONFIRM" != "WIPE" ]; then
                die "Wipe cancelled by user."
            fi
            WIPE_MODE="all"
            return 0  # proceed with fresh install
            ;;
        3)
            die "Deployment cancelled by user."
            ;;
        4)
            WIPE_MODE="boot_repair"
            return 0
            ;;
        *)
            # Restore mode
            info "Entering restore mode..."
            RESUME=1
            return 1  # signal to resume
            ;;
    esac
}

# ---- Partition helpers ----------------------------------------------------
set_partition_vars() {
    if [[ "$TARGET_DISK" == *"nvme"* ]] || [[ "$TARGET_DISK" == *"mmcblk"* ]]; then
        PART_BIOS="${TARGET_DISK}p1"
        PART_ESP="${TARGET_DISK}p2"
        PART_ROOT="${TARGET_DISK}p3"
    else
        PART_BIOS="${TARGET_DISK}1"
        PART_ESP="${TARGET_DISK}2"
        PART_ROOT="${TARGET_DISK}3"
    fi
}

# ---- Repartition helper: recreate 3 partitions (BIOS + ESP + LUKS) -------
repartition_dual() {
    info "Repartitioning: BIOS Boot + ESP + FUSION_LUKS..."

    # Recursively unmount ALL children of TARGET_DISK (incl. LVM LVs)
    for _dev in $(lsblk -l -n -o NAME "${TARGET_DISK}" 2>/dev/null || true); do
        case "$_dev" in
            ${TARGET_DISK#/dev/})
                # Skip the disk itself
                continue ;;
        esac
        # Resolve full device path (handles dm-/mapper- and partition names)
        if [ -b "/dev/mapper/$_dev" ]; then
            _full="/dev/mapper/$_dev"
        elif [ -b "/dev/$_dev" ]; then
            _full="/dev/$_dev"
        else
            continue
        fi
        _mp=$(findmnt -n -o TARGET --source "$_full" 2>/dev/null || true)
        [ -n "$_mp" ] && umount -R "$_mp" 2>/dev/null || true
    done

    # Tear down any stale LUKS/LVM on this disk
    vgchange -a n "${VG_NAME}" 2>/dev/null || true
    for _dm in $(dmsetup ls 2>/dev/null | grep "^${LUKS_MAPPER}" | awk '{print $1}' || true); do
        dmsetup remove --deferred "$_dm" 2>/dev/null || true
    done
    [ -e "/dev/mapper/${LUKS_MAPPER}" ] && cryptsetup close "${LUKS_MAPPER}" 2>/dev/null || true
    dmsetup remove --deferred "${LUKS_MAPPER}" 2>/dev/null || true
    udevadm settle 2>/dev/null || true
    sleep 1

    # Zero first 2MB to destroy GPT/MBR so kernel releases old partition references.
    run_logged "DD-ZERO" dd if=/dev/zero of="${TARGET_DISK}" bs=1M count=2 || true
    udevadm settle 2>/dev/null || true
    sleep 2

    # Log current kernel partition state for diagnostics
    run_logged "LSBLK" lsblk "${TARGET_DISK}" -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || true

    # Create fresh GPT header (sgdisk -n will fail without one after dd zeroed the disk)
    run_logged "SGDISK" sgdisk -o "${TARGET_DISK}" || warn "sgdisk -o had warnings (non-fatal)."

    # Partition 1: BIOS Boot (1MB, type EF02)
    local p1_start=2048
    local p1_end=$(( p1_start + 2048 - 1 ))

    # Partition 2: ESP (512MB, type EF00)
    local p2_start=$(( p1_end + 1 ))
    local p2_end=$(( p2_start + 512 * 1048576 / 512 - 1 ))

    # Partition 3: LUKS (type 8309) — user-chosen size or full remaining disk
    local p3_start=$(( p2_end + 1 ))
    if [ "${ARCH_SIZE_MB:-0}" -gt 0 ]; then
        local p3_sectors=$(( ARCH_SIZE_MB * 1048576 / 512 ))
        local p3_end=$(( p3_start + p3_sectors - 1 ))
        run_logged "SGDISK" sgdisk -n 1:${p1_start}:${p1_end} -t 1:EF02 -c 1:"BIOS" \
            -n 2:${p2_start}:${p2_end} -t 2:EF00 -c 2:"EFI" \
            -n 3:${p3_start}:${p3_end} -t 3:8309 -c 3:"FUSION_LUKS" \
            "${TARGET_DISK}" || \
            die "Failed to repartition disk."
    else
        run_logged "SGDISK" sgdisk -n 1:${p1_start}:${p1_end} -t 1:EF02 -c 1:"BIOS" \
            -n 2:${p2_start}:${p2_end} -t 2:EF00 -c 2:"EFI" \
            -n 3:${p3_start}:0 -t 3:8309 -c 3:"FUSION_LUKS" \
            "${TARGET_DISK}" || \
            die "Failed to repartition disk."
    fi

    udevadm settle 2>/dev/null || true
    sleep 2

    # Re-read partition table — try partx first (BLKPG, more resilient)
    run_logged "PARTX" partx -u "${TARGET_DISK}" || \
        run_logged "PARTX" partx -a "${TARGET_DISK}" || true
    udevadm settle 2>/dev/null || true
    sleep 2

    # Fallback: force-create partition devices via partx -d + -a
    if [ ! -b "${PART_ESP}" ] || [ ! -b "${PART_ROOT}" ]; then
        run_logged "PARTX" partx -d --nr 1-4 "${TARGET_DISK}" || true
        run_logged "PARTX" partx -a "${TARGET_DISK}" || true
        udevadm settle 2>/dev/null || true
        sleep 2
    fi

    # Log final partition state for diagnostics
    run_logged "LSBLK" lsblk "${TARGET_DISK}" -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || true

    [ -b "${PART_ESP}" ] || die "ESP partition ${PART_ESP} not available after repartition."
    [ -b "${PART_ROOT}" ] || die "LUKS partition ${PART_ROOT} not available after repartition."

    # Format ESP as FAT32 so it can be mounted and used for GRUB
    mkfs.vfat -F32 "${PART_ESP}" || die "Failed to format ESP as FAT32."

    ok "Repartition complete."
}

# ---- Step 1: Create LUKS2 + LVM ------------------------------------------
step_setup_luks_lvm() {
    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}[1/6] Creating LUKS2 encrypted container + LVM${NC}"
    echo -e "${CYAN}========================================================${NC}"

    set_partition_vars

    local needs_repartition=false
    local p3_size_bytes p3_size_mb

    if [ -b "${PART_ROOT}" ]; then
        p3_size_bytes=$(blockdev --getsize64 "${PART_ROOT}" 2>/dev/null || true)
        p3_size_mb=$(( ${p3_size_bytes:-0} / 1048576 ))
        if [ "$p3_size_mb" -lt 16 ]; then
            needs_repartition=true
        elif [ "${WIPE_MODE:-}" = "all" ] && [ "${ARCH_SIZE_MB:-0}" -gt 0 ]; then
            # Force repartition if user requested full wipe with a specific size
            local diff=$(( p3_size_mb - ARCH_SIZE_MB ))
            [ "${diff#-}" -gt 1024 ] && needs_repartition=true
        fi
    else
        needs_repartition=true
    fi

    if $needs_repartition; then
        warn "Partition ${PART_ROOT} missing or too small. Repartitioning..."

        vgchange -a n "${VG_NAME}" 2>/dev/null || true
        cryptsetup close "${LUKS_MAPPER}" 2>/dev/null || true

        repartition_dual

        p3_size_bytes=$(blockdev --getsize64 "${PART_ROOT}" 2>/dev/null || true)
        p3_size_mb=$(( ${p3_size_bytes:-0} / 1048576 ))
        [ "$p3_size_mb" -lt 16 ] && die "Partition ${PART_ROOT} still too small (${p3_size_mb}MB). Check disk layout."
    fi

    info "LUKS partition ${PART_ROOT}: ${p3_size_mb}MB"

    # Check if LUKS is already formatted
    local part_type
    part_type=$(blkid -s TYPE -o value "${PART_ROOT}" 2>/dev/null)
    
    if [ "$part_type" = "crypto_LUKS" ] && [ "${WIPE_MODE:-}" != "all" ]; then
        info "LUKS2 container already exists on ${PART_ROOT}."
        # Open existing LUKS container
        if [ -e "/dev/mapper/${LUKS_MAPPER}" ]; then
            info "LUKS container already open."
        else
            info "Opening existing LUKS container..."
            if [ -n "${NONINTERACTIVE:-}" ]; then
                [ -z "${LUKS_PASSPHRASE:-}" ] && die "NONINTERACTIVE mode requires LUKS_PASSPHRASE."
                local luks_keyfile
                luks_keyfile=$(mktemp)
                chmod 600 "${luks_keyfile}"
                echo -n "${LUKS_PASSPHRASE}" > "${luks_keyfile}"
                cryptsetup open "${PART_ROOT}" "${LUKS_MAPPER}" --key-file "${luks_keyfile}" || \
                    die "Failed to open LUKS container."
                rm -f "${luks_keyfile}"
            else
                cryptsetup open "${PART_ROOT}" "${LUKS_MAPPER}" || \
                    die "Failed to open LUKS container."
            fi
        fi
        LUKS_UUID=$(blkid -s UUID -o value "${PART_ROOT}")
        [ -n "${LUKS_UUID}" ] || die "Failed to get LUKS UUID after opening container."
        ok "LUKS2 container opened (UUID: ${LUKS_UUID})."
    else
        # Aggressively tear down any remaining LVM/LUKS from previous runs
        # Unmount any mounts on the LUKS mapper's LVs
        for _dm in $(dmsetup ls 2>/dev/null | grep "^${LUKS_MAPPER}" | awk '{print $1}' || true); do
            findmnt -rn -o TARGET -S "/dev/mapper/${_dm}" 2>/dev/null | \
                while read -r mp; do umount -R "$mp" 2>/dev/null || true; done || true
        done
        # Remove device-mapper devices from leaf to root (LV → VG → LUKS)
        dmsetup ls 2>/dev/null | grep "^${LUKS_MAPPER}" | awk '{print $1}' | sort -r | \
            while read -r dm; do dmsetup remove --deferred "$dm" 2>/dev/null || true; done || true
        # Final close via cryptsetup if dmsetup missed it
        [ -e "/dev/mapper/${LUKS_MAPPER}" ] && cryptsetup close "${LUKS_MAPPER}" 2>/dev/null || true
        dmsetup remove --deferred "${LUKS_MAPPER}" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        sleep 1
        wipefs -af "${PART_ROOT}" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        sleep 1
        info "Formatting ${PART_ROOT} as LUKS2..."

        local luks_passphrase luks_passphrase_confirm
        if [ -n "${NONINTERACTIVE:-}" ]; then
            luks_passphrase="${LUKS_PASSPHRASE:-}"
            [ -z "${luks_passphrase}" ] && die "NONINTERACTIVE mode requires LUKS_PASSPHRASE."
        else
            echo -e "${YELLOW}Set the MASTER DECRYPTION PASSWORD for your portable OS:${NC}"
            while true; do
                read -r -s -p "Enter passphrase: " luks_passphrase; echo
                [ ${#luks_passphrase} -ge 4 ] && break
                echo -e "${RED}Passphrase must be at least 4 characters.${NC}"
            done
            read -r -s -p "Confirm passphrase: " luks_passphrase_confirm; echo
            if [ "$luks_passphrase" != "$luks_passphrase_confirm" ]; then
                die "Passphrases do not match."
            fi
        fi

        local luks_keyfile
        luks_keyfile=$(mktemp)
        chmod 600 "${luks_keyfile}"
        echo -n "${luks_passphrase}" > "${luks_keyfile}"
        run_logged "CRYPTSETUP" cryptsetup luksFormat --type luks2 --pbkdf argon2id --batch-mode --key-file "${luks_keyfile}" "${PART_ROOT}" || \
            die "LUKS2 format failed."
        unset luks_passphrase luks_passphrase_confirm

        info "Opening LUKS container..."
        run_logged "CRYPTSETUP" cryptsetup open "${PART_ROOT}" "${LUKS_MAPPER}" --key-file "${luks_keyfile}" || \
            die "Failed to open LUKS container."
        rm -f "${luks_keyfile}"

        LUKS_UUID=$(blkid -s UUID -o value "${PART_ROOT}")
        [ -n "${LUKS_UUID}" ] || die "Failed to get LUKS UUID after formatting."
        ok "LUKS2 container created (UUID: ${LUKS_UUID})."
    fi

    # ---- LVM setup: clean up any stale VG from previous deployment, then create fresh
    # Since we repartitioned p3, any old VG on the previous p3 is invalid
    if vgdisplay "${VG_NAME}" >/dev/null 2>&1; then
        info "Removing stale volume group '${VG_NAME}' from previous deployment..."
        vgchange -a n "${VG_NAME}" 2>/dev/null || true
        # Remove all LVs first
        local existing_lvs
        existing_lvs=$(lvs "${VG_NAME}" --noheadings -o name 2>/dev/null | tr -d ' ' || true)
        for lv_name in $existing_lvs; do
            lvremove -f "${VG_NAME}/${lv_name}" 2>/dev/null || true
        done
        vgremove -f "${VG_NAME}" 2>/dev/null || true
        # Remove stale PV
        pvremove -f "/dev/mapper/${LUKS_MAPPER}" 2>/dev/null || true
    fi

    info "Setting up LVM (Volume Group: ${VG_NAME})..."
    pvcreate "/dev/mapper/${LUKS_MAPPER}" || die "pvcreate failed."
    vgcreate "${VG_NAME}" "/dev/mapper/${LUKS_MAPPER}" || die "vgcreate failed."

    local vg_free_mb
    vg_free_mb=$(vgs "${VG_NAME}" --noheadings --nosuffix --units m -o vg_free 2>/dev/null \
                 | awk '{print int($1)}' || echo "${ARCH_SIZE_MB}")
    ok "LVM volume group '${VG_NAME}' ready. Free space: ${vg_free_mb}MB ($(( vg_free_mb / 1024 ))GB)"

    # Temp mount base for bootstrapping
    MNT_ROOT=$(mktemp -d)
    cleanup_dirs+=("${MNT_ROOT}")
    save_state 1
}

# ---- Helper: get free VG space in MB ------------------------------------
get_vg_free_mb() {
    local raw free
    raw=$(vgs "${VG_NAME}" --noheadings --nosuffix --units m -o vg_free 2>&1) || true
    free=$(echo "$raw" | awk '{print int($1)}') || true
    echo "${free:-0}"
}

# ---- Helper: create LV + format for a single distro --------------------
create_distro_lv() {
    local distro="$1"
    local lv="${LV_MAP[$distro]}"
    local vg_free_mb
    vg_free_mb=$(get_vg_free_mb)
    
    # Debug: show what get_vg_free_mb returned
    info "VG free space reported: '${vg_free_mb}'MB"
    
    # Validate VG has space
    if ! [[ "$vg_free_mb" =~ ^[0-9]+$ ]]; then
        die "VG free space is not a number: '${vg_free_mb}'. VG '${VG_NAME}' may not exist."
    fi
    if [ "$vg_free_mb" -le 0 ]; then
        die "No free space in VG '${VG_NAME}'. Free: ${vg_free_mb}MB."
    fi
    
    vg_free_mb=$(( vg_free_mb > 32 ? vg_free_mb - 32 : vg_free_mb ))

    if [ "$vg_free_mb" -lt 4096 ]; then
        die "Not enough free space in VG for ${distro} (${vg_free_mb}MB < 4GB)."
    fi

    local alloc_mb
    local free_gb=$(( vg_free_mb / 1024 ))
    
    if [ -z "${NONINTERACTIVE:-}" ]; then
        echo -e "\n${CYAN}Available space for ${distro}: ${free_gb}GB${NC}"
        echo -e "${YELLOW}How much space for this distro?${NC}"
        echo -e "  [1] Use all remaining space"
        echo -e "  [2] Enter specific size in GB"
        read -rp "Choice [1]: " LV_CHOICE
        LV_CHOICE="${LV_CHOICE:-1}"
        
        case "$LV_CHOICE" in
            2)
                while true; do
                    read -rp "Enter size in GB: " LV_SIZE_GB
                    if [[ "$LV_SIZE_GB" =~ ^[0-9]+$ ]] && [ "$LV_SIZE_GB" -ge 4 ] && [ "$LV_SIZE_GB" -le "$free_gb" ]; then
                        break
                    fi
                    echo -e "${RED}Size must be between 4GB and ${free_gb}GB.${NC}"
                done
                alloc_mb=$(( LV_SIZE_GB * 1024 ))
                ;;
            *)
                alloc_mb="$vg_free_mb"
                ;;
        esac
    else
        alloc_mb="$vg_free_mb"
    fi

    info "Creating LV for ${distro} (${alloc_mb}MB)..."
    run_logged "LVCREATE" lvcreate -L "${alloc_mb}M" -n "${lv}" "${VG_NAME}" || \
        { warn "Exact-size LV failed, trying 100%FREE..."; \
          run_logged "LVCREATE" lvcreate -l "100%FREE" -n "${lv}" "${VG_NAME}" || \
          die "Failed to create ${distro} LV."; }

    info "Formatting /dev/${VG_NAME}/${lv} as Ext4 (no journal)..."
    mkfs.ext4 -O "^has_journal" -F "/dev/${VG_NAME}/${lv}" || die "Failed to format ${lv}."
    ok "LV '${lv}' created and formatted."
}

# ---- Helper: bootstrap + configure a single distro ---------------------
bootstrap_single_distro() {
    local distro="$1"
    local lv="${LV_MAP[$distro]}"
    local root_mnt="${MNT_ROOT}/${distro}"
    local kernel="${PROF_KERNEL[$distro]}"
    local extra="${PROF_EXTRA_PKGS[$distro]:-}"
    local preset="${PROF_MKINITCPIO_PRESET[$distro]}"

    info "Bootstrapping ${distro} (kernel: ${kernel})..."

    mkdir -p "${root_mnt}"
    mount "/dev/${VG_NAME}/${lv}" "${root_mnt}" || die "Failed to mount ${lv}."

    local COMMON_PKGS="base linux-firmware base-devel nano networkmanager polkit cryptsetup grub lvm2 archlinux-keyring gvfs gvfs-afc gvfs-gphoto2 gvfs-mtp gvfs-nfs gvfs-smb"
    local KERNEL_PKG="${kernel}"

    info "Generating clean pacman.conf for ${distro}..."
    local clean_pacman_conf="/tmp/clean_pacman_${distro}.conf"
    cat > "${clean_pacman_conf}" << CLEAN_CONF
[options]
HoldPkg      = pacman glibc
Architecture = auto
SigLevel     = Required DatabaseOptional
LocalFileSigLevel = Optional
ParallelDownloads = 5

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[community]
Include = /etc/pacman.d/mirrorlist
CLEAN_CONF

    info "Running pacstrap for ${distro}..."
    # shellcheck disable=SC2086
    run_logged "PACSTRAP" pacstrap -C "${clean_pacman_conf}" "${root_mnt}" base ${KERNEL_PKG} ${COMMON_PKGS} || \
        die "pacstrap failed for ${distro}."
    rm -f "${clean_pacman_conf}"

    ok "${distro}: base system installed."

    # Generate fstab
    info "Generating fstab for ${distro}..."
    genfstab -U "${root_mnt}" > "${root_mnt}/etc/fstab" 2>/dev/null || \
        warn "fstab generation failed for ${distro}."
    ok "${distro}: fstab generated."

    # ---- Add distro-specific repo BEFORE installing extra pkgs ----
    # This ensures packages from the distro repo are available
    if [ "${distro}" != "arch" ]; then
        local keyring_url="${PROF_KEYRING_URL[${distro}]:-}"
        if [ -n "${keyring_url}" ]; then
            info "Installing ${distro} keyring..."
            local keyring_file="/tmp/${distro}-keyring.pkg.tar.zst"
            run_logged "CURL" retry curl -#L --connect-timeout 30 --max-time 120 -o "${keyring_file}" "${keyring_url}" || \
                warn "Failed to download ${distro} keyring."
            if [ -f "${keyring_file}" ]; then
                cp "${keyring_file}" "${root_mnt}/tmp/"
                run_logged "PACMAN-KEYRING" arch-chroot "${root_mnt}" /bin/bash -c "pacman -U --noconfirm /tmp/${distro}-keyring.pkg.tar.zst" || \
                    warn "Failed to install ${distro} keyring."
                rm -f "${keyring_file}"
            fi
        fi

        local repo_conf="${PROF_REPO_CONF[${distro}]:-}"
        if [ -n "${repo_conf}" ]; then
            echo -e "${repo_conf}" >> "${root_mnt}/etc/pacman.conf"
            ok "${distro}: repo added to pacman.conf."
        fi

        local pgp_key="${PROF_KEYRING_PGP[${distro}]:-}"
        if [ -n "${pgp_key}" ]; then
            run_logged "PGP-KEY" arch-chroot "${root_mnt}" /bin/bash -c \
                "pacman-key --recv-keys ${pgp_key} && pacman-key --lsign-key ${pgp_key}" || \
                warn "PGP key import/trust failed for ${distro}."
        fi

        # Refresh pacman cache with new repos
        run_logged "PACMAN-REFRESH" arch-chroot "${root_mnt}" /bin/bash -c "pacman -Sy --noconfirm" || \
            warn "Failed to refresh pacman cache for ${distro}."
    fi

    # ---- Install EXTRA_PKGS (distro-specific packages from their repos) ----
    if [ -n "${extra}" ]; then
        info "Installing extra packages for ${distro}: ${extra}"
        # shellcheck disable=SC2086
        run_logged "PACMAN-EXTRA" arch-chroot "${root_mnt}" /bin/bash -c "pacman -S --noconfirm ${extra}" || \
            warn "Failed to install some extra packages for ${distro}."
    fi

    # ---- Remove packages if specified ----
    local remove_pkgs="${PROF_REMOVE_PKGS[${distro}]:-}"
    if [ -n "${remove_pkgs}" ]; then
        info "Removing packages from ${distro}: ${remove_pkgs}"
        # shellcheck disable=SC2086
        run_logged "PACMAN-REMOVE" arch-chroot "${root_mnt}" /bin/bash -c "pacman -Rns --noconfirm ${remove_pkgs}" || \
            warn "Failed to remove some packages from ${distro}."
    fi

    # ---- Configure distro inside chroot ----
    info "Configuring ${distro} (locale, network, initramfs)..."
    local root_pass
    root_pass=$(random_password)

    local chroot_script
    chroot_script=$(mktemp)
    cat > "${chroot_script}" << 'CHROOT_SCRIPT'
set -e
ln -sf /usr/share/zoneinfo/TIMEZONE_PLACEHOLDER /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "HOSTNAME_PLACEHOLDER" > /etc/hostname
echo "root:ROOT_PASS_PLACEHOLDER" | chpasswd
useradd -m -G wheel -s /bin/bash "USER_NAME_PLACEHOLDER"
echo "USER_NAME_PLACEHOLDER:USER_PASS_PLACEHOLDER" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
systemctl enable NetworkManager
sed -i 's/^#issue_discards = 0/issue_discards = 1/' /etc/lvm/lvm.conf 2>/dev/null || true
systemctl enable fstrim.timer
sed -i 's/^MODULES=()/MODULES=(usb_storage usbhid xhci_pci ehci_pci)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev keyboard autodetect modconf block encrypt lvm2 filesystems fsck)/' /etc/mkinitcpio.conf
CHROOT_SCRIPT
    sed -i "s|TIMEZONE_PLACEHOLDER|${TIMEZONE}|g; s|HOSTNAME_PLACEHOLDER|fusion-${distro}|g; s|ROOT_PASS_PLACEHOLDER|${root_pass}|g; s|USER_NAME_PLACEHOLDER|${USER_NAME}|g; s|USER_PASS_PLACEHOLDER|${USER_PASS}|g" "${chroot_script}"
    cp "${chroot_script}" "${root_mnt}/root/chroot_setup.sh"
    arch-chroot "${root_mnt}" /bin/bash /root/chroot_setup.sh
    rm -f "${chroot_script}" "${root_mnt}/root/chroot_setup.sh"

    # ---- Run post-install hooks (bash commands executed in chroot) ----
    local post_hooks="${PROF_POST_INSTALL_HOOKS[${distro}]:-}"
    if [ -n "${post_hooks}" ]; then
        info "Running post-install hooks for ${distro}..."
        run_logged "POST-HOOKS" arch-chroot "${root_mnt}" /bin/bash -c "${post_hooks}" || \
            warn "Post-install hooks failed for ${distro}."
    fi

    # ---- First-boot network setup helper ----
    mkdir -p "${root_mnt}/etc/profile.d"
    cat > "${root_mnt}/etc/profile.d/fusion-network.sh" << 'FNS'
FUSION_NET_CHECK=$(LANG=C nmcli -t -f STATE g 2>/dev/null | grep -c 'connected' || true)
if [ "$FUSION_NET_CHECK" -eq 0 ] && [ -z "${FUSION_NET_MSG_SHOWN:-}" ]; then
    export FUSION_NET_MSG_SHOWN=1
    echo ""
    echo "============================================"
    echo "  Fusion-OS — Network Setup Required"
    echo "============================================"
    echo ""
    echo "  Your system is not connected to the network."
    echo ""
    echo "  To configure WiFi, run:"
    echo "    nmtui"
    echo ""
    echo "  Or use the command line:"
    echo "    nmcli device wifi list"
    echo "    nmcli device wifi connect <SSID> password <password>"
    echo ""
    echo "  For wired (Ethernet) connections, just plug in the cable."
    echo "============================================"
    echo ""
fi
unset FUSION_NET_CHECK
FNS

    cat > "${root_mnt}/etc/motd" << 'MOTD'

======================================================================
  Welcome to Fusion-OS!
======================================================================
  Network not working?  Run:  nmtui
  Check status:               nmcli
  List WiFi:                  nmcli device wifi list
  Connect to WiFi:            nmcli device wifi connect <SSID> password <password>
======================================================================

MOTD

    # ---- Generate initramfs ----
    info "Generating initramfs for ${distro}..."
    run_logged "MKINITCPIO" arch-chroot "${root_mnt}" /bin/bash -c "mkinitcpio -p ${preset}" || \
        die "mkinitcpio failed for ${distro}."

    # ---- Save credentials ----
    cat > "${root_mnt}/root/fusion_credentials.txt" << CRED_EOF
Fusion-OS ${distro}
================
User:     ${USER_NAME}
Password: ${USER_PASS}
Root:     ${root_pass}

sudo: wheel group enabled (use 'sudo' prefix)
CRED_EOF
    chmod 600 "${root_mnt}/root/fusion_credentials.txt"

    umount "${root_mnt}"
    ok "${distro}: deployment complete."
}

# ---- Ask whether to deploy another Linux --------------------------------
ask_deploy_another() {
    local vg_free_mb
    vg_free_mb=$(get_vg_free_mb)
    local vg_free_gb=$(( vg_free_mb / 1024 ))

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}  First Linux distro deployed successfully!${NC}"
    echo -e "${CYAN}========================================================${NC}"
    echo -e "\n${YELLOW}Remaining free space in encrypted volume: ${vg_free_gb}GB${NC}"

    if [ "$vg_free_gb" -lt 4 ]; then
        warn "Not enough space to deploy another Linux (< 4GB)."
        return 1
    fi

    echo -e "${YELLOW}Deploy another Linux distro?${NC}"
    echo -e "  [Y] Yes — deploy another distro"
    echo -e "  [N] No — finish deployment"
    read -rp "Choice [Y]: " ANOTHER_CHOICE
    ANOTHER_CHOICE="${ANOTHER_CHOICE:-Y}"

    if [[ "$ANOTHER_CHOICE" == "N" || "$ANOTHER_CHOICE" == "n" ]]; then
        return 1
    fi
    return 0
}

# NOTE: step_bootstrap_distros() was removed — it was dead code that duplicated
# bootstrap_single_distro(). The main() loop calls create_distro_lv() +
# bootstrap_single_distro() directly for each distro.

# ---- Write a unified GRUB config to the given path -----------------------
write_grub_cfg() {
    local output_path="$1"
    cat > "${output_path}" << GRUB_CFG
# Project Fusion-OS v${VERSION} — Unified Boot Menu
set timeout=30
set default=0

insmod part_gpt
insmod cryptodisk
insmod luks2
insmod lvm
insmod ext2
insmod fat
insmod gzio

echo "========================================="
echo "   Fusion-OS Encrypted Workstation"
echo "========================================="
echo "Please enter your LUKS decryption password:"
# cryptomount -u requires UUID WITHOUT dashes
# NOTE: GRUB does not support \$? — use inline if/then/else syntax
if cryptomount -u ${LUKS_UUID_NODASH}; then
    insmod lvm
    echo ""
    echo "LUKS unlocked. Loading distro menu..."
else
    echo ""
    echo "ERROR: LUKS unlock failed!"
    echo "Check your passphrase and try again."
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
fi
${grub_entries}
menuentry "Reboot" {
    reboot
}

menuentry "Shutdown" {
    halt
}
GRUB_CFG
}

# ---- Step 3: Generate unified GRUB config + standalone GRUB EFI ---------
step_generate_grub() {
    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}[3/6] Generating unified GRUB config with ${#SELECTED_DISTROS[@]} distro entries${NC}"
    echo -e "${CYAN}========================================================${NC}"

    # Collect filesystem UUIDs for each selected distro's LV
    declare -A FS_UUIDS
    for distro in "${SELECTED_DISTROS[@]}"; do
        local lv="${LV_MAP[$distro]}"
        FS_UUIDS[$distro]=$(blkid -s UUID -o value "/dev/${VG_NAME}/${lv}" 2>/dev/null)
        [ -n "${FS_UUIDS[$distro]}" ] || die "Could not get UUID for LV ${distro}."
    done

    # GRUB cryptomount -u requires UUID WITHOUT dashes (32 hex chars, no separators)
    local LUKS_UUID_NODASH="${LUKS_UUID//-/}"
    info "LUKS UUID: ${LUKS_UUID}  (no-dash: ${LUKS_UUID_NODASH})"

    local ESP_UUID
    ESP_UUID=$(blkid -s UUID -o value "${PART_ESP}" 2>/dev/null || true)

    # Mount Arch LV (first selected) to write master GRUB config
    local first_distro="${SELECTED_DISTROS[0]}"
    local first_lv="${LV_MAP[$first_distro]}"
    local first_mnt="${MNT_ROOT}/grub_first"
    mkdir -p "${first_mnt}"
    mount "/dev/${VG_NAME}/${first_lv}" "${first_mnt}" || die "Failed to mount ${first_distro} LV for GRUB config."
    mkdir -p "${first_mnt}/boot/grub"

    # Build dynamic GRUB menu entries
    local grub_entries=""
    for distro in "${SELECTED_DISTROS[@]}"; do
        local lv="${LV_MAP[$distro]}"
        local kernel="${PROF_KERNEL[$distro]}"
        local label="${PROF_LABEL[$distro]}"
        local vmlinuz="/boot/vmlinuz-${kernel}"
        local initrd="/boot/initramfs-${kernel}.img"

        local boot_params="${PROF_BOOT_PARAMS[$distro]:-}"
        grub_entries+="
menuentry \"${label}\" --class ${distro} {
    search --no-floppy --fs-uuid --set=root ${FS_UUIDS[$distro]}
    echo \"Booting ${label}...\"
    linux ${vmlinuz} cryptdevice=UUID=${LUKS_UUID}:${LUKS_MAPPER}:allow-discards root=/dev/${VG_NAME}/${lv} rw rd.luks.uuid=${LUKS_UUID} rd.lvm.vg=${VG_NAME} ${boot_params}
    initrd ${initrd}
}
"
    done

    write_grub_cfg "${first_mnt}/boot/grub/grub.cfg"

    ok "Unified GRUB config written to ${first_distro} LV."

    # Replicate to all selected distros so each can boot independently
    info "Replicating GRUB config to all selected distros..."
    for distro in "${SELECTED_DISTROS[@]}"; do
        local lv="${LV_MAP[$distro]}"
        [ "${lv}" = "${first_lv}" ] && continue
        local mnt="${MNT_ROOT}/repl_${distro}"
        mkdir -p "${mnt}"
        mount "/dev/${VG_NAME}/${lv}" "${mnt}" 2>/dev/null || \
            { warn "Failed to mount ${lv} for GRUB config replication."; continue; }
        mkdir -p "${mnt}/boot/grub"
        cp "${first_mnt}/boot/grub/grub.cfg" "${mnt}/boot/grub/grub.cfg"
        umount "${mnt}"
        rmdir "${mnt}" 2>/dev/null || true
    done

    # ---- Build standalone GRUB EFI with embedded modules -------------------
    # By embedding all modules directly in the EFI binary, no dynamic
    # module loading from disk is needed, eliminating version conflicts.
    info "Building standalone GRUB EFI image with embedded crypto modules..."

    local grub_build_dir
    grub_build_dir=$(mktemp -d)
    cleanup_dirs+=("${grub_build_dir}")

    mkdir -p "${grub_build_dir}/boot/grub"

    # Re-generate grub.cfg for the standalone image (same content)
    write_grub_cfg "${grub_build_dir}/boot/grub/grub.cfg"

    # Build the standalone GRUB EFI image with all necessary modules embedded
    local standalone_efi="${grub_build_dir}/fusion-os-grub-standalone.efi"
    local grub_build_log="/tmp/grub_build.log"
    if command -v grub-mkstandalone &>/dev/null; then
        run_logged "GRUB-MKSTANDALONE" grub-mkstandalone \
            --format=x86_64-efi \
            --output="${standalone_efi}" \
            --locales="" \
            --fonts="" \
            --modules="part_gpt part_msdos normal test boot linux configfile loopback chain \
                       luks2 cryptodisk lvm ext2 fat gzio reboot halt efifwsetup" \
            "boot/grub/grub.cfg=${grub_build_dir}/boot/grub/grub.cfg" || \
            warn "grub-mkstandalone (host) failed. Log follows."
        # Also write to the dedicated build log for detailed inspection
        if [ -f "${standalone_efi}" ]; then
            rm -f "${grub_build_log}"
        else
            echo "$(log_ts) [GRUB-MKSTANDALONE] Host build failed" >> "${grub_build_log}"
        fi
    fi

    # Fallback: build inside chroot if host grub-mkstandalone is unavailable or failed
    if [ ! -f "${standalone_efi}" ]; then
        info "Trying grub-mkstandalone inside chroot..."
        local chroot_build="${MNT_ROOT}/grub_build"
        mkdir -p "${chroot_build}"
        mount "/dev/${VG_NAME}/${first_lv}" "${chroot_build}" 2>/dev/null || true
        if mountpoint -q "${chroot_build}" 2>/dev/null; then
                mkdir -p "${chroot_build}/tmp/grub_build"
                cp "${grub_build_dir}/boot/grub/grub.cfg" "${chroot_build}/tmp/grub_build/grub.cfg"
                run_logged "GRUB-MKSTANDALONE" arch-chroot "${chroot_build}" /bin/bash -c "
                    grub-mkstandalone \
                        --format=x86_64-efi \
                        --output=/tmp/grub_build/fusion-os-grub-standalone.efi \
                        --locales='' \
                        --fonts='' \
                        --modules='part_gpt part_msdos normal test boot linux configfile loopback chain luks2 cryptodisk lvm ext2 fat gzio reboot halt efifwsetup' \
                        'boot/grub/grub.cfg=/tmp/grub_build/grub.cfg' \
                        2>&1
                " && ok "Standalone GRUB EFI built inside chroot." || \
                    warn "grub-mkstandalone (chroot) also failed."
            cp "${chroot_build}/tmp/grub_build/fusion-os-grub-standalone.efi" "${standalone_efi}" 2>/dev/null || true
            umount "${chroot_build}" 2>/dev/null || true
            rmdir "${chroot_build}" 2>/dev/null || true
        fi
    fi

    if [ -f "${standalone_efi}" ]; then
        # Copy standalone EFI to /boot/grub/ on every distro LV
        # so it's available regardless of which distro is mounted
        STANDALONE_GRUB_EFI=""
        for distro in "${SELECTED_DISTROS[@]}"; do
            local lv="${LV_MAP[$distro]}"
            local mnt_efi="${MNT_ROOT}/standalone_${distro}"
            mkdir -p "${mnt_efi}"
            if mount "/dev/${VG_NAME}/${lv}" "${mnt_efi}" 2>/dev/null; then
                mkdir -p "${mnt_efi}/boot/grub"
                cp "${standalone_efi}" "${mnt_efi}/boot/grub/fusion-os-grub-standalone.efi"
                if [ "${lv}" = "${first_lv}" ]; then
                    STANDALONE_GRUB_EFI="${mnt_efi}/boot/grub/fusion-os-grub-standalone.efi"
                fi
                umount "${mnt_efi}"
            fi
            rmdir "${mnt_efi}" 2>/dev/null || true
        done
        STANDALONE_GRUB_EFI_SIZE=$(stat -c%s "${standalone_efi}" 2>/dev/null || echo "0")
        ok "Standalone GRUB EFI built and replicated: ${STANDALONE_GRUB_EFI_SIZE} bytes"
    else
        STANDALONE_GRUB_EFI=""
        warn "Could not build standalone GRUB EFI. GRUB will use module loading (may hit grub_memopy bug)."
        warn "Check ${grub_build_log} for details. Ensure grub-mkstandalone is available on host or in chroot."
    fi

    umount "${first_mnt}" 2>/dev/null || true
    ok "GRUB config replicated to all selected distro roots."
    save_state 3
}

# ---- Step 4: Install GRUB for UEFI + BIOS on each distro -----------------
step_configure_grub_defaults() {
    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}[4/6] Installing GRUB (UEFI+BIOS)${NC}"
    echo -e "${CYAN}========================================================${NC}"

    set_partition_vars
    local esp_mnt="${MNT_ROOT}/grub_esp"
    mkdir -p "${esp_mnt}"
    local esp_mounted=false
    if mount "${PART_ESP}" "${esp_mnt}" 2>/dev/null; then
        esp_mounted=true
        ok "ESP mounted for UEFI GRUB installation."
    else
        # ESP may exist but lack a filesystem (e.g., upgraded from older version)
        warn "Could not mount ESP. Attempting to format as FAT32..."
        run_logged "MKFS.VFAT" mkfs.vfat -F32 "${PART_ESP}" || \
            { warn "mkfs.vfat on ${PART_ESP} failed."; false; }
        if mount "${PART_ESP}" "${esp_mnt}" 2>/dev/null; then
            esp_mounted=true
            ok "ESP formatted as FAT32 and mounted."
        else
            warn "ESP mount failed entirely. UEFI GRUB will be skipped."
        fi
    fi

    for distro in "${SELECTED_DISTROS[@]}"; do
        local lv="${LV_MAP[$distro]}"
        local kernel="${PROF_KERNEL[$distro]}"
        local root_mnt="${MNT_ROOT}/grub_${distro}"
        mkdir -p "${root_mnt}"
        mount "/dev/${VG_NAME}/${lv}" "${root_mnt}" || { warn "Failed to mount ${lv}."; continue; }

        local boot_params="${PROF_BOOT_PARAMS[$distro]:-}"
        cat > "${root_mnt}/etc/default/grub" << GRUB_DEF
# Generated by Fusion-OS v${VERSION}
GRUB_DEFAULT=0
GRUB_TIMEOUT=30
GRUB_DISTRIBUTOR="Fusion-OS ${distro}"
GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3"
GRUB_CMDLINE_LINUX="cryptdevice=UUID=${LUKS_UUID}:${LUKS_MAPPER}:allow-discards root=/dev/${VG_NAME}/${lv} rw rd.luks.uuid=${LUKS_UUID} rd.lvm.vg=${VG_NAME} ${boot_params}"
GRUB_ENABLE_CRYPTODISK=y
GRUB_PRELOAD_MODULES="cryptodisk luks2 lvm ext2"
GRUB_DEF

        ok "${distro}: using unified GRUB config."

        # ---- UEFI: install GRUB x86_64-efi to ESP ----
        if $esp_mounted; then
            local distro_efi_dir="${esp_mnt}/EFI/FusionOS_${distro}"
            mkdir -p "${distro_efi_dir}"

            # The standalone EFI was persisted at /boot/grub/fusion-os-grub-standalone.efi
            # on every distro LV during step_generate_grub
            local distro_standalone_efi="${root_mnt}/boot/grub/fusion-os-grub-standalone.efi"
            if [ -f "${distro_standalone_efi}" ]; then
                # Deploy standalone GRUB EFI (modules embedded) as the primary EFI binary.
                # This avoids the grub_memopy symbol error entirely.
                cp "${distro_standalone_efi}" "${distro_efi_dir}/BOOTX64.EFI"
                # Also place a copy at the standard shim-friendly path
                cp "${distro_standalone_efi}" "${distro_efi_dir}/grubx64.efi" 2>/dev/null || true
                ok "${distro}: Standalone GRUB EFI deployed to ESP (FusionOS_${distro})."
            else
                # Fallback: traditional grub-install (may hit grub_memopy bug)
                warn "${distro}: Standalone GRUB EFI unavailable, falling back to grub-install."
                mkdir -p "${root_mnt}/boot/efi"
                mount --bind "${esp_mnt}" "${root_mnt}/boot/efi" 2>/dev/null || true

                run_logged "GRUB-UEFI" arch-chroot "${root_mnt}" /bin/bash << GRUB_INSTALL_EOF
                    mkdir -p /boot/efi/EFI/FusionOS_${distro}
                    grub-install --target=x86_64-efi \
                        --efi-directory=/boot/efi \
                        --bootloader-id=FusionOS_${distro} \
                        --boot-directory=/boot \
                        --no-nvram \
                        2>&1
GRUB_INSTALL_EOF
                ok "${distro}: GRUB UEFI installed to ESP (FusionOS_${distro})."
                umount "${root_mnt}/boot/efi" 2>/dev/null || true
                rmdir "${root_mnt}/boot/efi" 2>/dev/null || true
            fi

            # Copy our unified grub.cfg to the ESP EFI dir as well
            if [ -f "${root_mnt}/boot/grub/grub.cfg" ]; then
                cp "${root_mnt}/boot/grub/grub.cfg" "${distro_efi_dir}/grub.cfg" 2>/dev/null || true
            fi
        fi

        # ---- BIOS: install GRUB i386-pc to MBR ----
        if [ -d "${root_mnt}/usr/lib/grub/i386-pc" ]; then
            mkdir -p "${root_mnt}/boot/efi"
            mount --bind "${esp_mnt}" "${root_mnt}/boot/efi" 2>/dev/null || true

            if run_logged "GRUB-BIOS" arch-chroot "${root_mnt}" /bin/bash << GRUB_BIOS_EOF
                    grub-install --target=i386-pc \
                        --boot-directory=/boot \
                        ${TARGET_DISK} \
                        2>&1
GRUB_BIOS_EOF
            then
                ok "${distro}: GRUB i386-pc installed to MBR."
            else
                warn "${distro}: GRUB i386-pc install failed (GPT missing BIOS Boot Partition?). UEFI boot should still work."
            fi
            umount "${root_mnt}/boot/efi" 2>/dev/null || true
            rmdir "${root_mnt}/boot/efi" 2>/dev/null || true
        else
            warn "${distro}: i386-pc modules not found, BIOS boot may not work."
        fi

        umount "${root_mnt}"
        rmdir "${root_mnt}" 2>/dev/null || true
    done

    # ---- Deploy to standard UEFI fallback path (/EFI/BOOT/BOOTX64.EFI) ----
    if $esp_mounted; then
        local _first_distro="${SELECTED_DISTROS[0]}"
        local src_efi_fb="${esp_mnt}/EFI/FusionOS_${_first_distro}/BOOTX64.EFI"
        if [ -f "${src_efi_fb}" ]; then
            local efi_boot_dir="${esp_mnt}/EFI/BOOT"
            mkdir -p "${efi_boot_dir}"
            cp "${src_efi_fb}" "${efi_boot_dir}/BOOTX64.EFI"
            local src_cfg_fb="${esp_mnt}/EFI/FusionOS_${_first_distro}/grub.cfg"
            if [ -f "${src_cfg_fb}" ]; then
                cp "${src_cfg_fb}" "${efi_boot_dir}/grub.cfg" 2>/dev/null || true
            fi
            ok "Standalone GRUB EFI deployed to /EFI/BOOT/BOOTX64.EFI (UEFI fallback)."
        fi
    fi

    if $esp_mounted; then
        umount "${esp_mnt}" 2>/dev/null || true
    fi
    rmdir "${esp_mnt}" 2>/dev/null || true

    # ---- Register EFI boot entry with efibootmgr (UEFI only) ----
    if command -v efibootmgr &>/dev/null && [ -d /sys/firmware/efi ]; then
        info "Registering EFI boot entries..."
        for distro in "${SELECTED_DISTROS[@]}"; do
            local efi_path="\\EFI\\FusionOS_${distro}\\BOOTX64.EFI"
            local base_disk="${TARGET_DISK}"
            if [[ "$base_disk" == *"nvme"* ]] || [[ "$base_disk" == *"mmcblk"* ]]; then
                base_disk="${base_disk%p[0-9]*}"
            fi
            if efibootmgr --create --disk "${base_disk}" --part 2 \
                --label "FusionOS ${distro}" \
                --loader "${efi_path}" 2>/dev/null; then
                ok "NVRAM boot entry registered for ${distro}."
            else
                warn "Could not register NVRAM entry for ${distro} (non-critical)."
            fi
        done
    fi

    ok "Per-distro GRUB installed: UEFI (ESP) + BIOS (MBR)."
    save_state 4
}

# ---- Step 5: Display credentials ----------------------------------------
step_show_credentials() {
    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}[5/6] Distro credentials summary${NC}"
    echo -e "${CYAN}========================================================${NC}"

    for distro in "${SELECTED_DISTROS[@]}"; do
        local lv="${LV_MAP[$distro]}"
        local mnt="${MNT_ROOT}/cred_${distro}"
        mkdir -p "${mnt}"
        if mount "/dev/${VG_NAME}/${lv}" "${mnt}" 2>/dev/null; then
            local cred_file="${mnt}/root/fusion_credentials.txt"
            if [ -f "${cred_file}" ]; then
                echo -e "${YELLOW}${distro}:${NC}"
                cat "${cred_file}"
                echo ""
            fi
            umount "${mnt}"
            rmdir "${mnt}" 2>/dev/null || true
        fi
    done
    info "Credentials displayed above (not logged to file)."
    echo -e "${YELLOW}Please save these passwords. They are NOT recoverable!${NC}"
    save_state 5
}

# ---- Step 6: Final cleanup ----------------------------------------------
step_finalize() {
    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}[6/6] Finalizing deployment${NC}"
    echo -e "${CYAN}========================================================${NC}"

    sync

    info "Closing LVM and LUKS..."
    vgchange -a n "${VG_NAME}" 2>/dev/null || true
    cryptsetup close "${LUKS_MAPPER}" 2>/dev/null || true

    for d in "${cleanup_dirs[@]}"; do
        rmdir "$d" 2>/dev/null || true
    done

    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  PROJECT FUSION-OS v${VERSION} DEPLOYED SUCCESSFULLY!${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""
    echo -e "  ${CYAN}Boot modes:${NC}"
    echo -e "    UEFI:  USB boot → GRUB menu → unlock LUKS → select distro"
    echo -e "    BIOS:  USB boot → GRUB menu → unlock LUKS → select distro"
    echo ""
    echo -e "  ${YELLOW}Distros installed:${NC}"
    for distro in "${SELECTED_DISTROS[@]}"; do
        echo -e "    - ${distro}"
    done
    echo ""
    echo -e "  ${YELLOW}User:${NC}  ${USER_NAME}"
    echo -e "  ${YELLOW}Pass:${NC}  (saved in /root/fusion_credentials.txt per distro)"
    echo -e "${GREEN}============================================================${NC}"
    clear_state
}

# ---- Step: Boot Repair (rebuild GRUB without touching distros) -----------
step_boot_repair() {
    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}[Boot Repair] Rebuilding GRUB configuration...${NC}"
    echo -e "${CYAN}========================================================${NC}"

    set_partition_vars

    # Open LUKS if not already open (safe path — never destroys data)
    if [ ! -e "/dev/mapper/${LUKS_MAPPER}" ]; then
        if [ -b "${PART_ROOT}" ]; then
            info "Opening LUKS container..."
            run_logged "CRYPTSETUP" cryptsetup open "${PART_ROOT}" "${LUKS_MAPPER}" || \
                die "Failed to open LUKS container for repair."
        else
            die "LUKS partition ${PART_ROOT} not found."
        fi
    else
        info "LUKS container already open."
    fi

    # Activate VG if present
    if vgdisplay "${VG_NAME}" >/dev/null 2>&1; then
        vgchange -a y "${VG_NAME}" 2>/dev/null || true
        info "Volume group '${VG_NAME}' activated."
    else
        die "Volume group '${VG_NAME}' not found. Nothing to repair."
    fi

    MNT_ROOT=$(mktemp -d)
    cleanup_dirs+=("${MNT_ROOT}")

    # Get LUKS UUID
    LUKS_UUID=$(blkid -s UUID -o value "${PART_ROOT}" 2>/dev/null)
    [ -n "${LUKS_UUID}" ] || die "Could not determine LUKS UUID."

    # Detect deployed distros
    SELECTED_DISTROS=()
    for distro in "${AVAILABLE_PROFILES[@]}"; do
        local lv="${LV_MAP[$distro]}"
        if lvs "${VG_NAME}/${lv}" >/dev/null 2>&1; then
            SELECTED_DISTROS+=("$distro")
        fi
    done

    [ ${#SELECTED_DISTROS[@]} -gt 0 ] || die "No deployed distros found. Nothing to repair."

    info "Found deployed distros: ${SELECTED_DISTROS[*]}"

    # Rebuild GRUB config + standalone EFI
    step_generate_grub
    step_configure_grub_defaults

    # Show credentials
    step_show_credentials

    # Finalize (close LUKS/LVM, cleanup)
    step_finalize

    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  BOOT REPAIR COMPLETE!${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""
    echo -e "  ${CYAN}Your GRUB menu has been rebuilt with proper video support.${NC}"
    echo -e "  ${CYAN}The USB should now display the GRUB menu when booted.${NC}"
    echo ""
}

# ---- QEMU boot test ------------------------------------------------------
check_qemu_deps() {
    command -v qemu-system-x86_64 &>/dev/null || die "qemu-system-x86_64 not found. Install qemu-full or qemu-system-x86_64."
}

step_boot_test() {
    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}[QEMU Test] Booting ${TARGET_DISK} in QEMU${NC}"
    echo -e "${CYAN}========================================================${NC}"

    check_qemu_deps
    [ -b "${TARGET_DISK}" ] || die "Target disk ${TARGET_DISK} not available."

    local qemu_opts=()
    qemu_opts+=(-enable-kvm)
    qemu_opts+=(-m 4096)
    qemu_opts+=(-cpu host)
    qemu_opts+=(-smp 2)
    qemu_opts+=(-drive "format=raw,file=${TARGET_DISK},snapshot=on")
    qemu_opts+=(-boot menu=on)
    qemu_opts+=(-vga virtio)
    qemu_opts+=(-device virtio-net-pci,netdev=net0)
    qemu_opts+=(-netdev user,id=net0)
    qemu_opts+=(-usb)
    qemu_opts+=(-device usb-tablet)

    # Use serial console (nographic) — most reliable for CLI tool
    # Display backends (SDL/GTK) often fail under sudo/Wayland due to
    # missing XDG_RUNTIME_DIR and Wayland compositor root restrictions.
    qemu_opts+=(-nographic)
    qemu_opts+=(-serial mon:stdio)
    info "Using serial console (Ctrl+A X to exit QEMU)."

    # OVMF (UEFI) lookup — search common paths with and without .4m suffix
    local ovmf_code=""
    local ovmf_vars=""
    local -a ovmf_dirs=(
        /usr/share/edk2/x64
        /usr/share/edk2-ovmf/x64
        /usr/share/ovmf/x64
        /usr/share/ovmf
    )

    # Try separate CODE + VARS files first (writable NVRAM)
    for dir in "${ovmf_dirs[@]}"; do
        for suffix in ".4m" ""; do
            local code_candidate="${dir}/OVMF_CODE${suffix}.fd"
            local vars_candidate="${dir}/OVMF_VARS${suffix}.fd"
            if [ -f "$code_candidate" ] && [ -f "$vars_candidate" ]; then
                ovmf_code="$code_candidate"
                ovmf_vars="$vars_candidate"
                break 2
            fi
        done
    done

    # Fall back to combined OVMF.fd / OVMF.4m.fd
    if [ -z "$ovmf_code" ]; then
        for dir in "${ovmf_dirs[@]}"; do
            for name in "OVMF.4m.fd" "OVMF.fd"; do
                local combined="${dir}/${name}"
                if [ -f "$combined" ]; then
                    ovmf_code="$combined"
                    break 2
                fi
            done
        done
    fi

    if [ -n "$ovmf_code" ] && [ "${BOOT_MODE:-uefi}" != "bios" ]; then
        if [ -n "$ovmf_vars" ]; then
            local vars_copy
            vars_copy=$(mktemp /tmp/fusion_ovmf_vars_XXXXXX.fd)
            cp "${ovmf_vars}" "${vars_copy}"
            qemu_opts+=(-drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}")
            qemu_opts+=(-drive "if=pflash,format=raw,file=${vars_copy}")
        else
            qemu_opts+=(-bios "${ovmf_code}")
        fi
        info "Booting with UEFI (OVMF: ${ovmf_code})..."
    else
        info "Booting with BIOS (SeaBIOS)..."
    fi

    echo -e "\n${YELLOW}QEMU test session starting...${NC}"
    info "Disk: ${TARGET_DISK} (snapshot mode — no persistent writes)"
    info "RAM: 4GB | SMP: 2 cores | KVM: enabled"
    echo ""

    # Run QEMU — serial console (blocks until VM exits)
    run_logged "QEMU" qemu-system-x86_64 "${qemu_opts[@]}" || true

    # Clean up OVMF vars copy
    local vars_files
    vars_files=$(compgen -G "/tmp/fusion_ovmf_vars_*.fd" 2>/dev/null || true)
    for f in ${vars_files}; do rm -f "$f" 2>/dev/null || true; done

    ok "QEMU test session ended."
}

# ---- Step: Import host WiFi connections to all deployed distros ----------
step_import_wifi() {
    local ssid="" psk="" imported=false
    local nm_src="/etc/NetworkManager/system-connections"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${CYAN}[WiFi] Configuring network for deployed distros${NC}"
    echo -e "${CYAN}========================================================${NC}"

    # ---- Method 1: Import from host's NetworkManager ----
    if [ -d "${nm_src}" ] && [ -n "$(ls -A "${nm_src}" 2>/dev/null)" ]; then
        info "Found NetworkManager connections on host: $(ls "${nm_src}" 2>/dev/null | tr '\n' ' ')"
        cp "${nm_src}"/* "${tmp_dir}/" 2>/dev/null
        # Strip MAC/interface bindings so profiles work on any hardware
        for f in "${tmp_dir}"/*; do
            [ -f "$f" ] || continue
            sed -i '/^mac-address=/d; /^mac-address-blacklist=/d; /^interface-name=/d; /^cloned-mac-address=/d; /^generate-mac-address-mask=/d' "$f" 2>/dev/null || true
        done
        imported=true
        local file_count=0
        for _f in "${tmp_dir}"/*; do [ -f "$_f" ] && file_count=$((file_count + 1)); done
        info "Imported ${file_count} connection profile(s) from host NetworkManager."
    fi

    # ---- Method 2: Auto-detect current WiFi from any network manager ----
    if ! $imported; then
        local detected_ssid="" detected_psk=""

        # Detect SSID from any active WiFi interface
        if command -v iwgetid &>/dev/null; then
            detected_ssid=$(iwgetid -r 2>/dev/null || true)
        fi
        if [ -z "${detected_ssid}" ] && command -v iw &>/dev/null; then
            detected_ssid=$(iw dev 2>/dev/null | awk '/ssid/{print $2; exit}' || true)
        fi
        if [ -z "${detected_ssid}" ] && command -v nmcli &>/dev/null; then
            detected_ssid=$(nmcli -t -f ACTIVE,SSID device wifi 2>/dev/null | grep '^yes:' | cut -d: -f2 || true)
        fi

        if [ -n "${detected_ssid}" ]; then
            info "Detected active WiFi network: ${detected_ssid}"

            # Try to get password from wpa_supplicant.conf
            if [ -z "${detected_psk}" ] && [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
                detected_psk=$(sed -n '/network=/,/^}/p' /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null | \
                    sed -n '/ssid="'"${detected_ssid}"'"/,/^}/p' | \
                    grep 'psk=' | head -1 | cut -d= -f2 | tr -d '"' || true)
            fi

            # Try to get password from NetworkManager (if available on host but no config files)
            if [ -z "${detected_psk}" ] && command -v nmcli &>/dev/null; then
                detected_psk=$(nmcli -s -f 802-11-wireless-security.psk connection show "${detected_ssid}" 2>/dev/null || true)
            fi

            if [ -n "${detected_psk}" ]; then
                ssid="${detected_ssid}"
                psk="${detected_psk}"
                imported=true
                ok "Auto-detected WiFi credentials for: ${ssid}"
            fi
        fi
    fi

    # ---- Method 3: Ask user interactively ----
    if ! $imported && [ -z "${NONINTERACTIVE:-}" ]; then
        echo ""
        echo -e "${YELLOW}No existing WiFi config found on this host.${NC}"
        echo -e "${YELLOW}Enter WiFi credentials to pre-configure all deployed distros:${NC}"
        echo -e "  (Press Enter at SSID to skip WiFi configuration)"
        echo ""
        read -rp "WiFi SSID: " ssid
        if [ -n "${ssid}" ]; then
            read -rsp "WiFi Password: " psk; echo
            imported=true
        fi
    fi

    # ---- Create NetworkManager connection profiles ----
    if $imported && [ -n "${ssid}" ] && [ -n "${psk}" ]; then
        local conn_uuid
        conn_uuid=$(uuidgen 2>/dev/null || head -c 32 /dev/urandom | md5sum | head -c 32 || echo "$(date +%s)$$")
        cat > "${tmp_dir}/fusion-os-wifi.nmconnection" << NMCFG
[connection]
id=${ssid}
uuid=${conn_uuid}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${ssid}
hidden=false

[wifi-security]
key-mgmt=wpa-psk
psk=${psk}

[ipv4]
method=auto

[ipv6]
method=auto
NMCFG
        chmod 600 "${tmp_dir}/fusion-os-wifi.nmconnection"
        ok "NetworkManager profile created for SSID: ${ssid}"
    fi

    # ---- Deploy to all distros ----
    local deploy_count=0
    for distro in "${SELECTED_DISTROS[@]}"; do
        local lv="${LV_MAP[$distro]}"
        local mnt="${MNT_ROOT}/wifi_${distro}"
        mkdir -p "${mnt}"
        if mount "/dev/${VG_NAME}/${lv}" "${mnt}" 2>/dev/null; then
            local nm_dst="${mnt}/etc/NetworkManager/system-connections"
            mkdir -p "${nm_dst}"
            local conn_files=("${tmp_dir}"/*)
            if [ ${#conn_files[@]} -gt 0 ] && [ -f "${conn_files[0]}" ]; then
                cp "${tmp_dir}"/* "${nm_dst}/" 2>/dev/null
                chmod 600 "${nm_dst}"/* 2>/dev/null || true
                deploy_count=$(( deploy_count + 1 ))
            fi
            umount "${mnt}"
            rmdir "${mnt}" 2>/dev/null || true
        else
            warn "${distro}: failed to mount LV, skipping WiFi config."
            rmdir "${mnt}" 2>/dev/null || true
        fi
    done
    rm -rf "${tmp_dir}"

    if [ "${deploy_count}" -gt 0 ]; then
        ok "WiFi configuration deployed to ${deploy_count} distro(s)."
    else
        info "No WiFi configuration to deploy (skipped)."
    fi
}

# ---- Main entry point ----------------------------------------------------
main() {
    echo -e "${CYAN}"
    echo "=========================================================="
    echo "      Project Fusion-OS v${VERSION} — Ultimate USB Deployer"
    echo "      Multi-distro · LUKS2 · LVM · No-journal Ext4"
    echo "=========================================================="
    echo -e "${NC}"

    check_root
    init_log
    info "Log file: ${LOG_FILE}"

    check_deps
    check_network
    optimize_mirrors

    # Parse optional CLI flags
    local RESUME=0
    local -a CLI_DISTROS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --disk DEVICE    Target disk (e.g., /dev/sdb)"
    echo "  --size MB        Space to reserve for encrypted OS (MB)"
    echo "  --distros LIST   Comma-separated distro list (e.g., arch,cachyos,manjaro)"
    echo "  --test           Boot target disk in QEMU (UEFI if available, else BIOS)"
    echo "  --test-bios      Boot target disk in QEMU (force BIOS mode)"
    echo "  --user NAME      User account name (non-interactive mode)"
    echo "  --password PASS  User account password (non-interactive mode)"
    echo "  --passphrase KEY LUKS passphrase (non-interactive mode, or use LUKS_PASSPHRASE env var)"
    echo "  --noninteractive Skip confirmations (use with --disk and --size)"
    echo "  --resume         Resume from last successful step"
    echo "  --help, -h       Show this help"
    echo ""
    echo "Interactive mode:"
    echo "  - Select target USB disk"
    echo "  - Auto-detect existing Fusion-OS deployment"
    echo "  - Restore/repair or wipe & redeploy"
    echo "  - Choose Linux OS size (GB)"
    echo "  - Deploy distros one by one"
    echo "  - Create user account"
    echo ""
    echo "Boot modes:"
    echo "  UEFI:  USB boot → GRUB → unlock LUKS → select distro"
    echo "  BIOS:  USB boot → GRUB → unlock LUKS → select distro"
                exit 0
                ;;
            --disk)
                shift; TARGET_DISK="$1"; DISK_NAME="${TARGET_DISK#/dev/}"
                [ -b "$TARGET_DISK" ] || die "Block device $TARGET_DISK not found."
                ;;
            --size)
                shift; ARCH_SIZE_MB="$1"
                [ "$ARCH_SIZE_MB" -gt 4096 ] || die "Size must be > 4096 MB."
                ;;
            --distros)
                shift
                IFS=',' read -ra CLI_DISTROS <<< "$1"
                for d in "${CLI_DISTROS[@]}"; do
                    local found=false
                    for valid in "${AVAILABLE_PROFILES[@]}"; do
                        [ "$d" = "$valid" ] && found=true && break
                    done
                    $found || die "Invalid distro: ${d}. Valid: ${AVAILABLE_PROFILES[*]}"
                done
                ;;
            --test)
                BOOT_MODE="uefi"
                QEMU_TEST=1
                ;;
            --test-bios)
                BOOT_MODE="bios"
                QEMU_TEST=1
                ;;
            --user)
                shift; USER_NAME="$1"
                ;;
            --password)
                shift; USER_PASS="$1"
                ;;
            --passphrase)
                shift; LUKS_PASSPHRASE="$1"
                ;;
            --noninteractive)
                NONINTERACTIVE=1
                ;;
            --resume)
                RESUME=1
                ;;
            *)
                die "Unknown option: $1 (use --help)"
                ;;
        esac
        shift
    done

    # QEMU test mode: boot disk and exit
    if [ -n "${QEMU_TEST:-}" ]; then
        [ -n "${TARGET_DISK}" ] || die "--test requires --disk."
        info "QEMU test mode activated for ${TARGET_DISK}."
        step_boot_test
        exit 0
    fi

    # Check for previous install state
    local start_step=1
    if [ "${RESUME}" -eq 1 ] || load_state; then
        local prev_step
        prev_step=$(get_completed_step)
        local prev_disk="${TARGET_DISK:-}"
        # Load state values if not already set by CLI flags
        if [ -f "${STATE_FILE}" ]; then
            # shellcheck disable=SC1090
            source "${STATE_FILE}"
        fi
        if [ "${prev_step}" -gt 0 ] 2>/dev/null; then
            if [ -n "${prev_disk}" ] && [ "${prev_disk}" != "${TARGET_DISK}" ]; then
                warn "State file targets ${TARGET_DISK}, but you specified ${prev_disk}. Starting fresh."
                clear_state
            else
                start_step=$(( prev_step + 1 ))
                info "Resuming from step ${start_step}/6 (completed through step ${prev_step})."
                info "Target disk: ${TARGET_DISK}, Size: ${ARCH_SIZE_MB}MB"
            fi
        fi
    fi

    # Interactive disk selection if not specified
    if [ -z "${TARGET_DISK}" ]; then
        select_disk
    fi

    [ -b "${TARGET_DISK}" ] || die "Target disk ${TARGET_DISK} not available."

    # Detect existing Fusion-OS deployment FIRST
    set_partition_vars
    if detect_existing_deployment "${TARGET_DISK}"; then
        handle_existing_deployment "${TARGET_DISK}"
        
        case "${WIPE_MODE}" in
            all)
                # Wipe everything — fresh start from step 1
                ask_linux_size
                clear_state
                start_step=1
                RESUME=0
                info "Full wipe selected — starting fresh."
                ;;
            "")
                # No wipe mode = user chose "Repair / Add More" (resume)
                RESUME=1
                clear_state
                SELECTED_DISTROS=()
                start_step=1
                info "Entering repair mode — will verify LUKS and add distros."
                ;;
            boot_repair)
                # Fix GRUB display/menu without touching distros
                step_boot_repair
                exit 0
                ;;
        esac
    else
        # No existing deployment — fresh install, ask for sizes
        ask_linux_size
    fi

    # Confirm destructive operation (skip if resuming/repair)
    if [ -z "${NONINTERACTIVE:-}" ] && [ "${RESUME}" -eq 0 ]; then
        confirm_destructive
    fi

    # Restore LUKS/LVM state if resuming from step 2+
    if [ "${start_step}" -gt 1 ]; then
        restore_disk_state
    fi

    # Auto-detect deployed distros from LVM when resuming from step 3+
    if [ "${start_step}" -gt 2 ] && [ ${#SELECTED_DISTROS[@]} -eq 0 ]; then
        info "Detecting deployed distros from LVM volume group..."
        vgchange -a y "${VG_NAME}" 2>/dev/null || true
        for distro in "${AVAILABLE_PROFILES[@]}"; do
            local lv="${LV_MAP[$distro]}"
            if lvs "${VG_NAME}/${lv}" >/dev/null 2>&1; then
                SELECTED_DISTROS+=("$distro")
                info "  Found: ${distro} (LV: ${lv})"
            fi
        done
        if [ ${#SELECTED_DISTROS[@]} -gt 0 ]; then
            ok "Detected ${#SELECTED_DISTROS[@]} deployed distro(s)."
        else
            die "No deployed distros found in VG '${VG_NAME}'. Cannot resume."
        fi
    fi

    # Step 1: LUKS+LVM
    [ "${start_step}" -le 1 ] && step_setup_luks_lvm

    # User account setup (after LUKS is ready)
    if [ -z "${USER_NAME}" ]; then
        if [ -z "${NONINTERACTIVE:-}" ]; then
            setup_user
        else
            USER_NAME="fusion"
            USER_PASS="${USER_PASS:-$(random_password)}"
            info "Non-interactive mode: using default user '${USER_NAME}' with auto-generated password."
        fi
    elif [ -n "${NONINTERACTIVE:-}" ] && [ -z "${USER_PASS}" ]; then
        USER_PASS=$(random_password)
        info "Non-interactive mode: user '${USER_NAME}' set, password auto-generated."
    fi

    # ---- Step 2: Iterative distro deployment loop ----
    if [ "${start_step}" -le 2 ]; then
        echo -e "\n${CYAN}========================================================${NC}"
        echo -e "${CYAN}[2/6] Deploying Linux distros${NC}"
        echo -e "${CYAN}========================================================${NC}"

        # Ensure VG is active
        vgchange -a y "${VG_NAME}" 2>/dev/null || true

        # Select distros (from CLI flag or interactive prompt)
        SELECTED_DISTROS=()
        if [ ${#CLI_DISTROS[@]} -gt 0 ]; then
            SELECTED_DISTROS=("${CLI_DISTROS[@]}")
            echo -e "${GREEN}Using CLI-specified distros: ${SELECTED_DISTROS[*]}${NC}"
        else
            select_distros
        fi

        local deploy_idx=0
        local total_selected=${#SELECTED_DISTROS[@]}

        while [ "$deploy_idx" -lt "$total_selected" ]; do
            local current_distro="${SELECTED_DISTROS[$deploy_idx]}"
            local label="${PROF_LABEL[$current_distro]}"

            echo -e "\n${GREEN}--- Deploying: ${label} ($(( deploy_idx + 1 ))/${total_selected}) ---${NC}"
            create_distro_lv "$current_distro"
            bootstrap_single_distro "$current_distro"
            save_state 2

            deploy_idx=$(( deploy_idx + 1 ))

            # After first distro, ask if user wants to deploy another
            if [ "$deploy_idx" -eq "$total_selected" ]; then
                if [ -z "${NONINTERACTIVE:-}" ]; then
                    if ask_deploy_another; then
                        echo ""
                        echo -e "${CYAN}Remaining distros you can deploy:${NC}"
                        local available_count=0
                        for d in "${AVAILABLE_PROFILES[@]}"; do
                            local already_done=false
                            for done_d in "${SELECTED_DISTROS[@]:0:$deploy_idx}"; do
                                [ "$d" = "$done_d" ] && already_done=true && break
                            done
                            if ! $already_done; then
                                echo -e "  ${GREEN}[${d}]${NC} ${PROF_LABEL[$d]}"
                                available_count=$(( available_count + 1 ))
                            fi
                        done
                        if [ "$available_count" -eq 0 ]; then
                            warn "All distros have been deployed."
                        else
                            echo ""
                            echo "Enter distro name to deploy (e.g., cachyos) or 'done' to finish:"
                            read -rp "Choice: " NEXT_DISTRO
                            if [ "$NEXT_DISTRO" = "done" ] || [ -z "$NEXT_DISTRO" ]; then
                                break
                            fi
                            # Validate choice
                            local valid=false
                            for d in "${AVAILABLE_PROFILES[@]}"; do
                                [ "$NEXT_DISTRO" = "$d" ] && valid=true && break
                            done
                            if $valid; then
                                SELECTED_DISTROS+=("$NEXT_DISTRO")
                                total_selected=${#SELECTED_DISTROS[@]}
                            else
                                warn "Invalid distro name: ${NEXT_DISTRO}"
                                break
                            fi
                        fi
                    fi
                else
                    break
                fi
            fi
        done

        [ ${#SELECTED_DISTROS[@]} -gt 0 ] || die "No distros were deployed."
        save_state 2
    fi

    # Import host WiFi in real-time (after all distros deployed)
    step_import_wifi

    [ "${start_step}" -le 3 ] && step_generate_grub
    [ "${start_step}" -le 4 ] && step_configure_grub_defaults
    [ "${start_step}" -le 5 ] && step_show_credentials
    [ "${start_step}" -le 6 ] && step_finalize

    # Post-deployment menu: boot test or exit
    if [ -z "${NONINTERACTIVE:-}" ] && [ "${start_step}" -le 6 ]; then
        while true; do
            echo -e "\n${CYAN}========================================================${NC}"
            echo -e "${CYAN}  Deployment complete — what next?${NC}"
            echo -e "${CYAN}========================================================${NC}"
            echo -e "  ${GREEN}[1]${NC} Boot test — launch QEMU with ${TARGET_DISK}"
            echo -e "  ${GREEN}[2]${NC} Exit"
            read -rp "Choice [2]: " POST_CHOICE
            POST_CHOICE="${POST_CHOICE:-2}"
            case "$POST_CHOICE" in
                1)
                    step_boot_test
                    echo -e "\n${YELLOW}QEMU session ended. You can test again or exit.${NC}"
                    ;;
                2)
                    echo -e "\n${GREEN}Goodbye!${NC}"
                    break
                    ;;
                *)
                    echo -e "${RED}Invalid choice.${NC}"
                    ;;
            esac
        done
    fi
}

main "$@"
