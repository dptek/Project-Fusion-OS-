# Project Fusion-OS v2.0 — Installation Guide

Project Fusion-OS is a portable encrypted workstation deployer that installs Arch Linux on a single USB drive with full-disk encryption and GRUB bootloader.

## Features

- **Full-Disk Encryption**: LUKS2 encryption with `argon2id` PBKDF for maximum security.
- **GRUB Bootloader**: Direct UEFI and Legacy BIOS boot via GRUB with cryptodisk support.
- **Optimized for Flash**: Uses `ext4` without journaling to increase USB lifespan and write speed.
- **Automated Configuration**: Automatic timezone, locale, and network setup.
- **Flexible Deployment**: Supports both interactive and non-interactive (automated) installation.

---

## Prerequisites

- An Arch Linux environment (as the script uses `pacstrap` and `arch-chroot`).
- A USB drive with sufficient space (minimum 16GB recommended).
- An active internet connection.
- Root privileges.

---

## Step-by-Step Instructions

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

## CLI Options

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

## Booting your Fusion-OS

1. **Insert the USB** and boot from it.
2. **Enter your LUKS passphrase** when prompted by the GRUB bootloader.
3. **Select Arch Linux** from the GRUB menu.

## Post-Installation

User credentials are saved at `/root/fusion_credentials.txt` inside the installed system.

---

## Warning

**This script is destructive.** It will completely wipe all data on the target disk. Double-check your target device name before executing.
