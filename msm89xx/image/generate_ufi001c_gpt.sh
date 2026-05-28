#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Generate GPT image fragment for UFI-001C eMMC (7471104 x 512B sectors).

set -e

OUTFILE=${1:-ufi001c-gpt_both0.bin}
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
IMG="${TMPDIR}/gpt.img"

# Total size in 512B sectors
TOT_SECTORS=7471104

# GPT boundaries
FIRST_LBA=34
LAST_LBA=7471070

ROOTFSDATA_START=2133088
ROOTFSDATA_SIZE=$((LAST_LBA - ROOTFSDATA_START + 1))

[ ${ROOTFSDATA_SIZE} -gt 0 ] || { echo "ERROR: No space for rootfs_data"; exit 1; }

truncate -s $((TOT_SECTORS * 512)) "${IMG}"

sfdisk "${IMG}" <<EOF
label: gpt
label-id: 98101B32-BBE2-4BF2-A06E-2BB33D000C20
unit: sectors
first-lba: ${FIRST_LBA}
last-lba: ${LAST_LBA}
sector-size: 512

gpt.img1  : start=131072, size=131072, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="modem"
gpt.img2  : start=262144, size=1024, type=DEA0BA2C-CBDD-4805-B4F9-F428251C3E98, name="sbl1"
gpt.img3  : start=263168, size=1024, type=DEA0BA2C-CBDD-4805-B4F9-F428251C3E98, name="sbl1bak"
gpt.img4  : start=264192, size=2048, type=400FFDCD-22E0-47E7-9A23-F16ED9382388, name="aboot"
gpt.img5  : start=266240, size=2048, type=400FFDCD-22E0-47E7-9A23-F16ED9382388, name="abootbak"
gpt.img6  : start=268288, size=1024, type=098DF793-D712-413D-9D4E-89D711772228, name="rpm"
gpt.img7  : start=269312, size=1024, type=098DF793-D712-413D-9D4E-89D711772228, name="rpmbak"
gpt.img8  : start=270336, size=1024, type=A053AA7F-40B8-4B1C-BA08-2F68AC71A4F4, name="tz"
gpt.img9  : start=271360, size=1024, type=A053AA7F-40B8-4B1C-BA08-2F68AC71A4F4, name="tzbak"
gpt.img10 : start=272384, size=1024, type=E1A6A689-0C8D-4CC6-B4E8-55A4320FBD8A, name="hyp"
gpt.img11 : start=273408, size=1024, type=E1A6A689-0C8D-4CC6-B4E8-55A4320FBD8A, name="hypbak"
gpt.img12 : start=274432, size=2048, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="pad"
gpt.img13 : start=276480, size=3072, type=EBBEADAF-22C9-E33B-8F5D-0E81686A68CB, name="modemst1"
gpt.img14 : start=279552, size=3072, type=0A288B1F-22C9-E33B-8F5D-0E81686A68CB, name="modemst2"
gpt.img15 : start=282624, size=2048, type=20117F86-E985-4357-B9EE-374BC1D8487D, name="misc"
gpt.img16 : start=284672, size=2, type=57B90A16-22C9-E33B-8F5D-0E81686A68CB, name="fsc"
gpt.img17 : start=284674, size=16, type=2C86E742-745E-4FDD-BFD8-B6A7AC638772, name="ssd"
gpt.img18 : start=284690, size=20480, type=20117F86-E985-4357-B9EE-374BC1D8487D, name="splash"
gpt.img19 : start=393216, size=64, type=20A0C19C-286A-42FA-9CE7-F64C3226A794, name="DDR"
gpt.img20 : start=393280, size=3072, type=638FF8E2-22C9-E33B-8F5D-0E81686A68CB, name="fsg"
gpt.img21 : start=396352, size=32, type=303E6AC3-AF15-4C54-9E9B-D9A8FBECF401, name="sec"
gpt.img22 : start=396384, size=131072, type=20117F86-E985-4357-B9EE-374BC1D8487D, name="boot"
gpt.img23 : start=527456, size=1540096, type=1B81E7E6-F50D-419B-A739-2AEEF8DA3335, name="rootfs"
gpt.img24 : start=2067552, size=65536, type=6C95E238-E343-4BA8-B489-8681ED22AD0B, name="persist"
gpt.img25 : start=${ROOTFSDATA_START}, size=${ROOTFSDATA_SIZE}, type=1B81E7E6-F50D-419B-A739-2AEEF8DA3335, name="rootfs_data"
EOF

# Assemble gpt_both0.bin: primary header+entries + backup entries + backup header
dd if="${IMG}" of="${OUTFILE}" bs=512 count=34
dd if="${IMG}" bs=512 skip=2 count=32 >> "${OUTFILE}"
dd if="${IMG}" bs=512 skip=$((TOT_SECTORS - 1)) count=1 >> "${OUTFILE}"

echo "Generated: ${OUTFILE}"
