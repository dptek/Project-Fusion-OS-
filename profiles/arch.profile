# Profile: Arch Linux (Vanilla)
# Maintained by: Fusion-OS Project

PROFILE_NAME="arch"
PROFILE_LABEL="Arch Linux (Vanilla)"
PROFILE_KERNEL="linux"
PROFILE_MKINITCPIO_PRESET="linux"

# Extra packages to install (after arch-chroot, with all repos configured)
# Example: PROFILE_EXTRA_PKGS="plasma-meta konsole dolphin firefox"
PROFILE_EXTRA_PKGS=""

# Keyring & Repository (empty for vanilla Arch)
PROFILE_KEYRING_URL=""
PROFILE_REPO_CONF=""
PROFILE_KEYRING_PGP=""

# Extra kernel boot parameters (appended to GRUB_CMDLINE_LINUX)
# Example: "nvidia_drm.modeset=1 nowatchdog"
PROFILE_BOOT_PARAMS=""

# Packages to remove after install (e.g., conflicting keyrings)
# Example: PROFILE_REMOVE_PKGS="archlinux-keyring"
PROFILE_REMOVE_PKGS=""

# Post-install hooks: bash commands to run inside chroot after all config
# Example: PROFILE_POST_INSTALL_HOOKS="systemctl enable sddm && pacman -S --noconfirm firefox"
PROFILE_POST_INSTALL_HOOKS=""
