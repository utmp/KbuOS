#!/bin/bash
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

# Wallpaper source (local path)
WALLPAPER_SRC="$(pwd)/images/kbu.jpeg"

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
    lightdm
    lightdm-gtk-greeter
    yad
    feh
    fonts-dejavu
    firefox-esr
    plank
    picom
    pcmanfm
    adwaita-icon-theme
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
    
    # Copy wallpaper to rootfs
    if [[ -f "${WALLPAPER_SRC}" ]]; then
        log "Copying wallpaper..."
        mkdir -p "${ROOTFS_DIR}/usr/share/backgrounds/kbuos"
        cp "${WALLPAPER_SRC}" "${ROOTFS_DIR}/usr/share/backgrounds/kbuos/wallpaper.jpeg"
    else
        log "WARNING: Wallpaper not found at ${WALLPAPER_SRC}"
    fi
    
    # Copy KBU logo for icons
    LOGO_SRC="$(pwd)/images/kbuLogo.png"
    if [[ -f "${LOGO_SRC}" ]]; then
        log "Copying KBU logo..."
        mkdir -p "${ROOTFS_DIR}/usr/share/icons/kbuos"
        cp "${LOGO_SRC}" "${ROOTFS_DIR}/usr/share/icons/kbuos/kbulogo.png"
        # Also copy to pixmaps for broader compatibility
        mkdir -p "${ROOTFS_DIR}/usr/share/pixmaps"
        cp "${LOGO_SRC}" "${ROOTFS_DIR}/usr/share/pixmaps/kbulogo.png"
    else
        log "WARNING: KBU logo not found at ${LOGO_SRC}"
    fi
    
    # Create About KbuOS script with logo
    cat > "${ROOTFS_DIR}/usr/local/bin/about-kbuos" << 'ABOUT_SCRIPT'
#!/bin/bash
yad --title="About KbuOS" \
    --window-icon=/usr/share/icons/kbuos/kbulogo.png \
    --image=/usr/share/icons/kbuos/kbulogo.png \
    --text="<b>KbuOS</b>\n\nVersion: 1.0\n\nA hobby project.\n\nBuilt with:\n• Openbox Window Manager\n• Linux Kernel (amd64)\n• Debian Bookworm base\n\nKarabük University\nComputer Engineering Department\n\n© Abdulaziz Shamsiev 2025-2026" \
    --button=OK:0 \
    --center \
    --width=400
ABOUT_SCRIPT
    chmod +x "${ROOTFS_DIR}/usr/local/bin/about-kbuos"
    
    # Create desktop entry for About KbuOS with logo
    mkdir -p "${ROOTFS_DIR}/usr/share/applications"
    cat > "${ROOTFS_DIR}/usr/share/applications/about-kbuos.desktop" << 'DESKTOP_ENTRY'
[Desktop Entry]
Name=About KbuOS
Comment=Information about KbuOS
Exec=/usr/local/bin/about-kbuos
Icon=/usr/share/icons/kbuos/kbulogo.png
Terminal=false
Type=Application
Categories=System;
DESKTOP_ENTRY

    # Create OBS (Student Information System) desktop shortcut
    cat > "${ROOTFS_DIR}/usr/share/applications/obs-kbu.desktop" << 'OBS_ENTRY'
[Desktop Entry]
Name=KBU OBS
Comment=Karabük University Student Information System
Exec=firefox-esr https://obs.karabuk.edu.tr
Icon=applications-internet
Terminal=false
Type=Application
Categories=Network;Education;
OBS_ENTRY
    
    # Configure LightDM
    mkdir -p "${ROOTFS_DIR}/etc/lightdm"
    cat > "${ROOTFS_DIR}/etc/lightdm/lightdm.conf" << 'LIGHTDM_CONF'
[Seat:*]
autologin-user=user
autologin-user-timeout=0
user-session=openbox
greeter-session=lightdm-gtk-greeter
LIGHTDM_CONF

    # Configure LightDM GTK Greeter with wallpaper
    cat > "${ROOTFS_DIR}/etc/lightdm/lightdm-gtk-greeter.conf" << 'GREETER_CONF'
[greeter]
background=/usr/share/backgrounds/kbuos/wallpaper.jpeg
theme-name=Adwaita
icon-theme-name=Adwaita
font-name=DejaVu Sans 11
xft-antialias=true
xft-dpi=96
xft-hintstyle=slight
xft-rgba=rgb
GREETER_CONF
    
    # Create Openbox autostart to set wallpaper
    mkdir -p "${ROOTFS_DIR}/etc/xdg/openbox"
    cat > "${ROOTFS_DIR}/etc/xdg/openbox/autostart" << 'AUTOSTART'
# Start compositor for transparency and effects
picom -b &

# Set wallpaper
feh --bg-fill /usr/share/backgrounds/kbuos/wallpaper.jpeg &

# Start Plank dock at the bottom
plank &

# Start network manager applet (if available)
nm-applet &
AUTOSTART
    
    # Create Openbox menu with applications
    cat > "${ROOTFS_DIR}/etc/xdg/openbox/menu.xml" << 'MENU_XML'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="KbuOS">
    <item label="Firefox">
      <action name="Execute"><execute>firefox-esr</execute></action>
    </item>
    <item label="File Manager">
      <action name="Execute"><execute>pcmanfm</execute></action>
    </item>
    <item label="Terminal">
      <action name="Execute"><execute>xterm</execute></action>
    </item>
    <separator />
    <menu id="system-menu" label="System">
      <item label="About KbuOS">
        <action name="Execute"><execute>/usr/local/bin/about-kbuos</execute></action>
      </item>
    </menu>
    <separator />
    <item label="Log Out">
      <action name="Exit" />
    </item>
  </menu>
</openbox_menu>
MENU_XML
    
    # Create user and configure system
    chroot "${ROOTFS_DIR}" /bin/bash << 'CHROOT_EOF'
set -e

# Generate locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# Set root password
echo "root:kbuos" | chpasswd

# Create a regular user
useradd -m -s /bin/bash -G sudo,audio,video,netdev user
echo "user:user" | chpasswd

# Enable LightDM (login manager)
systemctl enable lightdm

# Enable NetworkManager
systemctl enable NetworkManager

# Configure Plank dock with default launchers
mkdir -p /home/user/.config/plank/dock1/launchers

# Firefox launcher
cat > /home/user/.config/plank/dock1/launchers/firefox-esr.dockitem << 'DOCK_FF'
[PlankDockItemPreferences]
Launcher=file:///usr/share/applications/firefox-esr.desktop
DOCK_FF

# File Manager launcher
cat > /home/user/.config/plank/dock1/launchers/pcmanfm.dockitem << 'DOCK_FM'
[PlankDockItemPreferences]
Launcher=file:///usr/share/applications/pcmanfm.desktop
DOCK_FM

# Terminal launcher
cat > /home/user/.config/plank/dock1/launchers/xterm.dockitem << 'DOCK_TERM'
[PlankDockItemPreferences]
Launcher=file:///usr/share/applications/xterm.desktop
DOCK_TERM

# About KbuOS launcher
cat > /home/user/.config/plank/dock1/launchers/about-kbuos.dockitem << 'DOCK_ABOUT'
[PlankDockItemPreferences]
Launcher=file:///usr/share/applications/about-kbuos.desktop
DOCK_ABOUT

# OBS (Student Portal) launcher
cat > /home/user/.config/plank/dock1/launchers/obs-kbu.dockitem << 'DOCK_OBS'
[PlankDockItemPreferences]
Launcher=file:///usr/share/applications/obs-kbu.desktop
DOCK_OBS

# Set ownership
chown -R user:user /home/user/.config

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

menuentry "KbuOS - Live (Openbox)" {
    linux /live/vmlinuz boot=live quiet splash
    initrd /live/initrd
}

menuentry "KbuOS - Live (Safe Mode)" {
    linux /live/vmlinuz boot=live nomodeset
    initrd /live/initrd
}

menuentry "KbuOS - Live (Text Mode)" {
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
