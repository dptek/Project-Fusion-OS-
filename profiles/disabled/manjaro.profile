# Profile: Manjaro (Stable)
# Maintained by: Fusion-OS Project

PROFILE_NAME="manjaro"
PROFILE_LABEL="Manjaro (Stable)"
PROFILE_KERNEL="linux"
PROFILE_MKINITCPIO_PRESET="linux"

# Extra packages from Manjaro repos (installed after repo config)
# Example: PROFILE_EXTRA_PKGS="manjaro-desktop manjaro-settings-manager xfce4"
PROFILE_EXTRA_PKGS=""

# Keyring URL: check https://mirrors.manjaro.org/stable/x86_64/ for latest version
PROFILE_KEYRING_URL="https://mirrors.manjaro.org/stable/x86_64/manjaro-keyring-20230918-2-any.pkg.tar.zst"
PROFILE_REPO_CONF="[manjaro]\nServer = https://mirrors.manjaro.org/stable/\$repo/\$arch\nSigLevel = Optional TrustAll"
PROFILE_KEYRING_PGP=""

# Extra kernel boot parameters
PROFILE_BOOT_PARAMS=""

# Manjaro ships its own keyring that replaces archlinux-keyring
PROFILE_REMOVE_PKGS="archlinux-keyring"

# Post-install hooks: bash commands to run inside chroot
# Example: PROFILE_POST_INSTALL_HOOKS="systemctl enable lightdm && pacman -S --noconfirm manjaro-welcome"
PROFILE_POST_INSTALL_HOOKS=""
