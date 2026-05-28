#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Flash OpenWrt to UFI-001C entirely via EDL.
# Prerequisites: edl
# Usage: run from the build output directory (bin/targets/...)

set -euo pipefail

# Must match TOT_SECTORS in generate_ufi001c_gpt.sh
TOT_SECTORS=7471104

# Temp files - cleaned up on exit
firmware_tmp=""
gpt_tmp=""
trap 'rm -rf "$firmware_tmp" "$gpt_tmp"' EXIT

find_image() {
    local dir="$1" pattern="$2" file
    file=$(find "$dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null | head -n 1 || true)
    if [[ -z "${file:-}" ]]; then
        echo "[-] Error: Image not found with pattern: $pattern" >&2
        return 1
    fi
    echo "$file"
}

require_file() {
    local path="$1" description="$2"
    if [[ ! -f "$path" ]]; then
        echo "[-] Error: Required $description not found: $path" >&2
        return 1
    fi
    echo "$path"
}

unquote_path() {
    local path="$1"
    if [[ "$path" == \"*\" && "$path" == *\" ]]; then
        path="${path:1:${#path}-2}"
    elif [[ "$path" == \'*\' && "$path" == *\' ]]; then
        path="${path:1:${#path}-2}"
    fi
    echo "$path"
}

echo "=== OpenWrt UFI-001C EDL Flash Script ==="
echo

# Detect required OpenWrt images.
echo "[*] Detecting OpenWrt images..."
gpt_path=$(find_image "." "*-ufi001c-gpt_both0.bin") || exit 1
gpt_prefix="${gpt_path%-ufi001c-gpt_both0.bin}"
boot_path=$(require_file "${gpt_prefix}-squashfs-boot.img" "boot image")     || exit 1
rootfs_path=$(require_file "${gpt_prefix}-squashfs-system.img" "rootfs image") || exit 1

echo "[+] GPT:    $(basename "$gpt_path")"
echo "[+] Boot:   $(basename "$boot_path")"
echo "[+] Rootfs: $(basename "$rootfs_path")"

# Detect firmware ZIP and extract .mbn files.
echo
echo "=== Firmware bundle (.zip) ==="
zip_path="${gpt_prefix}-firmware.zip"

if [[ -f "$zip_path" ]]; then
    echo "[*] Found firmware ZIP: $(basename "$zip_path")"
    firmware_tmp="$(mktemp -d)"
    echo "[*] Extracting .mbn files..."
    unzip -q -j -d "$firmware_tmp" "$zip_path" "*.mbn" || {
        echo "[-] Error: Failed to extract .mbn files from ZIP"
        exit 1
    }
    firmware_dir="$firmware_tmp"
else
    echo "[!] No matching firmware ZIP found: $zip_path"
    echo "=== Qualcomm Firmware Directory (fallback) ==="
    read -e -r -p "Drag the folder with .mbn files (aboot, hyp, rpm, sbl1, tz): " firmware_dir
    firmware_dir="$(unquote_path "$firmware_dir")"
fi

if [[ -z "$firmware_dir" || ! -d "$firmware_dir" ]]; then
    echo "[-] Error: Invalid firmware directory: $firmware_dir"
    exit 1
fi

echo "[*] Using firmware directory: $firmware_dir"
echo

# Verify required .mbn files.
echo "[*] Verifying firmware partitions..."
missing_mbn=false
for part in aboot hyp rpm sbl1 tz; do
    if [[ ! -f "$firmware_dir/${part}.mbn" ]]; then
        echo "[-] ${part}.mbn not found"
        missing_mbn=true
    else
        echo "[+] ${part}.mbn"
    fi
done

if [[ "$missing_mbn" == true ]]; then
    echo "[-] ERROR: Missing required .mbn files."
    exit 1
fi

# Confirm before flashing.
rootfs_flash="$rootfs_path"
echo
echo "[!] WARNING: This repartitions a UFI-001C and can permanently destroy data."
echo "[!] Make a complete backup of the device before continuing."
read -r -p "Continue with flashing? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "[!] Cancelled"
    exit 0
fi

mkdir -p saved

# Backup critical partitions.
echo
echo "=== Partition Backup (EDL) ==="
for n in modem fsc fsg modemst1 modemst2 persist sec; do
    echo "[*] Backing up $n..."
    if ! edl r "$n" "saved/$n.bin"; then
        echo "[-] Error backing up $n"
        exit 1
    fi
done

# Flash new GPT via raw sector writes first, so all subsequent flashes
# use the correct partition offsets from the OpenWrt GPT.
# gpt_both0.bin layout: [34 sectors primary] [32 sectors backup entries] [1 sector backup header]
echo
echo "=== Flashing GPT (EDL) ==="
gpt_tmp="$(mktemp -d)"
dd if="$gpt_path" bs=512 count=34         of="${gpt_tmp}/primary.bin"        2>/dev/null
dd if="$gpt_path" bs=512 skip=34 count=32 of="${gpt_tmp}/backup_entries.bin" 2>/dev/null
dd if="$gpt_path" bs=512 skip=66 count=1  of="${gpt_tmp}/backup_header.bin"  2>/dev/null
edl ws 0                      "${gpt_tmp}/primary.bin"        || { echo "[-] Error flashing primary GPT"; exit 1; }
edl ws $((TOT_SECTORS - 33)) "${gpt_tmp}/backup_entries.bin" || { echo "[-] Error flashing GPT backup entries"; exit 1; }
edl ws $((TOT_SECTORS - 1))  "${gpt_tmp}/backup_header.bin"  || { echo "[-] Error flashing GPT backup header"; exit 1; }

# Flash firmware, boot, rootfs (new GPT now active, correct offsets).
echo
echo "=== Flashing Firmware + OpenWrt images (EDL) ==="
for pair in aboot:abootbak hyp:hypbak rpm:rpmbak sbl1:sbl1bak tz:tzbak; do
    part="${pair%%:*}"
    backup_part="${pair##*:}"
    edl w "$part" "$firmware_dir/${part}.mbn" || { echo "[-] Error flashing $part"; exit 1; }
    edl w "$backup_part" "$firmware_dir/${part}.mbn" || echo "[!] Warning: Failed to flash $backup_part"
done
edl w boot   "$boot_path"    || { echo "[-] Error flashing boot";   exit 1; }
edl w rootfs "$rootfs_flash" || { echo "[-] Error flashing rootfs"; exit 1; }
edl e rootfs_data            || { echo "[-] Error erasing rootfs_data"; exit 1; }

# Restore backed-up partitions.
echo
echo "=== Partition Restoration (EDL) ==="
for n in modem fsc fsg modemst1 modemst2 persist sec; do
    if [[ -f "saved/$n.bin" ]]; then
        echo "[*] Restoring $n..."
        edl w "$n" "saved/$n.bin" || { echo "[-] Error restoring $n"; exit 1; }
    else
        echo "[-] Error: Missing required restore backup for $n"
        exit 1
    fi
done

echo
echo "[+] Flash completed successfully"
echo "[*] Rebooting..."
edl reset || { echo "[-] Error resetting device"; exit 1; }
