#!/bin/bash
# Complete revert of install.sh: removes the out-of-tree vd55g1.ko and
# restores the imx471-dkms sources to their packaged state (git checkout is
# not available in /usr/src, so we reinstall the package's pristine copy by
# removing our two patch insertions), then DKMS-rebuilds.
set -euo pipefail
KVER=$(uname -r)
DKMSSRC=$(ls -d /usr/src/imx471-* | head -1)
DKMSVER=${DKMSSRC#/usr/src/imx471-}
[ "$EUID" -ne 0 ] || { echo "Run as regular user; sudo is used where needed."; exit 1; }

echo "== Remove out-of-tree vd55g1 =="
sudo rm -f "/usr/lib/modules/$KVER/updates/vd55g1.ko"

echo "== Un-patch DKMS tree =="
sudo sed -i '/ST VD55G1 IR camera (Lenovo X1 Carbon G14)/,+1d' "$DKMSSRC/ipu-bridge.c"
for f in "$DKMSSRC"/*/discrete.c; do
  grep -q 'TBE20A1' "$f" 2>/dev/null || continue
  sudo python3 - "$f" <<'EOF'
import sys, re
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'\n\t\{\t/\* vd55g1 IR cam[^}]*\},', '', s, count=1)
open(p, 'w').write(s)
print(f"unpatched {p}")
EOF
done

echo "== Un-patch ipu7-drivers Y10 entry =="
IPUSRC=$(ls -d /usr/src/ipu7-drivers-* | head -1)
IPUVER=${IPUSRC#/usr/src/ipu7-drivers-}
VIDC="$IPUSRC/drivers/media/pci/intel/ipu7/ipu7-isys-video.c"
if grep -q 'V4L2_PIX_FMT_Y10' "$VIDC" 2>/dev/null; then
  sudo python3 - "$VIDC" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
block = '''
	{V4L2_PIX_FMT_Y10, 16, 10, MEDIA_BUS_FMT_Y10_1X10,
	 IPU_INSYS_FRAME_FORMAT_RAW16},'''
open(p, 'w').write(s.replace(block, '', 1))
print(f"unpatched {p}")
EOF
  sudo dkms remove "ipu7-drivers/$IPUVER" -k "$KVER" || true
  sudo dkms install "ipu7-drivers/$IPUVER" -k "$KVER"
fi

echo "== DKMS rebuild + depmod =="
sudo dkms remove "imx471/$DKMSVER" -k "$KVER" || true
sudo dkms install "imx471/$DKMSVER" -k "$KVER"
sudo depmod -a "$KVER"
echo ">>> Reverted. Reboot to unload vd55g1 and return to RGB-only state."
