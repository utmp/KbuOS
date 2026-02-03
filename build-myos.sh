#!/bin/bash
#
# build-myos.sh - Build a minimal Linux distribution based on Debian
#
# This script creates a bootable ISO with:
#   - Minimal Debian rootfs (via debootstrap)
#   - Linux kernel (linux-image-amd64)
#   - Openbox window manager
#   - GRUB bootloader
#
# Usage: sudo ./build-myos.sh
#

set -e

# ============================================================================
# Configuration
# ============================================================================

DISTRO_NAME="KbuOS"
WORK_DIR="$(pwd)/build"
ROOTFS_DIR="${WORK_DIR}/rootfs"
ISO_DIR="${WORK_DIR}/iso"
OUTPUT_ISO="${DISTRO_NAME}.iso"

DEBIAN_MIRROR="http://deb.debian.org/debian"
DEBIAN_SUITE="bookworm"
ARCH="amd64"

# Base packages for debootstrap (minimal, no complex dependencies)
BASE_PACKAGES=(
    systemd-sysv
    dbus
    locales
    sudo
)

# Packages to install in chroot (after base system is ready)
EXTRA_PACKAGES=(
    linux-image-amd64
    live-boot
    openbox
    xorg
    xinit
    xterm
    network-manager
)

# ============================================================================
# Helper Functions
# ============================================================================

log() {
    echo -e "\e[1;32m[MYOS]\e[0m $1"
}

error() {
    echo -e "\e[1;31m[ERROR]\e[0m $1" >&2
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root. Use: sudo $0"
    fi
}

cleanup() {
    log "Cleaning up mounts..."
    umount -lf "${ROOTFS_DIR}/dev/pts" 2>/dev/null || true
    umount -lf "${ROOTFS_DIR}/dev" 2>/dev/null || true
    umount -lf "${ROOTFS_DIR}/proc" 2>/dev/null || true
    umount -lf "${ROOTFS_DIR}/sys" 2>/dev/null || true
    umount -lf "${ROOTFS_DIR}/run" 2>/dev/null || true
}

trap cleanup EXIT

# ============================================================================
# Dependency Check
# ============================================================================

install_dependencies() {
    log "Checking and installing dependencies..."
    
    local deps=(
        debootstrap
        squashfs-tools
        grub-pc-bin
        grub-efi-amd64-bin
        grub-common
        xorriso
        mtools
        dosfstools
    )
    
    apt-get update
    apt-get install -y "${deps[@]}"
}

# ============================================================================
# Create Rootfs with Debootstrap
# ============================================================================

create_rootfs() {
    log "Creating minimal rootfs with debootstrap..."
    
    rm -rf "${ROOTFS_DIR}"
    mkdir -p "${ROOTFS_DIR}"
    
    # Stage 1: Create minimal base system
    debootstrap \
        --arch="${ARCH}" \
        --variant=minbase \
        --include="$(IFS=,; echo "${BASE_PACKAGES[*]}")" \
        "${DEBIAN_SUITE}" \
        "${ROOTFS_DIR}" \
        "${DEBIAN_MIRROR}"
    
    log "Base rootfs created. Installing additional packages..."
    
    # Mount filesystems for chroot
    mount --bind /dev "${ROOTFS_DIR}/dev"
    mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
    mount -t proc proc "${ROOTFS_DIR}/proc"
    mount -t sysfs sysfs "${ROOTFS_DIR}/sys"
    mount -t tmpfs tmpfs "${ROOTFS_DIR}/run"
    
    # Stage 2: Install extra packages in chroot with proper dependency resolution
    chroot "${ROOTFS_DIR}" /bin/bash << CHROOT_INSTALL_EOF
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ${EXTRA_PACKAGES[*]}
apt-get clean
CHROOT_INSTALL_EOF
    
    log "Rootfs created successfully."
}

# ============================================================================
# Configure Rootfs (chroot operations)
# ============================================================================

configure_rootfs() {
    log "Configuring rootfs..."
    
    # Note: Filesystems are already mounted from create_rootfs()
    
    # Set hostname
    echo "${DISTRO_NAME}" > "${ROOTFS_DIR}/etc/hostname"
    
    # Configure hosts
    cat > "${ROOTFS_DIR}/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   ${DISTRO_NAME}

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

    # Configure locales
    echo "en_US.UTF-8 UTF-8" > "${ROOTFS_DIR}/etc/locale.gen"
    
    # Create a default user
    chroot "${ROOTFS_DIR}" /bin/bash << 'CHROOT_EOF'
set -e

# Generate locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# Set root password (change this!)
echo "root:myos" | chpasswd

# Create a regular user
useradd -m -s /bin/bash -G sudo,audio,video,netdev user
echo "user:user" | chpasswd

# Enable auto-login for the user on tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'GETTY_EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin user --noclear %I $TERM
GETTY_EOF

# Configure .xinitrc for user to start Openbox
cat > /home/user/.xinitrc << 'XINITRC_EOF'
#!/bin/sh
exec openbox-session
XINITRC_EOF
chmod +x /home/user/.xinitrc
chown user:user /home/user/.xinitrc

# Auto-start X on login for user
cat >> /home/user/.bash_profile << 'PROFILE_EOF'
# Start X automatically on tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    startx
fi
PROFILE_EOF
chown user:user /home/user/.bash_profile

# Enable NetworkManager
systemctl enable NetworkManager

# Clean up apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*

CHROOT_EOF

    log "Rootfs configuration complete."
}

# ============================================================================
# Create ISO Directory Structure
# ============================================================================

create_iso_structure() {
    log "Creating ISO directory structure..."
    
    rm -rf "${ISO_DIR}"
    mkdir -p "${ISO_DIR}/boot/grub"
    mkdir -p "${ISO_DIR}/live"
    
    # Copy kernel and initrd
    cp "${ROOTFS_DIR}"/boot/vmlinuz-* "${ISO_DIR}/live/vmlinuz"
    cp "${ROOTFS_DIR}"/boot/initrd.img-* "${ISO_DIR}/live/initrd"
    
    log "ISO structure created."
}

# ============================================================================
# Create Squashfs Image
# ============================================================================

create_squashfs() {
    log "Creating squashfs image (this may take a while)..."
    
    # Unmount filesystems before creating squashfs
    cleanup
    
    mksquashfs "${ROOTFS_DIR}" "${ISO_DIR}/live/filesystem.squashfs" \
        -comp xz \
        -e boot \
        -noappend
    
    log "Squashfs image created."
}

# ============================================================================
# Configure GRUB
# ============================================================================

configure_grub() {
    log "Configuring GRUB bootloader..."
    
    cat > "${ISO_DIR}/boot/grub/grub.cfg" << 'GRUB_EOF'
set timeout=10
set default=0

insmod all_video
insmod gfxterm
set gfxmode=auto
terminal_output gfxterm

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "MyOS - Live (Openbox)" {
    linux /live/vmlinuz boot=live quiet splash
    initrd /live/initrd
}

menuentry "MyOS - Live (Safe Mode)" {
    linux /live/vmlinuz boot=live nomodeset
    initrd /live/initrd
}

menuentry "MyOS - Live (Text Mode)" {
    linux /live/vmlinuz boot=live systemd.unit=multi-user.target
    initrd /live/initrd
}
GRUB_EOF

    log "GRUB configuration complete."
}

# ============================================================================
# Generate Bootable ISO
# ============================================================================

generate_iso() {
    log "Generating bootable ISO..."
    
    grub-mkrescue \
        -o "${OUTPUT_ISO}" \
        "${ISO_DIR}" \
        -- \
        -volid "${DISTRO_NAME^^}"
    
    log "ISO generated: ${OUTPUT_ISO}"
    log "Size: $(du -h "${OUTPUT_ISO}" | cut -f1)"
}

# ============================================================================
# Main
# ============================================================================

main() {
    log "=========================================="
    log "  Building ${DISTRO_NAME} Linux Distribution"
    log "=========================================="
    
    check_root
    install_dependencies
    create_rootfs
    configure_rootfs
    create_iso_structure
    create_squashfs
    configure_grub
    generate_iso
    
    log "=========================================="
    log "  Build Complete!"
    log "=========================================="
    log ""
    log "Output: ${OUTPUT_ISO}"
    log ""
    log "Test with QEMU:"
    log "  qemu-system-x86_64 -cdrom ${OUTPUT_ISO} -m 1024 -enable-kvm"
    log ""
    log "Default credentials:"
    log "  User: user / Password: user"
    log "  Root: root / Password: myos"
    log ""
}

main "$@"
