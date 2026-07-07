# Project Fusion-OS v2.0 — Installation Guide

Project Fusion-OS is a portable encrypted workstation deployer that installs Arch Linux on a single USB drive with full-disk encryption and GRUB bootloader.

## 🚀 Features

- **LUKS2 Full-Disk Encryption**: `argon2id` PBKDF with keyfile-based unlocking.
- **Dual Boot Support**: UEFI (per-distro ESP entries + fallback `/EFI/BOOT/BOOTX64.EFI`) and Legacy BIOS (i386-pc MBR) via GRUB.
- **Standalone GRUB EFI**: Embedded modules in a single binary — avoids `grub_memopy` symbol errors, no module loading from disk.
- **GRUB Cryptodisk**: Built-in LUKS2 unlock at boot menu via `cryptomount`.
- **Ext4 No-Journal**: Optimized for flash storage — reduces writes, increases USB lifespan.
- **LVM Logical Volumes**: Flexible partition layout for future multi-distro expansion.
- **Automated Configuration**: Timezone, locale, hostname, sudo/wheel, NetworkManager enable, fstrim, mkinitcpio hooks.
- **First-Boot Network Helper**: Profile script and MOTD guide users through `nmtui`/`nmcli` WiFi setup.
- **WiFi Auto-Import**: Detects host WiFi credentials from NetworkManager, `wpa_supplicant`, or interactive input and deploys to installed system.
- **Resume Support**: Tracks progress via state file — interrupted installs can be resumed from the last successful step.
- **Boot Repair Mode**: Rebuild GRUB config and standalone EFI without touching distro data.
- **QEMU Boot Test**: Built-in QEMU launcher with UEFI (OVMF) and BIOS modes, serial console, snapshot mode.
- **Interactive & Non-Interactive Modes**: Fully automated via CLI flags (`--disk`, `--size`, `--passphrase`, `--user`, `--password`, `--noninteractive`).
- **Profile System**: Modular distro configuration (kernel, extra packages, repos, keyring, boot params, post-install hooks).
- **Automatic Dependency Resolution**: Installs missing packages (`cryptsetup`, `lvm2`, `gptfdisk`, `arch-install-scripts`, etc.).
- **Mirror Optimization**: Optional `reflector` integration for fastest package downloads.
- **Network Resilience**: 3-attempt retry with 5s delay on all downloads; fallback ping/curl connectivity check.
- **Safe Cleanup**: Trap-based teardown closes LUKS, deactivates LVM, unmounts filesystems, and removes keyfiles on exit or error.
- **NVRAM Registration**: Optional `efibootmgr` boot entry creation for UEFI systems.

---

## 🛠️ Prerequisites

- An Arch Linux environment (as the script uses `pacstrap` and `arch-chroot`).
- A USB drive with sufficient space (minimum 16GB recommended).
- An active internet connection.
- Root privileges.

---

## 📖 Step-by-Step Instructions

### 1. Basic Installation (Interactive)

1. **Make the script executable**:
   ```bash
   chmod +x fusion_os_installer.sh
   ```

2. **Run the installer**:
   ```bash
   sudo ./fusion_os_installer.sh
   ```

3. **Follow the prompts**:
   - **Disk Selection**: Choose the target USB drive (e.g., `sdb`).
   - **Space Allocation**: Enter the amount of space to reserve for the encrypted OS.
   - **Confirmation**: Type `CONFIRM` to wipe the disk and begin.
   - **Encryption**: Set your Master Decryption Password when prompted.

### 2. Automated Installation (Non-Interactive)

```bash
sudo ./fusion_os_installer.sh --disk /dev/sdX --size 40960 --noninteractive \
  --passphrase "YourSecurePassword" --user fusion --password "userpass"
```

---

## 🚩 CLI Options

| Option | Description | Example |
| :--- | :--- | :--- |
| `--disk <DEVICE>` | Specify target USB disk | `--disk /dev/sdb` |
| `--size <MB>` | Space to reserve for encrypted OS | `--size 61440` |
| `--user <NAME>` | User account name (non-interactive) | `--user fusion` |
| `--password <PASS>` | User password (non-interactive) | `--password mypass` |
| `--passphrase <KEY>` | LUKS passphrase (non-interactive) | `--passphrase mykey` |
| `--noninteractive` | Skip all user prompts | `--noninteractive` |
| `--resume` | Resume from last successful step | `--resume` |
| `--test` | Boot target in QEMU (UEFI) | `--test` |
| `-h, --help` | Show help message | `-h` |

---

## 👢 Booting your Fusion-OS

1. **Insert the USB** and boot from it.
2. **Enter your LUKS passphrase** when prompted by the GRUB bootloader.
3. **Select Arch Linux** from the GRUB menu.

## Post-Installation

User credentials are saved at `/root/fusion_credentials.txt` inside the installed system.

### First Boot — WiFi Setup

NetworkManager is pre-installed and enabled. On first boot, configure WiFi with:

```bash
# List available WiFi networks
nmcli device wifi list

# Connect to a network
nmcli device wifi connect "SSID" password "password"

# Or use interactive TUI
nmtui
```

---

## ⚠️ Warning

**This script is destructive.** It will completely wipe all data on the target disk. Double-check your target device name before executing.

## 🧹 Known Issues & Security Considerations

The following items are tracked in the script header for future maintenance:

- **Passphrase in memory**: The LUKS passphrase is stored in a bash variable during setup. `unset` does not scrub the value from process memory. This is a fundamental bash limitation and not practically exploitable, but worth noting.
- **Plaintext credentials**: User and root passwords are written to `/root/fusion_credentials.txt` (chmod 600) inside each deployed distro. Consider replacing or deleting this file after first login.
- **State file**: Intermediate state is written to `/tmp/fusion_os_state_*`. The file is created with 600 permissions but resides in a world-readable directory.
- **Duplicate code**: The `cryptsetup open` logic (with NONINTERACTIVE branching) is repeated in 4 places. A future refactor should extract a shared `open_luks()` helper.
- **GRUB BIOS ESP mount**: The BIOS GRUB installation step bind-mounts the ESP even though `grub-install i386-pc` only writes to the MBR. This is harmless overhead from shared code paths.
