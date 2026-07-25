#!/bin/bash
# EXPERIMENTAL: enable the IR camera (ST VD55G1 behind ACPI TBE20A1) on the
# X1C Gen 14. Three pieces:
#   1. vd55g1.ko with an added ACPI match table -> /usr/lib/modules/$KVER/updates/
#      (shadows the in-tree DT-only module)
#   2. imx471-dkms source tree gains the TBE20A1 ipu-bridge entry (link freq
#      600 MHz first guess) + int3472 power-enable->"vana" quirk, then DKMS
#      rebuild (these two modules are already shadowed by that package).
#   3. depmod + reboot.
# NOTE: an imx471-dkms-git package upgrade wipes the /usr/src patches — rerun
# this script afterwards. Revert: revert.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVER=$(uname -r)
DKMSSRC=$(ls -d /usr/src/imx471-* | head -1)
DKMSVER=${DKMSSRC#/usr/src/imx471-}
[ "$EUID" -ne 0 ] || { echo "Run as regular user; sudo is used where needed."; exit 1; }

echo "== 1. Build + install vd55g1 (ACPI edition) for $KVER =="
make -C "/usr/lib/modules/$KVER/build" M="$REPO/src" modules
sudo mkdir -p "/usr/lib/modules/$KVER/updates"
sudo cp "$REPO/src/vd55g1.ko" "/usr/lib/modules/$KVER/updates/"

echo "== 2. Patch DKMS tree at $DKMSSRC =="
if ! grep -q 'TBE20A1' "$DKMSSRC/ipu-bridge.c"; then
  sudo sed -i 's|\tIPU_SENSOR_CONFIG("TBE20A0", 1, 200000000),|&\n\t/* ST VD55G1 IR camera (Lenovo X1 Carbon G14) */\n\tIPU_SENSOR_CONFIG("TBE20A1", 1, 600000000),|' \
    "$DKMSSRC/ipu-bridge.c"
fi
grep -q 'TBE20A1' "$DKMSSRC/ipu-bridge.c" || { echo "ipu-bridge patch failed"; exit 1; }

for f in "$DKMSSRC"/*/discrete.c; do
  grep -q 'int3472_gpio_map' "$f" || continue
  grep -q 'TBE20A1' "$f" && continue
  sudo python3 - "$f" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = '''		.hid = "TBE20A0",
		.type_from = INT3472_GPIO_TYPE_POWER_ENABLE,
		.type_to = INT3472_GPIO_TYPE_POWER_ENABLE,
		.con_id = "vana",
		.enable_time_us = GPIO_REGULATOR_ENABLE_TIME,
	},'''
addition = anchor + '''
	{	/* vd55g1 IR cam (Lenovo X1 Carbon G14): power enable -> "vana" */
		.hid = "TBE20A1",
		.type_from = INT3472_GPIO_TYPE_POWER_ENABLE,
		.type_to = INT3472_GPIO_TYPE_POWER_ENABLE,
		.con_id = "vana",
		.enable_time_us = GPIO_REGULATOR_ENABLE_TIME,
	},'''
if anchor not in s:
    sys.exit(f"anchor not found in {p}")
open(p, 'w').write(s.replace(anchor, addition, 1))
print(f"patched {p}")
EOF
done

echo "== 2b. Patch ipu7-drivers: expose Y10 mono pixelformat on ISYS video nodes =="
# Y10_1X10 is already in csi2_supported_codes and the MIPI RAW10 mapping —
# Intel just never added a video-node pixelformat row for it, so STREAMON
# fails with EPIPE for mono sensors. Mirror the Bayer10 entry.
IPUSRC=$(ls -d /usr/src/ipu7-drivers-* | head -1)
IPUVER=${IPUSRC#/usr/src/ipu7-drivers-}
VIDC="$IPUSRC/drivers/media/pci/intel/ipu7/ipu7-isys-video.c"
if ! grep -q 'V4L2_PIX_FMT_Y10' "$VIDC"; then
  sudo python3 - "$VIDC" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = '''	{V4L2_PIX_FMT_SRGGB10, 16, 10, MEDIA_BUS_FMT_SRGGB10_1X10,
	 IPU_INSYS_FRAME_FORMAT_RAW16},'''
addition = anchor + '''
	{V4L2_PIX_FMT_Y10, 16, 10, MEDIA_BUS_FMT_Y10_1X10,
	 IPU_INSYS_FRAME_FORMAT_RAW16},'''
if anchor not in s:
    sys.exit(f"anchor not found in {p}")
open(p, 'w').write(s.replace(anchor, addition, 1))
print(f"patched {p}")
EOF
fi
grep -q 'V4L2_PIX_FMT_Y10' "$VIDC" || { echo "ipu7-isys-video patch failed"; exit 1; }
sudo dkms remove "ipu7-drivers/$IPUVER" -k "$KVER" || true
sudo dkms install "ipu7-drivers/$IPUVER" -k "$KVER"

echo "== 3. DKMS rebuild (imx471/$DKMSVER) =="
sudo dkms remove "imx471/$DKMSVER" -k "$KVER" || true
sudo dkms install "imx471/$DKMSVER" -k "$KVER"
sudo depmod -a "$KVER"

echo
echo ">>> Done. Check alias then REBOOT:"
grep -i tbe20a1 "/usr/lib/modules/$KVER/modules.alias" || echo "WARNING: no TBE20A1 alias!"
echo ">>> After reboot: journalctl -k -b | grep -iE 'vd55g1|TBE20A1|ipu'"
