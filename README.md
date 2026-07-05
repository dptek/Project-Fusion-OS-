# Project Fusion-OS v2.0 — Installation Guide

Project Fusion-OS is an ultimate portable workstation deployer that installs four Arch-based distributions on a single USB drive with full-disk encryption and a GRUB-based bootloader.

## 🚀 Features

- **6-in-1 Workstation**: Deploy Arch Linux, CachyOS, Archcraft, BigLinux, Manjaro, and Mabox on one device.
- **Full-Disk Encryption**: LUKS2 encryption with `argon2id` PBKDF for maximum security.
- **Logical Volume Management (LVM)**: Separate LVs for each distro to prevent kernel/initramfs collisions.
- **GRUB Bootloader**: Direct UEFI and Legacy BIOS boot via GRUB with cryptodisk support.
- **Optimized for Flash**: Uses `ext4` without journaling to increase USB lifespan and write speed.
- **Automated Configuration**: Automatic timezone, locale, and network setup.
- **Flexible Deployment**: Supports both interactive and non-interactive (automated) installation.

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
   - **Space Allocation**: Enter the amount of space (in MB) to reserve for the encrypted OS (e.g., `40960` for 40GB).
   - **Confirmation**: Type `CONFIRM` to wipe the disk and begin.
   - **Encryption**: Set your Master Decryption Password when prompted.

### 2. Automated Installation (Non-Interactive)

For automation (CI/CD or scripting), provide the disk and size as flags and the LUKS passphrase as an environment variable.

```bash
# With environment variable for passphrase
export LUKS_PASSPHRASE="YourSecurePasswordHere"
sudo ./fusion_os_installer.sh --disk /dev/sdX --size 40960 --distros arch,cachyos,manjaro --noninteractive

# Fully self-contained (no env vars needed)
sudo ./fusion_os_installer.sh --disk /dev/sdX --size 40960 --distros arch,cachyos \
  --passphrase "YourSecurePassword" --user fusion --password "userpass" --noninteractive
```

---

## 🚩 CLI Options

| Option | Description | Example |
| :--- | :--- | :--- |
| `--disk <DEVICE>` | Specify target USB disk | `--disk /dev/sdb` |
| `--size <MB>` | Space to reserve for encrypted OS | `--size 61440` |
| `--distros <LIST>` | Comma-separated distro list | `--distros arch,cachyos` |
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
3. **Select your desired distro** from the GRUB menu (Arch, CachyOS, Archcraft, BigLinux, Manjaro, or Mabox).

## 🔑 Post-Installation

The root passwords for each distro are randomized for security. You can find them in the following location inside each distro:
`/root/fusion_credentials.txt`

---

## ⚠️ Warning
**This script is destructive.** It will completely wipe all data on the target disk. Double-check your target device name before executing.