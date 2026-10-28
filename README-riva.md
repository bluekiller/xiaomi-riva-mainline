# Ubuntu 24.04 + Klipper on the Xiaomi Redmi 5A (riva)

Scripts to build a mainline Linux 7.1.3 kernel and an Ubuntu 24.04 root
filesystem for the Xiaomi Redmi 5A (codename **riva**, Qualcomm MSM8917), boot
it with [lk2nd], and run the Klipper 3D-printer stack (preinstalled; [KIAUH]
is included for maintenance).

> **Status:** the kernel build is tested. The rootfs build, the boot flow and
> USB OTG on real hardware are **not tested yet** — see
> [Known issues](#known-issues).

## Contents

| File | Purpose |
|---|---|
| `build-riva-ubuntu.sh` | Builds the kernel `.deb`, the Ubuntu rootfs and the two flashable images |
| `extract-riva-firmware.sh` | Backs up the phone's partitions and extracts the firmware it needs, without root |
| `README-riva.md` | This file |

Kernel source: `/home/pfwu/linux-msm89x7` ([msm89x7-mainline/linux], branch
`msm89x7/7.1.3`), including the uncommitted riva USB work described in
[Kernel changes](#kernel-changes).

## How it boots

```
 boot partition
 ├─ first 512 KiB    lk2nd (second-stage bootloader, replaces the stock kernel)
 │        │  finds the ext2 /extlinux/extlinux.conf after itself
 │        ▼
 └─ rest             boot.ext2: vmlinuz, dtbs/qcom/msm8917-*.dtb, extlinux.conf
          │  lk2nd picks msm8917-xiaomi-riva.dtb, patches the panel and
          │  touchscreen nodes for the detected panel, starts the kernel
          ▼
 userdata partition  rootfs.simg: Ubuntu 24.04 (root=PARTLABEL=userdata, no initramfs)
```

lk2nd splits `boot` into its own 512 KiB and the rest; in **lk2nd's** fastboot,
`fastboot flash boot` writes only the rest. Linux sees the whole partition and
mounts the boot filesystem at `/boot` with a loop mount at offset 512 KiB.

`cache`, `modem`, `persist` and the other firmware/calibration partitions are
never written. (Set `BOOT_PARTITION=cache` to use `cache` instead.)

## Prerequisites

1. **Unlocked bootloader.** Xiaomi requires the Mi Unlock tool (Windows) and a
   Mi account; there is usually a waiting period. Unlocking wipes the phone.
2. **Host packages** (Ubuntu/Debian):
   ```bash
   sudo apt install build-essential bc bison flex libssl-dev dpkg-dev debhelper libdw-dev libelf-dev rsync kmod cpio gcc-aarch64-linux-gnu qemu-user-static binfmt-support e2fsprogs dosfstools mtools android-sdk-libsparse-utils curl python3
   ```
3. **fastboot ≥ 31** from Google's [platform-tools] (older versions lack
   `fastboot fetch`):
   ```bash
   export PATH=$HOME/platform-tools:$PATH
   ```
4. **lk2nd:** `lk2nd-msm8952.img` from the [lk2nd releases][lk2nd-releases]
   (the msm8952 build covers MSM8917 and includes riva's panel/touchscreen
   table).
5. **sudo** on the build machine for the rootfs stage (loop mounts and chroot).
   Root on the phone is **not** needed.

## Step by step

### 1. Flash lk2nd

Boot the phone into stock fastboot (Power + Volume Down):

```bash
fastboot flash boot lk2nd-msm8952.img
```

```bash
fastboot reboot
```

Hold **Volume Down** while it restarts to stay in lk2nd's fastboot, and check:

```bash
fastboot getvar product
```

### 2. Back up the phone and extract the firmware

```bash
./extract-riva-firmware.sh --fetch
```

This saves `persist`, `modem`, `modemst1`, `modemst2` and `fsg` to
`./riva-dumps/` and builds `./riva-fw/`. **Keep a copy of `riva-dumps/`** —
`persist` holds this unit's calibration data and cannot be downloaded
anywhere.

If the summary reports `Wi-Fi: no`, rerun with `--pmos-fallback` to use the
postmarketOS Wi-Fi files (taken from the sibling Redmi 4A, rolex).

### 3. Check the boot partition size

The boot image needs 32 MiB in the part of `boot` after lk2nd. lk2nd's
fastboot reports that size:

```bash
fastboot getvar partition-size:boot
```

### 4. Configure

Create `~/riva-build/riva.conf`:

```sh
TARGET_USER=pi
TARGET_PASSWORD=choose-one
TARGET_HOSTNAME=riva
TARGET_TIMEZONE=Asia/Taipei
WIFI_SSID="YourNetwork"
WIFI_PSK="YourPassword"
SSH_PUBKEY=$HOME/.ssh/id_ed25519.pub
FIRMWARE_DIR=/path/to/riva-fw
```

### 5. Build

```bash
./build-riva-ubuntu.sh
```

Output in `~/riva-build/out/`:

| File | Flash to | Contents |
|---|---|---|
| `boot.ext2` | `boot` (after lk2nd) | kernel, device trees, `extlinux.conf` |
| `rootfs.simg` | `userdata` | Ubuntu 24.04 root filesystem (sparse image) |

### 6. Flash and boot

In **lk2nd's** fastboot (this erases Android's `userdata`). Flashing `boot`
from the *stock* fastboot would overwrite lk2nd itself, so check first that
lk2nd is answering — this variable exists only in lk2nd:

```bash
fastboot getvar max-fetch-size
```

```bash
fastboot flash boot ~/riva-build/out/boot.ext2
```

```bash
fastboot flash userdata ~/riva-build/out/rootfs.simg
```

```bash
fastboot reboot
```

### 7. First boot

The root filesystem grows to fill `userdata` automatically. SSH is enabled
(password or `SSH_PUBKEY`). Connect over Wi-Fi; the phone announces itself as
`riva.local` with mDNS (avahi):

```bash
ssh pi@riva.local
```

Or plug the phone into a PC with a normal USB cable (not the OTG adapter). It
appears as a USB serial port with a login prompt — useful when Wi-Fi is not
up yet:

```bash
screen /dev/ttyACM0 115200
```

The serial console starts with userspace, so it does not show kernel boot
messages, and it is unavailable while the printer is attached (host mode).

### 8. Klipper, Moonraker, Fluidd and KlipperScreen

They are preinstalled (`KLIPPER_STACK=1`) the way KIAUH installs them, so
KIAUH (`~/kiauh/kiauh.sh`) and Fluidd's update manager can maintain them:

| Component | Where | Service |
|---|---|---|
| Klipper | `~/klipper`, venv `~/klippy-env` | `klipper` |
| Moonraker | `~/moonraker`, venv `~/moonraker-env`, port 7125 | `moonraker` |
| Fluidd | `~/fluidd` (+ macros from `~/fluidd-config`), nginx on port 80 | `nginx` |
| KlipperScreen | `~/KlipperScreen`, venv `~/.KlipperScreen-env` | `KlipperScreen` |

Configuration and logs are in `~/printer_data` (`config/printer.cfg`,
`config/moonraker.conf`, `logs/`). The versions that were installed are in
`~/klipper-stack-versions.txt`.

Open **Fluidd** at `http://riva.local/` (or the phone's IP). Klipper reports a
configuration error until `[mcu]` in `printer.cfg` is filled in (next step);
edit it in Fluidd's configuration page.

**KlipperScreen** runs on Wayland: its service (`BACKEND=W`) starts Weston
with the kiosk shell on the phone's DRM display, no X server. The rotation
is in `~/.config/weston.ini` (`transform=rotate-270` by default, landscape;
build setting `KS_ROTATION`); edit it and `sudo systemctl restart
KlipperScreen`. cage is not used: Ubuntu 24.04's cage aborts when the output
is rotated with `wlr-randr`.

The arm/avr toolchains for building MCU firmware (`make menuconfig` in
`~/klipper`) are included unless `KLIPPER_MCU_TOOLCHAINS=0`.

### 9. Connect the printer

Plug the printer mainboard in through a micro-USB **OTG adapter** (it grounds
the ID pin, which switches the phone to USB host mode), then:

```bash
ls /dev/serial/by-id/
```

Use that path as `serial:` in the `[mcu]` section of `printer.cfg`.

## build-riva-ubuntu.sh reference

```
./build-riva-ubuntu.sh [all|kernel|rootfs|images|clean]
```

| Stage | What it does |
|---|---|
| `kernel` | Downloads the postmarketOS msm89x7 kernel config, enables the Klipper USB serial drivers and `CHARGER_BQ256XX`, builds `linux-image-7.1.3-msm89x7_*.deb` with `bindeb-pkg` |
| `rootfs` | Unpacks the latest `ubuntu-base-24.04.*-arm64` (SHA256-checked) into a 6 GiB ext4 image, installs packages in a qemu chroot, installs the kernel and firmware, creates the user, configures Wi-Fi, SSH, fstab and the first-boot resize, clones KIAUH, installs the Klipper stack |
| `images` | Creates `boot.ext2` and `rootfs.simg` |
| `clean` | Removes build output (downloads are kept) |
| `all` | `kernel` + `rootfs` + `images` (default) |

Settings come from the environment or `~/riva-build/riva.conf`:

| Variable | Default | Meaning |
|---|---|---|
| `WORK` | `~/riva-build` | Build directory |
| `KERNEL_SRC` | `/home/pfwu/linux-msm89x7` | Kernel tree (must be clean of in-tree build output) |
| `TARGET_USER` / `TARGET_PASSWORD` | `pi` / prompted | Login on the phone (in `sudo`, `dialout`, `video`, `input` groups) |
| `TARGET_HOSTNAME` | `riva` | Hostname |
| `TARGET_TIMEZONE` / `TARGET_LOCALE` | `Etc/UTC` / `en_US.UTF-8` | |
| `WIFI_SSID` / `WIFI_PSK` | empty | NetworkManager Wi-Fi profile |
| `SSH_PUBKEY` | empty | Public key installed for `TARGET_USER` |
| `USB_GADGET` | `1` | USB serial console (`ttyGS0` on the phone, `ttyACM*` on the PC) when plugged into a PC |
| `FIRMWARE_DIR` | empty | Folder copied into `/lib/firmware` (output of `extract-riva-firmware.sh`) |
| `MODEM_IMG` / `NV_BIN` | empty | Alternative to `FIRMWARE_DIR`: a modem FAT image and the Wi-Fi NV file |
| `UBUNTU_MIRROR` | `mirrors.tuna.tsinghua.edu.cn/ubuntu-ports` | arm64 package mirror (no scheme) for the build and the image's apt sources; upstream is `ports.ubuntu.com/ubuntu-ports` |
| `KLIPPER_STACK` | `1` | Preinstall Klipper, Moonraker, Fluidd and KlipperScreen; `0` for a bare system |
| `KLIPPER_MCU_TOOLCHAINS` | `1` | Also install avr/arm-none-eabi toolchains, `stm32flash`, `dfu-util` (~700 MB) |
| `KS_ROTATION` | `270` | KlipperScreen rotation in Weston: `normal`, `90`, `180` or `270` |
| `FLUIDD_ZIP_URL` | latest GitHub release | Fluidd release to install (cached in `downloads/`) |
| `PIP_INDEX_URL` | `https://pypi.tuna.tsinghua.edu.cn/simple` | PyPI index written to the device's `/etc/pip.conf` (also used by KIAUH's venvs); empty for pip's default |
| `UBUNTU_BASE_DIR` | TUNA `ubuntu-cdimage/ubuntu-base/releases/24.04/release` | Where the Ubuntu base tarball and `SHA256SUMS` come from |
| `BOOT_PARTITION` | `boot` | Where `boot.ext2` goes: `boot` (after lk2nd) or `cache` |
| `LK2ND_SIZE` | `524288` | Size of lk2nd at the start of `boot` (the `/boot` loop-mount offset) |
| `ROOTFS_SIZE` / `BOOTFS_SIZE` | `6G` / `32M` (`64M` for `cache`) | Image sizes |
| `CMDLINE` | `root=PARTLABEL=userdata rootwait rw console=tty0` | Kernel command line |
| `EXTRA_PACKAGES` | empty | More Ubuntu packages to install |

The GPU microcode (`qcom/a300_pm4.fw`, `qcom/a300_pfp.fw`) is always
downloaded from linux-firmware.

## extract-riva-firmware.sh reference

```
./extract-riva-firmware.sh [--fetch] [--dumps DIR] [--out DIR] [--pmos-fallback]
```

| Option | Meaning |
|---|---|
| `--fetch` | Pull the partitions with `fastboot fetch` (phone in lk2nd's fastboot) |
| `--dumps DIR` | Partition images (default `./riva-dumps`); a `NON-HLOS.bin` from the MIUI fastboot ROM can stand in for `modem.img` |
| `--out DIR` | Output firmware folder (default `./riva-fw`) |
| `--pmos-fallback` | Fill missing Wi-Fi files from postmarketOS `firmware-xiaomi-riva` |

It checks that every firmware segment (`.bNN`) listed in each `.mdt` header is
present and complete.

## Firmware

| Function | Files (in `/lib/firmware`) | Needed for Klipper? |
|---|---|---|
| Wi-Fi (WCN3620) | `wcnss.mdt`, `wcnss.b??`, `wlan/prima/WCNSS_qcom_wlan_nv.bin` | **Yes** |
| GPU (Adreno 308) | `qcom/a300_pm4.fw`, `qcom/a300_pfp.fw` | For KlipperScreen |
| Modem | `mba.mbn`, `modem.mdt`, `modem.b??` | No (cellular) |
| Audio DSP (ADSP) | `adsp.mdt`, `adsp.b??` | No (needed for sound) |
| Video codec (venus) | `venus.mdt`, `venus.b??` | No |

Display, touchscreen, charger, fuel gauge, USB and eMMC need no firmware
files. The signed images must come from riva (secure boot checks the OEM
signature).

## Audio

The speaker is driven by an AW8738 amplifier on the codec's HPHR output; the
codec is reached through the ADSP (APR over SMD), so sound needs the ADSP
firmware above; without it the `adsp` remoteproc stays offline and the sound
card never probes. (The modem has an `apr_audio_svc` channel too, but the
MSM8917 DT binds APR on the ADSP edge.) The image also enables `rmtfs`,
which serves the modem's `modemst1`/`modemst2`/`fsg` partitions so the modem
stays up for cellular use.

When the card appears, udev runs `riva-audio`, which routes the default PCM
to the speaker (left and right mixed, since the speaker is mono). Switch by
hand with:

```bash
sudo riva-audio headphones   # or: speaker
speaker-test -c2 -t wav -l1
```

The riva DT routes the speaker amplifier (and the headphone switch) from
the codec's `HPH_R`/`HPH_L` output pins rather than the `HPHR`/`HPHL` muxes
in front of the PAs, as the shared wingtech routing does. With the mux
routing, DAPM kept the AW8738 on permanently while the HPH PA powered up and
down behind it, which popped on every stream open and close; now the
amplifier switches on after the PA and off before it.

To keep your own mixer settings across reboots, run `sudo alsactl store`;
the saved state is restored after `riva-audio` and overrides it.

Check the chain if there is no card (`aplay -l` empty):

```bash
grep . /sys/class/remoteproc/*/name /sys/class/remoteproc/*/state  # adsp: running
systemctl status rmtfs
sudo dmesg | grep -i -E 'q6|apr|wcd|aw8738|remoteproc'
```

## Kernel changes

Uncommitted in `/home/pfwu/linux-msm89x7`:

- **riva-usb v2** by Reza Kurniawan ([patchew][riva-usb]): the bq256xx
  charger driver reports VBUS through extcon; the riva DT enables USB.
- **USB OTG VBUS:** a `usb-otg-vbus` regulator in `bq256xx_charger.c` (boost
  mode via REG01 OTG_CONFIG, 4.85–5.30 V, 0.5/1.2 A), the matching
  `bq256xx.yaml` binding, and in the riva DT `dr_mode = "otg"` with
  `vbus-supply`.
- **Wi-Fi packet loss:** with the default wcn36xx HAL config the riva
  WCN3620 dropped ~86% of packets (slow links, DHCP timeouts). `smd.c` gains
  a `wcn3610_cfg` module parameter that sends the WCN3610 config from the
  upstream WCN3610 series instead (dynamic RA start rate 0, BTC execution
  mode 2, no firmware powersave); the image enables it in
  `/etc/modprobe.d/wcn36xx.conf`. `ra_start_rate` and `btc_mode` override
  single values for testing.
- **Sensors via the ADSP:** the STK3311 proximity/light sensor, BMA253
  accelerometer and magnetometer sit on BLSP1 I2C4, which the ADSP owns:
  enabling `&blsp1_i2c4` from Linux resets the phone (tested 2026-10-27), so
  it stays disabled. With the ADSP running and the sensor registry from
  `persist:/sensors/sns.reg` installed as
  `/lib/firmware/qcom/sensors/sns.reg-xiaomi,riva` (served by `qcom_sns_reg`),
  the ADSP's SMGR service appears and `qcom_smgr` registers
  `qcom-smgr-prox`, `qcom-smgr-accel` and `qcom-smgr-mag` IIO devices
  (buffered reads only). Proximity is near/far: 0 or 65536 (1.0 in Q16).
  Ambient light is the prox-light sensor's secondary SMGR data type;
  `qcom_smgr` was extended to stream it (report ID `sensor id | 0x80`) and
  `qcom_smgr_prox` registers it as `qcom-smgr-light` (`in_illuminance`, lux).
  IIO device numbers change between boots: look devices up by `name`.

Host/device role selection relies on the USB controller's own ID detection
(OTGSC). The ID pin is wired directly to the SoC (ball AB39 `USB2_HS_ID`);
whether the controller sees it is unverified — see below.

## Known issues

- **Untested on hardware:** lk2nd booting extlinux from the rest of `boot`,
  the `/boot` loop mount, the
  Ubuntu rootfs, USB OTG, and audio (rmtfs and the `riva-audio` mixer
  routing).
- **OTG detection (fixed).** The micro-USB ID pin is wired only to the
  28nm USB PHY (`USB2_HS_ID`), so the controller's OTGSC ID bit never
  changes. `phy-qcom-usb-hs-28nm` now polls the PHY's IDDIG status every
  500 ms (`qcom,id-detect`, only while the PHY is clocked and powered, and
  re-arming the IDDIG sources after every PHY reset) and reports it as an
  extcon; the riva DT uses it as the controller's ID extcon. Plugging an
  OTG adapter switches to host and turns on the bq25601 5 V boost within
  about half a second; unplugging switches back to the gadget console.
  Check with `cat /sys/class/extcon/*/name /sys/class/extcon/*/state` and
  `cat /sys/devices/platform/soc@0/78db000.usb/ci_hdrc.0/role`.
  Never read the PHY registers through `/dev/mem`: it froze the phone.
- **Single USB port, charging in host mode.** With the printer attached
  there is no USB serial console (use Wi-Fi/SSH). The OTG 5 V boost only
  starts when nothing else powers VBUS: if the printer board (or a powered
  OTG Y-cable) feeds 5 V, the phone stays in host mode **and charges** from
  it ("External VBUS present, OTG boost not started" in dmesg). Limitation:
  external power connected *after* the boost started is not detected
  (the charger cannot see its input while boosting); replug the cable.
- **Old qemu.** Ubuntu 20.04 ships qemu 4.2; if `apt` crashes inside the
  chroot, install a newer `qemu-user-static`.
- **arm64 build hosts.** On an arm64 machine the rootfs runs natively and no
  qemu is needed. Never register a `qemu-aarch64` binfmt handler there: every
  program on the host would match it (and so would its arm64 interpreter), so
  every program launch fails with "Too many levels of symbolic links" until
  the handler is removed or the machine reboots. The build script detects an
  arm64 host and skips the registration.

## Recovery

- lk2nd's fastboot (hold Volume Down) is always available to reflash `boot`
  or `userdata`.
- After kernel changes: `./build-riva-ubuntu.sh kernel`, then `rootfs` and
  `images`, and reflash.
- Back to Android: flash `boot.img` from the MIUI fastboot ROM to `boot`, or
  run the ROM's flash script. Restore `persist` from `riva-dumps/persist.img`
  only if it was damaged.

[lk2nd]: https://github.com/msm8916-mainline/lk2nd
[lk2nd-releases]: https://github.com/msm8916-mainline/lk2nd/releases
[KIAUH]: https://github.com/dw-0/kiauh
[platform-tools]: https://developer.android.com/tools/releases/platform-tools
[msm89x7-mainline/linux]: https://github.com/msm89x7-mainline/linux
[riva-usb]: https://patchew.org/linux/20260912-riva-usb-v2-0-997fe0171ee5@gmail.com/
