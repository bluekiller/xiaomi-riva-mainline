#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Build a bootable Ubuntu 24.04 image for the Xiaomi Redmi 5A (riva, MSM8917)
# booted by lk2nd through extlinux:
#
#   boot.ext2     -> flash to the "boot" partition from lk2nd's fastboot, which
#                    writes it after lk2nd (kernel, dtbs, extlinux.conf)
#   rootfs.simg   -> flash to the "userdata" partition (Ubuntu root filesystem)
#
# Klipper itself is installed on the device with KIAUH after first boot; this
# script only clones KIAUH into the user's home directory.
#
# Usage: ./build-riva-ubuntu.sh [all|kernel|rootfs|images|clean]
#
# Settings are read from the environment, or from $CONFIG_FILE
# (default: $WORK/riva.conf) if it exists. See the defaults below.

set -euo pipefail

# ---------------------------------------------------------------- settings --
WORK=${WORK:-$HOME/riva-build}
CONFIG_FILE=${CONFIG_FILE:-$WORK/riva.conf}
# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

KERNEL_SRC=${KERNEL_SRC:-/home/pfwu/linux-msm89x7}
PMOS_CONFIG_URL=${PMOS_CONFIG_URL:-https://gitlab.postmarketos.org/postmarketOS/pmaports/-/raw/main/device/testing/linux-postmarketos-qcom-msm89x7/config-postmarketos-qcom-msm89x7.aarch64}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
JOBS=${JOBS:-$(nproc)}

UBUNTU_BASE_DIR=${UBUNTU_BASE_DIR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release}
# arm64 package mirror (ports archive), without the scheme: Tsinghua TUNA.
# Upstream: ports.ubuntu.com/ubuntu-ports
UBUNTU_MIRROR=${UBUNTU_MIRROR:-mirrors.tuna.tsinghua.edu.cn/ubuntu-ports}
# PyPI index for pip on the device (KIAUH's Klipper/Moonraker venvs too);
# empty keeps pip's default (pypi.org)
PIP_INDEX_URL=${PIP_INDEX_URL-https://pypi.tuna.tsinghua.edu.cn/simple}
# Preinstall Klipper, Moonraker, Fluidd (port 80) and KlipperScreen (Wayland)
KLIPPER_STACK=${KLIPPER_STACK:-1}
# avr/arm-none-eabi toolchains for building MCU firmware on the phone (~700 MB)
KLIPPER_MCU_TOOLCHAINS=${KLIPPER_MCU_TOOLCHAINS:-1}
# KlipperScreen display rotation in Weston: normal, 90, 180 or 270
KS_ROTATION=${KS_ROTATION:-270}
FLUIDD_ZIP_URL=${FLUIDD_ZIP_URL:-https://github.com/fluidd-core/fluidd/releases/latest/download/fluidd.zip}
ROOTFS_SIZE=${ROOTFS_SIZE:-6G}		# grown to the full partition on first boot
# Where boot.ext2 goes: "boot" (after lk2nd, default) or "cache"
BOOT_PARTITION=${BOOT_PARTITION:-boot}
case "$BOOT_PARTITION" in
boot)	BOOTFS_SIZE=${BOOTFS_SIZE:-32M} ;;	# boot is shared with lk2nd
cache)	BOOTFS_SIZE=${BOOTFS_SIZE:-64M} ;;
*)	echo "BOOT_PARTITION must be boot or cache" >&2; exit 1 ;;
esac
# lk2nd occupies the start of the boot partition (LK2ND_PARTITION_SIZE)
LK2ND_SIZE=${LK2ND_SIZE:-524288}
DTB_NAME=${DTB_NAME:-msm8917-xiaomi-riva}
CMDLINE=${CMDLINE:-root=PARTLABEL=userdata rootwait rw console=tty0}

TARGET_HOSTNAME=${TARGET_HOSTNAME:-riva}
TARGET_USER=${TARGET_USER:-pi}
TARGET_PASSWORD=${TARGET_PASSWORD:-}	# prompted for if empty
TARGET_TIMEZONE=${TARGET_TIMEZONE:-Etc/UTC}
TARGET_LOCALE=${TARGET_LOCALE:-en_US.UTF-8}
WIFI_SSID=${WIFI_SSID:-}
WIFI_PSK=${WIFI_PSK:-}
SSH_PUBKEY=${SSH_PUBKEY:-}		# path to a public key for $TARGET_USER
# USB serial console when the phone is plugged into a PC (ttyACM* on the PC)
USB_GADGET=${USB_GADGET:-1}

# Device firmware (not redistributable, take it from your own phone/ROM):
#   MODEM_IMG: the "modem" partition dump or NON-HLOS.bin from the MIUI
#              fastboot ROM (FAT image, firmware lives in image/)
#   NV_BIN:    WCNSS_qcom_wlan_nv.bin (stock /vendor/firmware/wlan/prima/
#              or the persist partition)
#   FIRMWARE_DIR: extra files copied verbatim into /lib/firmware
MODEM_IMG=${MODEM_IMG:-}
NV_BIN=${NV_BIN:-}
FIRMWARE_DIR=${FIRMWARE_DIR:-}
LINUX_FIRMWARE_URL=${LINUX_FIRMWARE_URL:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain}

EXTRA_PACKAGES=${EXTRA_PACKAGES:-}

# Kernel options added on top of the postmarketOS config. Klipper needs the
# USB serial drivers used by printer mainboards (ttyACM*/ttyUSB*).
KCONFIG_MODULES=(USB_ACM USB_SERIAL_CH341 USB_SERIAL_FTDI_SIO USB_SERIAL_PL2303
		 USB_SERIAL_CP210X CHARGER_BQ256XX)

# ------------------------------------------------------------------ paths --
KBUILD=$WORK/kernel/build
DEBS=$WORK/kernel
DL=$WORK/downloads
ROOT=$WORK/rootfs
BOOTFS=$WORK/bootfs
OUT=$WORK/out
ROOTFS_IMG=$OUT/rootfs.img

# ---------------------------------------------------------------- helpers --
log()  { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

kmake() {
	make -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
		O="$KBUILD" LOCALVERSION= -j"$JOBS" "$@"
}

in_chroot() {
	sudo env -i HOME=/root TERM="${TERM:-xterm}" \
		PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C \
		DEBIAN_FRONTEND=noninteractive \
		chroot "$ROOT" /bin/bash -euo pipefail -c "$1"
}

need() {
	local missing=()
	for c in "$@"; do command -v "$c" >/dev/null || missing+=("$c"); done
	[ ${#missing[@]} -eq 0 ] || die "missing tools: ${missing[*]}
Install with: sudo apt install build-essential bc bison flex libssl-dev dpkg-dev \\
  debhelper libdw-dev libelf-dev zstd rsync kmod cpio gcc-aarch64-linux-gnu qemu-user-static binfmt-support \\
  e2fsprogs dosfstools mtools android-sdk-libsparse-utils curl"
}

umount_all() {
	local m
	for m in "$ROOT/dev/pts" "$ROOT/dev" "$ROOT/proc" "$ROOT/sys" "$ROOT/run" "$ROOT"; do
		mountpoint -q "$m" 2>/dev/null && sudo umount -l "$m"
	done
	return 0
}
trap umount_all EXIT

kernelrelease() {
	make -s -C "$KERNEL_SRC" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
		O="$KBUILD" LOCALVERSION= kernelrelease
}

# ----------------------------------------------------------------- kernel --
stage_kernel() {
	need make "${CROSS_COMPILE}gcc" dpkg-buildpackage dh_listpackages bc bison flex curl zstd
	dpkg -s libdw-dev libelf-dev libssl-dev >/dev/null 2>&1 || \
		die "missing libdw-dev/libelf-dev/libssl-dev (needed by bindeb-pkg)"
	[ -f "$KERNEL_SRC/Makefile" ] || die "KERNEL_SRC=$KERNEL_SRC is not a kernel tree"
	[ -e "$KERNEL_SRC/.config" ] || [ -d "$KERNEL_SRC/include/config" ] && \
		die "$KERNEL_SRC is not clean (out-of-tree builds need 'make mrproper' there)"

	mkdir -p "$KBUILD" "$DL"
	if [ ! -f "$DL/pmos.config" ]; then
		log "Downloading the postmarketOS msm89x7 kernel config"
		curl -fL -o "$DL/pmos.config" "$PMOS_CONFIG_URL"
	fi
	cp "$DL/pmos.config" "$KBUILD/.config"
	local opt
	for opt in "${KCONFIG_MODULES[@]}"; do
		"$KERNEL_SRC/scripts/config" --file "$KBUILD/.config" -m "$opt"
	done
	# No debug info: it only makes the build slow and adds a huge -dbg package
	"$KERNEL_SRC/scripts/config" --file "$KBUILD/.config" \
		-d DEBUG_INFO_DWARF5 -d DEBUG_INFO_DWARF4 \
		-d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT -e DEBUG_INFO_NONE
	kmake olddefconfig
	grep -q '^CONFIG_DEBUG_INFO=y' "$KBUILD/.config" && warn "debug info is still enabled"

	for opt in "${KCONFIG_MODULES[@]}"; do
		grep -qE "^CONFIG_${opt}=[ym]" "$KBUILD/.config" || \
			warn "CONFIG_$opt did not stick (missing dependency?)"
	done

	log "Building kernel $(kernelrelease) as Debian packages"
	rm -f "$DEBS"/linux-*.deb "$DEBS"/linux-*.buildinfo "$DEBS"/linux-*.changes
	kmake bindeb-pkg
	ls "$DEBS"/linux-image-[0-9]*[0-9]_*.deb >/dev/null 2>&1 || die "bindeb-pkg produced no linux-image package"
}

# ----------------------------------------------------------------- rootfs --
fetch_ubuntu_base() {
	mkdir -p "$DL"
	local name
	name=$(curl -fsSL "$UBUNTU_BASE_DIR/" |
	       grep -oE 'ubuntu-base-24\.04(\.[0-9]+)?-base-arm64\.tar\.gz' | sort -uV | tail -1)
	[ -n "$name" ] || die "could not find an ubuntu-base arm64 tarball in $UBUNTU_BASE_DIR"
	if [ ! -f "$DL/$name" ]; then
		log "Downloading $name"
		curl -fL -o "$DL/$name.part" "$UBUNTU_BASE_DIR/$name"
		mv "$DL/$name.part" "$DL/$name"
	fi
	curl -fsSL "$UBUNTU_BASE_DIR/SHA256SUMS" | grep -F " *$name" |
		(cd "$DL" && sha256sum -c --quiet -) || die "checksum mismatch for $name"
	UBUNTU_BASE_TAR=$DL/$name
}

install_firmware() {
	local fw=$ROOT/lib/firmware
	sudo mkdir -p "$fw/qcom" "$fw/wlan/prima"

	log "Fetching Adreno 308 firmware from linux-firmware"
	local f
	for f in a300_pm4.fw a300_pfp.fw; do
		[ -f "$DL/$f" ] || curl -fL -o "$DL/$f" "$LINUX_FIRMWARE_URL/qcom/$f"
		sudo install -m644 "$DL/$f" "$fw/qcom/$f"
	done

	if [ -n "$MODEM_IMG" ]; then
		[ -f "$MODEM_IMG" ] || die "MODEM_IMG=$MODEM_IMG not found"
		log "Copying modem/adsp/wcnss/venus firmware from $MODEM_IMG"
		local tmp; tmp=$(mktemp -d)
		mcopy -s -n -i "$MODEM_IMG" ::image "$tmp/" || die "cannot read image/ from $MODEM_IMG"
		# The drivers request bare lowercase names (modem.mdt, mba.mbn,
		# wcnss.mdt, venus.mdt); FAT may hold them as upper-case 8.3 names
		local src
		for src in "$tmp"/image/*; do
			[ -f "$src" ] || continue
			sudo install -m644 "$src" "$fw/$(basename "$src" | tr '[:upper:]' '[:lower:]')"
		done
		rm -rf "$tmp"
	else
		warn "MODEM_IMG not set: modem, audio DSP (adsp), Wi-Fi (wcnss) and venus will not start"
	fi

	if [ -n "$NV_BIN" ]; then
		[ -f "$NV_BIN" ] || die "NV_BIN=$NV_BIN not found"
		sudo install -m644 "$NV_BIN" "$fw/wlan/prima/WCNSS_qcom_wlan_nv.bin"
	else
		warn "NV_BIN not set: wcn36xx needs wlan/prima/WCNSS_qcom_wlan_nv.bin for Wi-Fi"
	fi

	if [ -n "$FIRMWARE_DIR" ]; then
		log "Copying extra firmware from $FIRMWARE_DIR"
		sudo cp -a "$FIRMWARE_DIR"/. "$fw/"
	fi
}

write_target_files() {
	# fstab: root is the whole userdata partition. /boot is the ext2 boot
	# filesystem: on "boot" it starts after lk2nd, so it is a loop mount with
	# an offset, and fsck must be skipped (the raw partition starts with lk2nd).
	local bootline
	if [ "$BOOT_PARTITION" = boot ]; then
		bootline="/dev/disk/by-partlabel/boot	/boot	ext2	loop,offset=$LK2ND_SIZE,noatime,nofail	0 0"
	else
		bootline="/dev/disk/by-partlabel/cache	/boot	ext2	noatime,nofail	0 2"
	fi
	sudo tee "$ROOT/etc/fstab" >/dev/null <<-EOF
	PARTLABEL=userdata	/	ext4	defaults,noatime	0 1
	$bootline
	EOF

	echo "$TARGET_HOSTNAME" | sudo tee "$ROOT/etc/hostname" >/dev/null
	sudo tee "$ROOT/etc/hosts" >/dev/null <<-EOF
	127.0.0.1	localhost
	127.0.1.1	$TARGET_HOSTNAME
	::1		localhost ip6-localhost ip6-loopback
	EOF

	# Grow the root filesystem to the full userdata partition on first boot
	sudo tee "$ROOT/etc/systemd/system/riva-resize-rootfs.service" >/dev/null <<-'EOF'
	[Unit]
	Description=Grow root filesystem to the userdata partition
	ConditionPathExists=!/var/lib/riva-resize-rootfs.done

	[Service]
	Type=oneshot
	ExecStart=/usr/sbin/resize2fs /dev/disk/by-partlabel/userdata
	ExecStartPost=/usr/bin/touch /var/lib/riva-resize-rootfs.done

	[Install]
	WantedBy=multi-user.target
	EOF

	# wcn36xx fails to enter power save (hal_enter_bmps err=1) and DHCP
	# then stalls; keep the radio awake, which also lowers latency
	sudo mkdir -p "$ROOT/etc/NetworkManager/conf.d"
	printf '[connection]\nwifi.powersave = 2\n' |
		sudo tee "$ROOT/etc/NetworkManager/conf.d/wifi-powersave-off.conf" >/dev/null
	# With the default HAL config the riva WCN3620 loses ~86% of packets;
	# the WCN3610 config (RA start rate 0, BTC mode 2) fixes it
	echo 'options wcn36xx wcn3610_cfg=1' |
		sudo tee "$ROOT/etc/modprobe.d/wcn36xx.conf" >/dev/null

	if [ -n "$PIP_INDEX_URL" ]; then
		printf '[global]\nindex-url = %s\n' "$PIP_INDEX_URL" |
			sudo tee "$ROOT/etc/pip.conf" >/dev/null
	fi

	if [ -n "$WIFI_SSID" ]; then
		local nm=$ROOT/etc/NetworkManager/system-connections/wifi.nmconnection
		sudo mkdir -p "$(dirname "$nm")"
		sudo tee "$nm" >/dev/null <<-EOF
		[connection]
		id=$WIFI_SSID
		uuid=$(cat /proc/sys/kernel/random/uuid)
		type=wifi
		autoconnect=true

		[wifi]
		mode=infrastructure
		ssid=$WIFI_SSID

		[wifi-security]
		key-mgmt=wpa-psk
		psk=$WIFI_PSK

		[ipv4]
		method=auto

		[ipv6]
		method=auto
		EOF
		sudo chmod 600 "$nm"
	else
		warn "WIFI_SSID not set: configure networking on the device yourself"
	fi
}

# ELF e_machine of a file as 4 hex digits (e.g. 3e00 = x86-64, b700 = arm64)
elf_machine() {
	od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \n'
}

ELF_ARM64=b700

host_is_arm64() {
	[ "$(elf_machine /bin/sh)" = "$ELF_ARM64" ]
}

# The emulator must be a native program of this machine, or it cannot run.
check_native() {
	local host
	host=$(elf_machine /bin/sh)
	[ -n "$host" ] && [ "$(elf_machine "$1")" = "$host" ] || die "$1 is not a program for this machine
(ELF machine $(elf_machine "$1"), host $host); install this machine's qemu-user-static"
}

# On an arm64 host the rootfs runs natively: no emulation, and an arm64
# handler must NOT be registered (every program on the host would match it,
# and so would its arm64 interpreter, so every exec loops with ELOOP).
# On other hosts, Ubuntu 20.04's qemu-user-static may lack the aarch64 entry,
# so register it ourselves (until reboot) when it is missing.
ensure_binfmt() {
	local bm=/proc/sys/fs/binfmt_misc
	local qemu
	if host_is_arm64; then
		[ -e "$bm/qemu-aarch64" ] && die "an arm64 binfmt handler is registered on this arm64 host;
remove it before anything else breaks:  echo -1 | sudo tee $bm/qemu-aarch64"
		log "Host is arm64: running the rootfs natively, no emulation needed"
		return 0
	fi
	if [ -e "$bm/qemu-aarch64" ]; then
		qemu=$(sed -n 's/^interpreter //p' "$bm/qemu-aarch64")
		check_native "$qemu"
		return 0
	fi
	qemu=$(command -v qemu-aarch64-static) || die "qemu-aarch64-static not found (install qemu-user-static)"
	check_native "$qemu"
	[ -e "$bm/register" ] || sudo mount -t binfmt_misc binfmt_misc "$bm"
	log "Registering $qemu for arm64 binaries (binfmt_misc, until reboot)"
	printf '%s' ':qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:'"$qemu"':F' |
		sudo tee "$bm/register" >/dev/null
	[ -e "$bm/qemu-aarch64" ] || die "binfmt registration for qemu-aarch64 failed"
}

write_usb_gadget() {
	[ "$USB_GADGET" = 1 ] || return 0

	sudo tee "$ROOT/usr/local/sbin/riva-usb-gadget" >/dev/null <<'EOF'
#!/bin/sh
# USB gadget: ACM serial console via configfs (ttyGS0 here, ttyACM* on the PC)
set -e
G=/sys/kernel/config/usb_gadget/riva

stop() {
    [ -d "$G" ] || exit 0
    echo "" > "$G/UDC" 2>/dev/null || true
    rm -f "$G"/configs/c.1/acm.usb0
    rmdir "$G"/configs/c.1/strings/0x409 "$G"/configs/c.1 \
          "$G"/functions/acm.usb0 "$G"/strings/0x409 "$G" 2>/dev/null || true
    exit 0
}
[ "$1" = stop ] && stop

modprobe libcomposite
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
[ -d "$G" ] && exit 0

mkdir -p "$G"
echo 0x1d6b > "$G/idVendor"     # Linux Foundation
echo 0x0104 > "$G/idProduct"    # Multifunction Composite Gadget
echo 0x0100 > "$G/bcdDevice"
echo 0x0200 > "$G/bcdUSB"
# composite class with an IAD: binds to cdc_acm on Linux, usbser on Windows 10+
echo 0xEF > "$G/bDeviceClass"
echo 0x02 > "$G/bDeviceSubClass"
echo 0x01 > "$G/bDeviceProtocol"

mkdir -p "$G/strings/0x409"
sha256sum /etc/machine-id | cut -c1-16 > "$G/strings/0x409/serialnumber"
echo "Xiaomi"          > "$G/strings/0x409/manufacturer"
echo "Redmi 5A (riva)" > "$G/strings/0x409/product"

mkdir -p "$G/functions/acm.usb0"
mkdir -p "$G/configs/c.1/strings/0x409"
echo "Serial console" > "$G/configs/c.1/strings/0x409/configuration"
echo 500 > "$G/configs/c.1/MaxPower"
ln -s "$G/functions/acm.usb0" "$G/configs/c.1/"

# wait for the USB controller (ci_hdrc) to register its UDC
for i in $(seq 50); do
    udc=$(ls /sys/class/udc 2>/dev/null | head -1)
    [ -n "$udc" ] && break
    sleep 0.2
done
[ -n "$udc" ] || { echo "no UDC found" >&2; exit 1; }
echo "$udc" > "$G/UDC"
EOF
	sudo chmod 755 "$ROOT/usr/local/sbin/riva-usb-gadget"

	sudo tee "$ROOT/etc/systemd/system/riva-usb-gadget.service" >/dev/null <<'EOF'
[Unit]
Description=USB serial console gadget
After=sys-kernel-config.mount systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/riva-usb-gadget
ExecStop=/usr/local/sbin/riva-usb-gadget stop

[Install]
WantedBy=multi-user.target
EOF
}

write_apt_sources() {
	echo "# Ubuntu sources are in /etc/apt/sources.list.d/ubuntu.sources" |
		sudo tee "$ROOT/etc/apt/sources.list" >/dev/null
	sudo tee "$ROOT/etc/apt/sources.list.d/ubuntu.sources" >/dev/null <<-EOF
	Types: deb
	URIs: $1://$UBUNTU_MIRROR/
	Suites: noble noble-updates noble-backports noble-security
	Components: main universe restricted multiverse
	Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
	EOF
}

write_audio() {
	# The modem crashes soon after boot without rmtfs serving
	# modemst1/modemst2/fsg (audio itself runs on the ADSP). Ubuntu's
	# unit requires the userspace qrtr-ns, which this kernel replaces with
	# its in-kernel name service, so ship a unit without that dependency.
	sudo tee "$ROOT/etc/systemd/system/rmtfs.service" >/dev/null <<'EOF'
[Unit]
Description=Qualcomm remotefs service

[Service]
ExecStart=/usr/bin/rmtfs -r -P -s
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

	sudo tee "$ROOT/usr/local/sbin/riva-audio" >/dev/null <<'EOF'
#!/bin/sh
# Route playback (MultiMedia1, the default PCM) to the speaker or headphones.
#   riva-audio [speaker|headphones] [card]
# udev runs this when the sound card appears; a state saved with
# "sudo alsactl store" is restored right after it and wins.
out=${1:-speaker}
card=${2:-0}
c() { amixer -q -c "$card" cset "name=$1" "$2"; }

# not the riva card
amixer -c "$card" cget "name=PRI_MI2S_RX Audio Mixer MultiMedia1" >/dev/null 2>&1 || exit 0

c 'PRI_MI2S_RX Audio Mixer MultiMedia1' on
c 'RX1 MIX1 INP1' RX1
c 'RX2 MIX1 INP1' RX2
# HPHR drives both the right headphone and the speaker amplifier
c 'RDAC2 MUX' RX2
c 'HPHL' Switch
c 'HPHR' Switch

case $out in
speaker)
	# mono speaker: mix the left channel into RX2 as well
	c 'RX2 MIX1 INP2' RX1
	c 'Headphones Switch' off
	c 'Speaker Switch' on
	;;
headphones)
	c 'RX2 MIX1 INP2' ZERO
	c 'Speaker Switch' off
	c 'Headphones Switch' on
	;;
*)
	echo "usage: riva-audio [speaker|headphones] [card]" >&2
	exit 1
	;;
esac
EOF
	sudo chmod 755 "$ROOT/usr/local/sbin/riva-audio"

	# Before 90-alsa-restore.rules, so a saved mixer state overrides this
	sudo tee "$ROOT/etc/udev/rules.d/89-riva-audio.rules" >/dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="sound", KERNEL=="controlC*", RUN+="/usr/local/sbin/riva-audio speaker $attr{device/number}"
EOF
}

# ---------------------------------------------------------- klipper stack --
# Klipper, Moonraker, Fluidd (nginx, port 80) and KlipperScreen (Wayland via
# Weston's kiosk shell), laid out like KIAUH installs them (~/printer_data, ~/*-env), so KIAUH
# and Moonraker's update manager can maintain them afterwards. The upstream
# install scripts start services, which cannot work in the build chroot, so
# their steps are reproduced here using each project's own dependency lists.
install_klipper_stack() {
	[ "$KLIPPER_STACK" = 1 ] || return 0
	local u=$TARGET_USER h=/home/$TARGET_USER

	log "Installing Klipper stack packages"
	local pkgs="git virtualenv python3-virtualenv python3-venv python3-dev
		libffi-dev build-essential libncurses-dev libusb-dev libusb-1.0-0
		libopenjp2-7 libsodium-dev zlib1g-dev libjpeg-dev packagekit
		wireless-tools curl unzip nginx
		weston seatd libgirepository1.0-dev gcc libcairo2-dev pkg-config
		gir1.2-gtk-3.0 librsvg2-common libdbus-glib-1-dev autoconf
		libmpv-dev fonts-nanum fonts-ipafont fonts-wqy-microhei"
	[ "$KLIPPER_MCU_TOOLCHAINS" = 1 ] && pkgs="$pkgs avrdude gcc-avr
		binutils-avr avr-libc stm32flash dfu-util libnewlib-arm-none-eabi
		gcc-arm-none-eabi binutils-arm-none-eabi"
	in_chroot "apt-get update && apt-get -y install --no-install-recommends $(echo $pkgs)"

	log "Fetching Fluidd"
	if curl -fL -o "$DL/fluidd.zip.part" "$FLUIDD_ZIP_URL"; then
		mv "$DL/fluidd.zip.part" "$DL/fluidd.zip"
	else
		[ -f "$DL/fluidd.zip" ] || die "could not download $FLUIDD_ZIP_URL"
		warn "Fluidd download failed, using the cached $DL/fluidd.zip"
	fi
	sudo install -m644 "$DL/fluidd.zip" "$ROOT/tmp/fluidd.zip"

	log "Installing Klipper, Moonraker, KlipperScreen and Fluidd for $u"
	in_chroot "runuser -u $u -- env HOME=$h PATH=/usr/bin:/bin bash -euo pipefail -c '
		cd $h
		mkdir -p printer_data/config printer_data/logs printer_data/gcodes \
			printer_data/systemd printer_data/comms
		for r in Klipper3d/klipper Arksine/moonraker KlipperScreen/KlipperScreen \
			 fluidd-core/fluidd-config; do
			[ -d \$(basename \$r) ] || git clone --progress https://github.com/\$r.git
		done
		mkdir -p fluidd && unzip -q -o /tmp/fluidd.zip -d fluidd

		virtualenv -p python3 klippy-env
		klippy-env/bin/pip install --no-cache-dir -r klipper/scripts/klippy-requirements.txt
		# build the C helper now instead of on the first start
		(cd klipper/klippy && ../../klippy-env/bin/python -c \"import chelper; chelper.get_ffi()\")

		virtualenv -p python3 moonraker-env
		moonraker-env/bin/pip install --no-cache-dir -r moonraker/scripts/moonraker-requirements.txt

		python3 -m venv .KlipperScreen-env
		.KlipperScreen-env/bin/pip install --no-cache-dir -r KlipperScreen/scripts/KlipperScreen-requirements.txt

		ln -sf $h/fluidd-config/fluidd.cfg printer_data/config/fluidd.cfg
		for d in klipper moonraker KlipperScreen fluidd-config; do
			echo \"\$d \$(git -C \$d describe --always --tags) \$(git -C \$d log -1 --format=%cs)\"
		done > klipper-stack-versions.txt
		echo \"fluidd \$(grep -o \"v[0-9][0-9.]*\" fluidd/release_info.json)\" >> klipper-stack-versions.txt
	'
	rm -f /tmp/fluidd.zip"

	write_klipper_stack_files

	in_chroot "
		groupadd -f moonraker-admin
		groupadd -f klipperscreen
		groupadd -f network
		for g in tty netdev network klipperscreen; do
			if getent group \$g >/dev/null; then usermod -aG \$g $u; fi
		done
		gid=\$(getent group moonraker-admin | cut -d: -f3)
		sed -i \"s/@MOONRAKER_GID@/\$gid/\" /etc/polkit-1/rules.d/moonraker.rules
		# nginx (www-data) must reach ~/fluidd; Ubuntu creates homes 0750
		chmod o+x $h
		chown -R $u:$u $h
		rm -f /etc/nginx/sites-enabled/default
		ln -sf /etc/nginx/sites-available/fluidd /etc/nginx/sites-enabled/fluidd
		systemctl enable klipper moonraker nginx KlipperScreen
		systemctl set-default multi-user.target
	"
}

write_klipper_stack_files() {
	local u=$TARGET_USER h=/home/$TARGET_USER

	printf 'KLIPPER_ARGS="%s"\n' \
		"$h/klipper/klippy/klippy.py $h/printer_data/config/printer.cfg -I $h/printer_data/comms/klippy.serial -l $h/printer_data/logs/klippy.log -a $h/printer_data/comms/klippy.sock" |
		sudo tee "$ROOT$h/printer_data/systemd/klipper.env" >/dev/null
	sudo tee "$ROOT/etc/systemd/system/klipper.service" >/dev/null <<EOF
[Unit]
Description=Klipper 3D Printer Firmware SV1
Documentation=https://www.klipper3d.org/
After=network-online.target
Wants=udev.target

[Install]
WantedBy=multi-user.target

[Service]
Type=simple
User=$u
RemainAfterExit=yes
WorkingDirectory=$h/klipper
EnvironmentFile=$h/printer_data/systemd/klipper.env
ExecStart=$h/klippy-env/bin/python \$KLIPPER_ARGS
Restart=always
RestartSec=10
EOF

	sudo tee "$ROOT$h/printer_data/systemd/moonraker.env" >/dev/null <<EOF
MOONRAKER_DATA_PATH="$h/printer_data"
MOONRAKER_ARGS="-m moonraker"
PYTHONPATH="$h/moonraker"
EOF
	sudo tee "$ROOT/etc/systemd/system/moonraker.service" >/dev/null <<EOF
[Unit]
Description=API Server for Klipper SV1
Documentation=https://moonraker.readthedocs.io/
Requires=network-online.target
After=network-online.target

[Install]
WantedBy=multi-user.target

[Service]
Type=simple
User=$u
SupplementaryGroups=moonraker-admin
RemainAfterExit=yes
WorkingDirectory=$h/moonraker
EnvironmentFile=$h/printer_data/systemd/moonraker.env
ExecStart=$h/moonraker-env/bin/python \$MOONRAKER_ARGS
Restart=always
RestartSec=10
EOF

	# Placeholder: Klipper reports a config error until [mcu] is set up,
	# which can be done from Fluidd's configuration editor
	sudo tee "$ROOT$h/printer_data/config/printer.cfg" >/dev/null <<'EOF'
[include fluidd.cfg]

[mcu]
serial: /dev/serial/by-id/<your-mcu-id>

[printer]
kinematics: none
max_velocity: 1000
max_accel: 1000
EOF

	sudo tee "$ROOT$h/printer_data/config/moonraker.conf" >/dev/null <<EOF
[server]
host: 0.0.0.0
port: 7125
klippy_uds_address: $h/printer_data/comms/klippy.sock

[machine]
provider: systemd_dbus

[authorization]
trusted_clients:
    10.0.0.0/8
    127.0.0.0/8
    169.254.0.0/16
    172.16.0.0/12
    192.168.0.0/16
    FC00::/7
    FE80::/10
    ::1/128
cors_domains:
    *.lan
    *.local
    *://localhost
    *://localhost:*
    *://my.mainsail.xyz
    *://app.fluidd.xyz

[octoprint_compat]

[history]

[update_manager]
channel: dev
refresh_interval: 168

[update_manager fluidd]
type: web
channel: stable
repo: fluidd-core/fluidd
path: ~/fluidd

[update_manager fluidd-config]
type: git_repo
primary_branch: master
path: ~/fluidd-config
origin: https://github.com/fluidd-core/fluidd-config.git
managed_services: klipper

[update_manager KlipperScreen]
type: git_repo
path: ~/KlipperScreen
origin: https://github.com/KlipperScreen/KlipperScreen.git
virtualenv: ~/.KlipperScreen-env
requirements: scripts/KlipperScreen-requirements.txt
system_dependencies: scripts/system-dependencies.json
managed_services: KlipperScreen
EOF

	# KlipperScreen's own unit, with BACKEND=W: its start script runs Weston
	# (kiosk shell) when cage is not installed. Weston, not cage: Ubuntu
	# 24.04's cage aborts when the output is rotated through wlr-randr.
	sed -e "s|KS_USER|$u|g" -e "s|KS_ENV|$h/.KlipperScreen-env|g" \
	    -e "s|KS_DIR|$h/KlipperScreen|g" -e "s|KS_BACKEND|W|g" \
		"$ROOT$h/KlipperScreen/scripts/KlipperScreen.service" |
		sudo tee "$ROOT/etc/systemd/system/KlipperScreen.service" >/dev/null
	# The start script backgrounds Weston and execs KlipperScreen, and a
	# restart can leave the old Weston holding the display: the new one then
	# fails at once and the unit restart-loops on a black screen
	sudo mkdir -p "$ROOT/etc/systemd/system/KlipperScreen.service.d"
	printf '[Service]\nExecStartPre=-/usr/bin/pkill -x -u %s weston\nExecStopPost=-/usr/bin/pkill -x -u %s weston\n' "$u" "$u" |
		sudo tee "$ROOT/etc/systemd/system/KlipperScreen.service.d/weston.conf" >/dev/null

	local transform=normal
	[ "$KS_ROTATION" = normal ] || transform=rotate-$KS_ROTATION
	sudo mkdir -p "$ROOT$h/.config"
	sudo tee "$ROOT$h/.config/weston.ini" >/dev/null <<EOF
[core]
idle-time=0

[output]
name=DSI-1
transform=$transform
EOF

	sudo mkdir -p "$ROOT/etc/polkit-1/rules.d"
	# Moonraker: manage units, reboot/shutdown, PackageKit (as its
	# set-policykit-rules.sh writes for polkit >= 0.106)
	sudo tee "$ROOT/etc/polkit-1/rules.d/moonraker.rules" >/dev/null <<EOF
// Allow Moonraker User to manage systemd units, reboot and shutdown
// the system
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.systemd1.manage-units" ||
         action.id == "org.freedesktop.login1.power-off" ||
         action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
         action.id == "org.freedesktop.login1.reboot" ||
         action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
         action.id == "org.freedesktop.login1.halt" ||
         action.id == "org.freedesktop.login1.halt-multiple-sessions" ||
         action.id.startsWith("org.freedesktop.packagekit.")) &&
        subject.user == "$u") {
        // Only allow processes with the "moonraker-admin" supplementary group
        // access
        var regex = "^Groups:.+?\\\\s@MOONRAKER_GID@[\\\\s\\\\0]";
        var cmdpath = "/proc/" + subject.pid.toString() + "/status";
        try {
            polkit.spawn(["grep", "-Po", regex, cmdpath]);
            return polkit.Result.YES;
        } catch (error) {
            return polkit.Result.NOT_HANDLED;
        }
    }
});
EOF
	# KlipperScreen: NetworkManager and power actions (its installer's rules)
	sudo tee "$ROOT/etc/polkit-1/rules.d/KlipperScreen.rules" >/dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") == 0 &&
        subject.isInGroup("network")) {
        return polkit.Result.YES;
    }
});
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.login1.power-off" ||
         action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
         action.id == "org.freedesktop.login1.reboot" ||
         action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
         action.id == "org.freedesktop.login1.halt" ||
         action.id == "org.freedesktop.login1.halt-multiple-sessions" ||
         action.id.startsWith("org.freedesktop.NetworkManager.")) &&
        subject.isInGroup("klipperscreen")) {
        return polkit.Result.YES;
    }
});
EOF

	# Fluidd on port 80, as KIAUH configures nginx (webcam proxies dropped)
	sudo tee "$ROOT/etc/nginx/conf.d/common_vars.conf" >/dev/null <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
EOF
	sudo tee "$ROOT/etc/nginx/conf.d/upstreams.conf" >/dev/null <<'EOF'
upstream apiserver {
    ip_hash;
    server 127.0.0.1:7125;
}
EOF
	sudo tee "$ROOT/etc/nginx/sites-available/fluidd" >/dev/null <<EOF
server {
    listen 80;

    access_log /var/log/nginx/fluidd-access.log;
    error_log /var/log/nginx/fluidd-error.log;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 4;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/x-javascript application/json application/xml;

    root $h/fluidd;
    index index.html;
    server_name _;

    # no upload size limit, no request buffering (large G-code uploads)
    client_max_body_size 0;
    proxy_request_buffering off;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location = /index.html {
        add_header Cache-Control "no-store, no-cache, must-revalidate";
    }

    location /websocket {
        proxy_pass http://apiserver/websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400;
    }

    location ~ ^/(printer|api|access|machine|server)/ {
        proxy_pass http://apiserver\$request_uri;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Scheme \$scheme;
    }
}
EOF
}

stage_rootfs() {
	need curl sha256sum mkfs.ext4 mcopy
	ensure_binfmt
	ls "$DEBS"/linux-image-[0-9]*[0-9]_*.deb >/dev/null 2>&1 || die "no kernel packages, run the kernel stage first"

	if [ -z "$TARGET_PASSWORD" ]; then
		[ -t 0 ] || die "TARGET_PASSWORD is not set"
		read -rsp "Password for $TARGET_USER on the device: " TARGET_PASSWORD; echo
		[ -n "$TARGET_PASSWORD" ] || die "empty password"
	fi

	fetch_ubuntu_base

	log "Creating $ROOTFS_SIZE root filesystem image"
	umount_all
	mkdir -p "$OUT" "$ROOT"
	rm -f "$ROOTFS_IMG"
	truncate -s "$ROOTFS_SIZE" "$ROOTFS_IMG"
	mkfs.ext4 -q -L riva-root "$ROOTFS_IMG"
	sudo mount -o loop "$ROOTFS_IMG" "$ROOT"

	log "Unpacking Ubuntu base"
	sudo tar -xpf "$UBUNTU_BASE_TAR" -C "$ROOT"
	# Plain HTTP until ca-certificates is installed (the base has no CA
	# bundle); apt still verifies the archive signatures
	write_apt_sources http
	host_is_arm64 || sudo cp "$(command -v qemu-aarch64-static)" "$ROOT/usr/bin/" 2>/dev/null || true

	for m in dev dev/pts proc sys; do
		sudo mkdir -p "$ROOT/$m"
		sudo mount --bind "/$m" "$ROOT/$m"
	done
	# Private /run: binding the host's would make systemctl in package
	# scripts talk to the host's systemd
	sudo mount -t tmpfs tmpfs "$ROOT/run"
	sudo rm -f "$ROOT/etc/resolv.conf"
	sudo cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
	# Do not start services inside the chroot
	printf '#!/bin/sh\nexit 101\n' | sudo tee "$ROOT/usr/sbin/policy-rc.d" >/dev/null
	sudo chmod 755 "$ROOT/usr/sbin/policy-rc.d"

	log "Installing packages"
	in_chroot "
		apt-get update
		apt-get -y upgrade
		apt-get -y install --no-install-recommends \
			systemd-sysv systemd-resolved systemd-timesyncd udev kmod dbus \
			sudo openssh-server network-manager wpasupplicant iw rfkill \
			ca-certificates curl wget git nano less locales tzdata \
			python3 python3-venv python3-pip e2fsprogs dosfstools \
			usbutils pciutils bash-completion avahi-daemon \
			rmtfs alsa-utils \
			$EXTRA_PACKAGES
	"
	write_apt_sources https

	log "Installing the kernel"
	sudo mkdir -p "$ROOT/tmp/debs"
	sudo cp "$DEBS"/linux-image-[0-9]*[0-9]_*.deb "$ROOT/tmp/debs/"
	in_chroot "dpkg -i /tmp/debs/*.deb && rm -rf /tmp/debs"

	install_firmware
	write_target_files
	write_usb_gadget
	write_audio

	log "Configuring user, locale and services"
	in_chroot "
		locale-gen $TARGET_LOCALE
		update-locale LANG=$TARGET_LOCALE
		ln -sf /usr/share/zoneinfo/$TARGET_TIMEZONE /etc/localtime
		echo $TARGET_TIMEZONE > /etc/timezone
		groups=\$(for g in sudo dialout tty video input render plugdev audio; do
			getent group \$g >/dev/null && printf '%s,' \$g; done)
		id -u $TARGET_USER >/dev/null 2>&1 || \
			useradd -m -s /bin/bash -G \${groups%,} $TARGET_USER
		# Ubuntu 24.04 starts sshd through socket activation
		systemctl enable ssh.socket
		systemctl enable NetworkManager systemd-resolved systemd-timesyncd riva-resize-rootfs
		systemctl enable rmtfs
		if [ $USB_GADGET = 1 ]; then
			systemctl enable riva-usb-gadget.service serial-getty@ttyGS0.service
		fi
		git clone --depth 1 https://github.com/dw-0/kiauh.git /home/$TARGET_USER/kiauh
		chown -R $TARGET_USER:$TARGET_USER /home/$TARGET_USER
	"
	printf '%s:%s\n' "$TARGET_USER" "$TARGET_PASSWORD" | sudo chroot "$ROOT" chpasswd
	if [ -n "$SSH_PUBKEY" ]; then
		sudo install -d -m700 "$ROOT/home/$TARGET_USER/.ssh"
		sudo install -m600 "$SSH_PUBKEY" "$ROOT/home/$TARGET_USER/.ssh/authorized_keys"
		in_chroot "chown -R $TARGET_USER:$TARGET_USER /home/$TARGET_USER/.ssh"
	fi

	install_klipper_stack

	log "Cleaning up the rootfs"
	in_chroot "apt-get clean; rm -rf /var/lib/apt/lists/*"
	sudo rm -f "$ROOT/usr/sbin/policy-rc.d" "$ROOT/usr/bin/qemu-aarch64-static"
	sudo ln -sf ../run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"

	# Keep a copy of /boot for the images stage, then leave /boot empty as
	# the mount point for the boot filesystem
	sudo rm -rf "$WORK/boot-staging"
	sudo cp -a "$ROOT/boot" "$WORK/boot-staging"
	sudo cp -a "$ROOT/usr/lib/linux-image-"* "$WORK/boot-staging/" 2>/dev/null || true
	sudo find "$ROOT/boot" -mindepth 1 -delete

	umount_all
}

# ----------------------------------------------------------------- images --
stage_images() {
	need mke2fs img2simg
	[ -f "$ROOTFS_IMG" ] || die "no rootfs image, run the rootfs stage first"
	local kver
	kver=$(ls "$WORK/boot-staging" | sed -n 's/^vmlinuz-//p' | sort -V | tail -1)
	[ -n "$kver" ] || die "no kernel found in $WORK/boot-staging"
	local dtb=$WORK/boot-staging/linux-image-$kver/qcom/$DTB_NAME.dtb
	[ -f "$dtb" ] || die "missing $dtb"

	log "Creating boot partition image (kernel $kver)"
	sudo rm -rf "$BOOTFS"
	mkdir -p "$BOOTFS/extlinux" "$BOOTFS/dtbs/qcom"
	sudo cp "$WORK/boot-staging/vmlinuz-$kver" "$BOOTFS/"
	sudo cp "$WORK/boot-staging/config-$kver" "$WORK/boot-staging/System.map-$kver" "$BOOTFS/" 2>/dev/null || true
	sudo cp "$WORK/boot-staging/linux-image-$kver/qcom/"msm8917-*.dtb "$BOOTFS/dtbs/qcom/"
	cat > "$BOOTFS/extlinux/extlinux.conf" <<-EOF
	default ubuntu
	timeout 1

	label ubuntu
		kernel /vmlinuz-$kver
		fdtdir /dtbs
		append $CMDLINE
	EOF
	sudo chown -R "$(id -u):$(id -g)" "$BOOTFS"

	rm -f "$OUT/boot.ext2"
	mke2fs -q -t ext2 -L boot -d "$BOOTFS" "$OUT/boot.ext2" "$BOOTFS_SIZE" || \
		die "boot files do not fit in BOOTFS_SIZE=$BOOTFS_SIZE"
	log "boot.ext2: $(du -sh "$BOOTFS" | cut -f1) used of $BOOTFS_SIZE"

	log "Converting rootfs to a sparse image"
	e2fsck -fy "$ROOTFS_IMG" >/dev/null || true
	img2simg "$ROOTFS_IMG" "$OUT/rootfs.simg"

	cat <<-EOF

	Done. Images in $OUT:
	  boot.ext2     kernel $kver, dtbs, extlinux.conf
	  rootfs.simg   Ubuntu 24.04 root filesystem

	Flash from lk2nd's fastboot (lk2nd already in the boot partition). From the
	stock fastboot, "flash boot" would overwrite lk2nd; check lk2nd first:
	  fastboot getvar max-fetch-size                 # only lk2nd has this
	  fastboot getvar partition-size:$BOOT_PARTITION     # must be >= $BOOTFS_SIZE
	  fastboot flash $BOOT_PARTITION $OUT/boot.ext2
	  fastboot flash userdata $OUT/rootfs.simg  # erases Android data
	  fastboot reboot

	Then: ssh $TARGET_USER@$TARGET_HOSTNAME.local (Wi-Fi), or over the USB cable
	screen /dev/ttyACM0 115200, and run ~/kiauh/kiauh.sh
	EOF
}

stage_clean() {
	umount_all
	log "Removing $WORK (downloads are kept)"
	sudo rm -rf "$KBUILD" "$DEBS"/linux-* "$ROOT" "$BOOTFS" "$OUT" "$WORK/boot-staging"
}

# ------------------------------------------------------------------- main --
[ "$(id -u)" -ne 0 ] || die "run as a normal user; sudo is used where needed"
mkdir -p "$WORK"

case "${1:-all}" in
all)	stage_kernel; stage_rootfs; stage_images ;;
kernel)	stage_kernel ;;
rootfs)	stage_rootfs ;;
images)	stage_images ;;
clean)	stage_clean ;;
*)	die "usage: $0 [all|kernel|rootfs|images|clean]" ;;
esac
