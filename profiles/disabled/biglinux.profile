# Profile: BigLinux (Compatibility)
# Maintained by: Fusion-OS Project

PROFILE_NAME="biglinux"
PROFILE_LABEL="BigLinux (Compatibility)"
PROFILE_KERNEL="linux"
PROFILE_MKINITCPIO_PRESET="linux"

# Extra packages from BigLinux repos (installed after repo config)
# Example: PROFILE_EXTRA_PKGS="biglinux-desktop biglinux-settings"
PROFILE_EXTRA_PKGS=""

# Keyring URL: check https://gitlab.com/biglinux/biglinux-keyring for latest
PROFILE_KEYRING_URL="https://gitlab.com/biglinux/biglinux-keyring/-/raw/main/biglinux-keyring.pkg.tar.zst"
PROFILE_REPO_CONF="[biglinux]\nServer = https://repo.biglinux.com.br/\$repo/x86_64\nSigLevel = Optional TrustAll"
PROFILE_KEYRING_PGP=""

# Extra kernel boot parameters
PROFILE_BOOT_PARAMS=""

# Packages to remove after install
PROFILE_REMOVE_PKGS=""

# Post-install hooks: bash commands to run inside chroot
# Example: PROFILE_POST_INSTALL_HOOKS="systemctl enable sddm && localectl set-keymap br-abnt2"
PROFILE_POST_INSTALL_HOOKS=""
