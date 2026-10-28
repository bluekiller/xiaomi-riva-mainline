#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Extract the firmware a mainline kernel needs on the Xiaomi Redmi 5A (riva)
# from partition dumps, without root:
#
#   modem.img   (FAT, "modem" partition, or NON-HLOS.bin from the MIUI ROM)
#               -> wcnss.*, mba.mbn, modem.*, adsp.*, venus.*
#   persist.img (ext4, "persist" partition)
#               -> wlan/prima/WCNSS_qcom_wlan_nv.bin
#
# The output directory mirrors /lib/firmware and can be passed to
# build-riva-ubuntu.sh as FIRMWARE_DIR.
#
# Usage:
#   ./extract-riva-firmware.sh [--fetch] [--dumps DIR] [--out DIR] [--pmos-fallback]
#
#   --fetch          first pull persist/modem/modemst1/modemst2/fsg with
#                    "fastboot fetch" (phone must be in lk2nd's fastboot)
#   --dumps DIR      where the partition images are/go (default: ./riva-dumps)
#   --out DIR        output firmware directory (default: ./riva-fw)
#   --pmos-fallback  use the postmarketOS firmware-xiaomi-riva package (rolex
#                    blobs) for any Wi-Fi file missing from the dumps

set -euo pipefail

DUMPS=./riva-dumps
OUT=./riva-fw
FETCH=0
PMOS_FALLBACK=0
PMOS_APK_URL=https://mirror.postmarketos.org/postmarketos/v24.12/aarch64/firmware-xiaomi-riva-0.1-r0.apk
BACKUP_PARTS=(persist modem modemst1 modemst2 fsg)

log()  { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
	--fetch)	 FETCH=1 ;;
	--dumps)	 DUMPS=$2; shift ;;
	--out)		 OUT=$2; shift ;;
	--pmos-fallback) PMOS_FALLBACK=1 ;;
	-h|--help)	 sed -n '3,26p' "$0"; exit 0 ;;
	*)		 die "unknown option: $1" ;;
	esac
	shift
done

for c in mcopy mdir debugfs python3; do
	command -v "$c" >/dev/null || die "missing $c (sudo apt install mtools e2fsprogs python3)"
done

mkdir -p "$DUMPS" "$OUT/wlan/prima"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------ fetch dumps --
if [ "$FETCH" = 1 ]; then
	command -v fastboot >/dev/null || die "fastboot not found (use Google platform-tools >= 31)"
	fastboot devices | grep -q . || die "no fastboot device; boot lk2nd and hold Volume Down"
	fastboot getvar max-fetch-size 2>&1 | grep -q max-fetch-size: || \
		die "this fastboot server has no fetch support; are you in lk2nd's fastboot?"
	for p in "${BACKUP_PARTS[@]}"; do
		if [ -s "$DUMPS/$p.img" ]; then
			log "$p.img already present, skipping"
			continue
		fi
		log "Fetching $p"
		if ! fastboot fetch "$p" "$DUMPS/$p.img.part"; then
			warn "fastboot fetch failed for $p, trying oem read-partition + get_staged"
			fastboot oem read-partition "$p" && fastboot get_staged "$DUMPS/$p.img.part" || \
				die "could not read $p"
		fi
		mv "$DUMPS/$p.img.part" "$DUMPS/$p.img"
	done
	log "Partition backups are in $DUMPS - keep a copy somewhere safe"
fi

# ------------------------------------------------------ modem partition --
MODEM_IMG=""
for f in "$DUMPS/modem.img" "$DUMPS/NON-HLOS.bin"; do
	[ -s "$f" ] && { MODEM_IMG=$f; break; }
done

if [ -n "$MODEM_IMG" ]; then
	log "Extracting firmware from $MODEM_IMG"
	mdir -i "$MODEM_IMG" ::image >/dev/null 2>&1 || die "$MODEM_IMG has no image/ directory (not a modem FAT image?)"
	mcopy -s -n -i "$MODEM_IMG" ::image "$TMP/"
	# Linux looks files up case-sensitively by these lowercase names
	found=0
	for src in "$TMP"/image/*; do
		name=$(basename "$src" | tr '[:upper:]' '[:lower:]')
		case "$name" in
		wcnss.*|mba.mbn|modem.*|adsp.*|venus.*)
			install -m644 "$src" "$OUT/$name"
			found=$((found + 1)) ;;
		esac
	done
	[ "$found" -gt 0 ] || warn "no wcnss/mba/modem/adsp/venus files in $MODEM_IMG:image/"
else
	warn "no modem.img or NON-HLOS.bin in $DUMPS: modem, wcnss and venus firmware not extracted"
fi

# ---------------------------------------------------- persist partition --
NV=$OUT/wlan/prima/WCNSS_qcom_wlan_nv.bin
if [ -s "$DUMPS/persist.img" ]; then
	log "Searching $DUMPS/persist.img for the Wi-Fi NV file"
	mkdir -p "$TMP/persist"
	# rdump as a normal user: ownership/permission warnings are expected
	debugfs -R "rdump / $TMP/persist" "$DUMPS/persist.img" >/dev/null 2>&1 || true
	nv=$(find "$TMP/persist" -type f -iname 'WCNSS_qcom_wlan_nv.bin' | head -1)
	if [ -n "$nv" ]; then
		install -m644 "$nv" "$NV"
		log "Using NV file from persist:${nv#"$TMP"/persist}"
	else
		warn "WCNSS_qcom_wlan_nv.bin not found in persist.img"
	fi
	# Sensor registry: qcom_sns_reg serves it to the ADSP sensor core, which
	# then offers the SMGR service (proximity/light, accelerometer)
	if [ -s "$TMP/persist/sensors/sns.reg" ]; then
		install -Dm644 "$TMP/persist/sensors/sns.reg" "$OUT/qcom/sensors/sns.reg-xiaomi,riva"
		log "Using sensor registry from persist:/sensors/sns.reg"
	else
		warn "sensors/sns.reg not found in persist.img: no sensors via the ADSP"
	fi
else
	warn "no persist.img in $DUMPS: Wi-Fi NV file not extracted"
fi

# ---------------------------------------------------- pmOS fallback --
if [ "$PMOS_FALLBACK" = 1 ] && { [ ! -s "$OUT/wcnss.mdt" ] || [ ! -s "$NV" ]; }; then
	command -v curl >/dev/null || die "curl is needed for --pmos-fallback"
	log "Fetching postmarketOS firmware-xiaomi-riva (rolex Wi-Fi blobs) for the missing files"
	curl -fsSL "$PMOS_APK_URL" | tar -xz -C "$TMP" lib/firmware/postmarketos 2>/dev/null || \
		die "could not download/unpack $PMOS_APK_URL"
	src=$TMP/lib/firmware/postmarketos
	if [ ! -s "$OUT/wcnss.mdt" ]; then
		cp "$src"/wcnss.* "$OUT/"
		warn "wcnss.* taken from the pmOS package (rolex)"
	fi
	if [ ! -s "$NV" ]; then
		install -m644 "$src/wlan/prima/WCNSS_qcom_wlan_nv.bin" "$NV"
		warn "NV file taken from the pmOS package (rolex calibration, not your unit's)"
	fi
fi

# ------------------------------------------------------------- verify --
log "Checking split firmware images"
python3 -I - "$OUT" <<'EOF'
import os, struct, sys

out = sys.argv[1]
PT_LOAD = 1
ok = True

def check(mdt):
    """Every loadable segment with data must have its .bNN file."""
    global ok
    with open(mdt, 'rb') as f:
        hdr = f.read(64)
    if hdr[:4] != b'\x7fELF':
        print(f'  {os.path.basename(mdt)}: not an ELF header'); ok = False; return
    is64 = hdr[4] == 2
    if is64:
        phoff, = struct.unpack_from('<Q', hdr, 32)
        phentsize, phnum = struct.unpack_from('<HH', hdr, 54)
    else:
        phoff, = struct.unpack_from('<I', hdr, 28)
        phentsize, phnum = struct.unpack_from('<HH', hdr, 42)
    data = open(mdt, 'rb').read()
    base = mdt[:-4]
    missing = []
    for i in range(phnum):
        ph = data[phoff + i * phentsize: phoff + (i + 1) * phentsize]
        if is64:
            p_type, _, p_offset, _, _, p_filesz = struct.unpack_from('<IIQQQQ', ph)
        else:
            p_type, p_offset, _, _, p_filesz = struct.unpack_from('<IIIII', ph)
        if p_type == PT_LOAD and p_filesz:
            seg = f'{base}.b{i:02d}'
            if not os.path.exists(seg) or os.path.getsize(seg) < p_filesz:
                missing.append(os.path.basename(seg))
    name = os.path.basename(mdt)
    if missing:
        print(f'  {name}: MISSING {" ".join(missing)}'); ok = False
    else:
        print(f'  {name}: complete')
    if name == 'modem.mdt':
        check_mpss_span(data, is64, phoff, phentsize, phnum)

# riva DT: mpss_mem reg = <0x0 0x86800000 0x0 0x5500000>
MPSS_SIZE = 0x5500000

def check_mpss_span(data, is64, phoff, phentsize, phnum):
    """qcom_q6v5_mss refuses segments beyond the mpss_mem region."""
    global ok
    lo, hi = None, 0
    for i in range(phnum):
        ph = data[phoff + i * phentsize: phoff + (i + 1) * phentsize]
        if is64:
            p_type, p_flags, _, _, p_paddr, _, p_memsz = struct.unpack_from('<IIQQQQQ', ph)
        else:
            p_type, _, _, p_paddr, _, p_memsz, p_flags = struct.unpack_from('<IIIIIII', ph)
        # same filter as q6v5_phdr_valid(): loadable, not the hash segment
        if p_type != PT_LOAD or not p_memsz or (p_flags & (7 << 24)) == (2 << 24):
            continue
        lo = p_paddr if lo is None else min(lo, p_paddr)
        hi = max(hi, p_paddr + p_memsz)
    span = hi - (lo or 0)
    if span > MPSS_SIZE:
        print(f'  modem.mdt: needs 0x{span:x} bytes, more than mpss_mem (0x{MPSS_SIZE:x}): '
              'enlarge mpss_mem in the DT'); ok = False
    else:
        print(f'  modem.mdt: fits mpss_mem (0x{span:x} of 0x{MPSS_SIZE:x} bytes)')

for name in ('wcnss.mdt', 'modem.mdt', 'adsp.mdt', 'venus.mdt'):
    p = os.path.join(out, name)
    if os.path.exists(p):
        check(p)
    else:
        print(f'  {name}: absent')
print('  mba.mbn: ' + ('present' if os.path.exists(os.path.join(out, 'mba.mbn')) else 'absent'))
nv = os.path.join(out, 'wlan/prima/WCNSS_qcom_wlan_nv.bin')
print('  wlan/prima/WCNSS_qcom_wlan_nv.bin: ' + ('present' if os.path.exists(nv) else 'absent'))
sys.exit(0 if ok else 1)
EOF

wifi="no"; [ -s "$OUT/wcnss.mdt" ] && [ -s "$NV" ] && wifi="yes"
modem="no"; [ -s "$OUT/mba.mbn" ] && [ -s "$OUT/modem.mdt" ] && modem="yes"
adsp="no"; [ -s "$OUT/adsp.mdt" ] && adsp="yes"
venus="no"; [ -s "$OUT/venus.mdt" ] && venus="yes"

cat <<EOF

Firmware in $OUT:
  Wi-Fi (wcnss + NV):         $wifi
  Modem (mba + modem):        $modem
  Audio DSP (adsp):           $adsp
  Video (venus):              $venus

Use it with the image builder, e.g. in ~/riva-build/riva.conf:
  FIRMWARE_DIR=$(cd "$OUT" && pwd)
EOF
