# Profile: Archcraft (Aesthetic)
# Maintained by: Fusion-OS Project

PROFILE_NAME="archcraft"
PROFILE_LABEL="Archcraft (Aesthetic)"
PROFILE_KERNEL="linux"
PROFILE_MKINITCPIO_PRESET="linux"

# Extra packages from Archcraft repos (installed after repo config)
# Example: PROFILE_EXTRA_PKGS="archcraft-openbox archcraft-settings"
PROFILE_EXTRA_PKGS=""

# Keyring URL: check https://github.com/archcraft-os/archcraft-keyring/releases for latest
PROFILE_KEYRING_URL="https://raw.githubusercontent.com/archcraft-os/archcraft-keyring/main/archcraft-keyring-20240428-1-any.pkg.tar.zst"
PROFILE_REPO_CONF="[archcraft]\nServer = https://repo.archcraft.io/\$repo/x86_64\nSigLevel = Optional TrustAll"
PROFILE_KEYRING_PGP=""

# Extra kernel boot parameters
PROFILE_BOOT_PARAMS=""

# Packages to remove after install
PROFILE_REMOVE_PKGS=""

# Post-install hooks: bash commands to run inside chroot
# Example: PROFILE_POST_INSTALL_HOOKS="systemctl enable lightdm && pacman -S --noconfirm archcraft-welcome"
PROFILE_POST_INSTALL_HOOKS=""
