# Profile: Mabox (Openbox)
# Maintained by: Fusion-OS Project
# Note: Mabox is based on Manjaro

PROFILE_NAME="mabox"
PROFILE_LABEL="Mabox (Openbox)"
PROFILE_KERNEL="linux"
PROFILE_MKINITCPIO_PRESET="linux"

# Extra packages from Mabox/Manjaro repos (installed after repo config)
# Example: PROFILE_EXTRA_PKGS="mabox-desktop mabox-tint2"
PROFILE_EXTRA_PKGS=""

# Keyring URL: same as Manjaro (Mabox uses Manjaro repos + its own)
PROFILE_KEYRING_URL="https://mirrors.manjaro.org/stable/x86_64/manjaro-keyring-20230918-2-any.pkg.tar.zst"
PROFILE_REPO_CONF="[mabox]\nServer = https://repo.maboxlinux.org/\$repo/\$arch\nSigLevel = Optional TrustAll\n[manjaro]\nServer = https://mirrors.manjaro.org/stable/\$repo/\$arch\nSigLevel = Optional TrustAll"
PROFILE_KEYRING_PGP=""

# Extra kernel boot parameters
PROFILE_BOOT_PARAMS=""

# Mabox (via Manjaro) ships its own keyring that replaces archlinux-keyring
PROFILE_REMOVE_PKGS="archlinux-keyring"

# Post-install hooks: bash commands to run inside chroot
# Example: PROFILE_POST_INSTALL_HOOKS="systemctl enable lightdm && pacman -S --noconfirm mabox-welcome"
PROFILE_POST_INSTALL_HOOKS=""
