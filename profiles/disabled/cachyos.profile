# Profile: CachyOS (Performance)
# Maintained by: Fusion-OS Project

PROFILE_NAME="cachyos"
PROFILE_LABEL="CachyOS (Performance)"
PROFILE_KERNEL="linux-cachyos"
PROFILE_MKINITCPIO_PRESET="linux-cachyos"

# Extra packages from CachyOS repos (installed after repo config)
PROFILE_EXTRA_PKGS="cachyos-settings linux-cachyos-headers"

# Keyring URL: check https://mirror.cachyos.org/ for latest version
PROFILE_KEYRING_URL="https://mirror.cachyos.org/cachyos-keyring/cachyos-keyring-20250414-1-any.pkg.tar.zst"
PROFILE_REPO_CONF="[cachyos]\nServer = https://mirror.cachyos.org/repo/x86_64/\$repo\nSigLevel = Optional TrustAll"
PROFILE_KEYRING_PGP="F3B607488DB35A471AC8E9AA1D6E5AB5E0A1F384"

# Extra kernel boot parameters (e.g., nvidia_drm.modeset=1 for NVIDIA GPUs)
PROFILE_BOOT_PARAMS=""

# Packages to remove after install
PROFILE_REMOVE_PKGS=""

# Post-install hooks: bash commands to run inside chroot
PROFILE_POST_INSTALL_HOOKS=""
