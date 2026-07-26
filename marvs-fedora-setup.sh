#!/bin/bash

BASE_PATH='/var/lib/fedora_setup'
STATE_FILE="$BASE_PATH/state"
GPU_FILE="$BASE_PATH/gpu"
SERVICE_FILE='/etc/systemd/system/marvs_fedora_setup.service'

# ---States---
START='start'
POST_UPDATE='post-update'
DONE='done'

set_autostart() {
    SERVICE_CONTENTS="[Unit]
Description=Resume update after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$0
"
    
    echo "$SERVICE_CONTENTS" > $SERVICE_FILE
    systemctl enable "$(basename $SERVICE_FILE)"
}

next_state() {
    if [ ! -n $1 ]; then
        echo "Invalid state change: \"$1\"" >&2
	exit 1
    fi

    echo $1 > $STATE_FILE
    set_autostart
    reboot
}

# ---GPU Types---
AMD='AMD'
INTEL='INTEL'
SKIP='SKIP'

# ---Fedora setup---
fedora_update() {
    # Get the free repository 
    dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
    # Get the nonfree repository (NVIDIA drivers, some codecs)
    dnf install -y https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
    # Install AppStream metadata
    dnf install rpmfusion-free-appstream-data rpmfusion-nonfree-appstream-data
    dnf check-update

    dnf update -y
}

fedora_setup() {
    # ---Fimware update---
    # See what can be updated
    fwupdmgr get-devices
    # Refresh the firmware database
    fwupdmgr refresh --force
    # Check for updates
    fwupdmgr get-updates
    # Apply them
    fwupdmgr update

    # ---Flatpak---
    # Remove the limited Fedora repo to prevent conflicts
    flatpak remote-delete fedora
    flatpak remote-add --if-not-exists --subset=verified flathub https://flathub.org/repo/flathub.flatpakrepo

    gpu="$(cat "$GPU_FILE" 2> /dev/null | echo "$SKIP")"
    case "$gpu" in
        "$AMD"|"$INTEL")
	    # AMD&INTEL core
	    dnf install mesa-vulkan-drivers vulkan-loader mesa-libGLU libva-utils

	    case "$gpu" in
                "$AMD")
	            # AMD Video acceleration
	            dnf swap mesa-va-drivers mesa-va-drivers-freeworld mesa-vdpau-drivers mesa-vdpau-drivers-freeworld
		    ;;
		"$INTEL")
		    # Intel video acceleration (for newer Intel GPUs)
                    dnf install -y intel-media-driver
                    ;;
            esac
            ;;
        *)
	    case "$gpu" in
	        "$SKIP")
	            echo 'Skipping GPU setup...'
	            firefox 'https://github.com/wz790/Fedora-Noble-Setup#graphics-drivers'
                    ;;
		*)
                    echo 'Invalid GPU selector found: Skipping...' >&2
                    ;;
            esac
	    ;;
    esac

    # ---Media Codecs---
    dnf swap ffmpeg-free ffmpeg --allowerasing
    dnf update @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin
    dnf groupupdate sound-and-video

    # ---Hardware Acceleration---
    # Install VA-API stuff
    dnf install -y ffmpeg-libs libva libva-utils

    # Firefox Video fix
    dnf install -y openh264 gstreamer1-plugin-openh264 mozilla-openh264
    dnf config-manager --set-enabled fedora-cisco-openh264
    dnf update -y
    notify-send -u normal -t 60000 -a 'Marvs Fedora Setup' 'Restart Firefox and enable the OpenH264 Plugin: `about:addons`'

    # ---Useful stuff---
    # .rar
    dnf install -y p7zip p7zip-plugins unrar

    # Appimages
    dnf install -y fuse fuse-libs
    flatpak install -y flathub it.mijorus.gearlever

    # System Snapshots
    dnf install -y btrfs-assistant btrbk snapper

    # Backups
    dnf install -y deja-dup
}

# ---Software setup---
software_setup() {
    # Launchers Software
    dnf install -y steam lutris 

    # Utility
    dnf install -y mangohud gamemoderun

    # Chromium
    dnf install -y chromium
    # Brave
    dnf install dnf-plugins-core
    dnf config-manager addrepo --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
    rpm --import https://brave-browser-rpm-release.s3.brave.com/brave-core.asc
    dnf install -y brave-browser
    # Librewolf
    curl -fsSL https://repo.librewolf.net/librewolf.repo | pkexec tee /etc/yum.repos.d/librewolf.repo
    dnf install -y librewolf
    
    # General Software
    dnf install -y vlc blender audacity brave chromium sqlitebrowser gimp godot inkscape kdenlive kile kitty krita lmms localsend qbittorrent tor torbrowser-launcher

    flatpak install -y flathub com.obsproject.Studio org.prismlauncher.PrismLauncher com.spotify.Client

    cargo install ratty concord atac
}

# ---Cleanup---
cleanup() {
    systemctl disable "$(basename "$SERVICE_FILE")"
    rm -f "$SERVICE_FILE"

    rm -rf "$BASE_PATH"

    dnf clean all
    dnf autoremove -y
}

# ---Script setup---
sudo -s

mkdir -p "$BASE_PATH"

# ---State Machine---
stage="$(cat "$STATE_FILE" 2> /dev/null || next_state "$START" && echo "$START")"
case "$stage" in
    "$START")
	read -p 'Input hostname (Skip with <ENTER>): ' host
	if [ -n host ]; then
	    hostnamectl set-hostname "$host"
	fi

	echo

	echo 'Select GPU:'
	echo "$AMD 1)"
	echo "$INTEL 2)"
	echo "$SKIP 0)"
	while read -p 'GPU: ' gpu
	do
            case "$gpu" in
                '1')
                    echo "$AMD" > "$GPU_FILE"
                    ;;
		'2')
		    echo "$INTEL" > "$GPU_FILE"
		    ;;
		'0')
		    echo "$SKIP" > "$GPU_FILE"
		    ;;
                *)
                    echo "Invalid GPU: $gpu"
                    ;;
            esac
	done

	echo

	curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
        
        fedora_update
        
	next_state "$POST_UPDATE"
	;;
    "$POST_UPDATE")
        fedora_setup
	software_setup

	next_state "$END"
        ;;
    "$END")
        cleanup
	exit 0
        ;;
    *)
        echo "State \"$state\" not found!" >&2
	cleanup
	exit 1
	;;
esac

