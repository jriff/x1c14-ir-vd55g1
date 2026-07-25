# IR camera (ST VD55G1) on ThinkPad X1 Carbon Gen 14 — working on Linux

**Status: streaming.** Y10 mono, 804x704 @ 30 fps, working auto-exposure,
captured on a retail 21V7CTO1WW (2.8K OLED) under Arch Linux / Omarchy,
kernel 7.1.4 — concurrently with the IMX471 RGB camera on the same IPU7.

As far as we know this is the first time this sensor has produced an image on
Linux. Total delta: **four small patches** (`patches/`), each finishing
something the respective driver had almost in place. Nothing here is a new
driver.

## The sensor is a VD55G1, not "unknown"

The IR camera enumerates as ACPI HID **`TBE20A1`** (sibling of `TBE20A0`, the
IMX471 RGB sensor — see [RH bug 2483180]). No public source named the IR
sensor, so we pulled Lenovo's Windows **Intel MIPI Camera Driver** for this
machine (`n4oce17w`, via the Microsoft Update Catalog, which indexes drivers
by hardware ID — search "TBE20A1") and read the tuning-file metadata inside:

```
TBE0020A1_*.aiqb:  Sensor: VD55G1   ProjectName: Avon.IPU75XA
```

Control check for the method: the RGB twin's tuning file
(`TBE0020A0_AAJH5-D_PTL.aiqb`) says `imx471` — which is chip-id-proven true.
Final confirmation on the wire: the mainline `vd55g1` driver's probe reads
back CCI model id `0x53354731` (VD55G1, mono) and binds. See
`docs/probe.log`.

The VD55G1 is an ST 800x704 **global shutter** mono sensor — a
computer-vision part (presence detection, face auth), which is exactly what
this camera is for (Windows Hello / "user presence sensing").

## The four patches

| # | File | What it fixes |
|---|------|---------------|
| 1 | `drivers/media/i2c/vd55g1.c` | ST's mainline driver is DT-only; adds an ACPI match table for `TBE20A1` |
| 2 | `drivers/media/pci/intel/ipu-bridge.c` | `IPU_SENSOR_CONFIG("TBE20A1", 1, 600000000)` — 1 lane, link freq verified streaming |
| 3 | `drivers/platform/x86/intel/int3472/discrete.c` | map the module's power-enable GPIO to con_id `"vana"` (one of vd55g1's supply names); without it the sensor stays unpowered behind a dummy regulator |
| 4 | `drivers/staging/media/ipu7/ipu7-isys-video.c` | `Y10_1X10` is already in `csi2_supported_codes` and the RAW10 MIPI mapping, but no video-node pixel format references it → mono sensors pass subdev negotiation then die at STREAMON with EPIPE. Adds `V4L2_PIX_FMT_Y10`. |

Patches 2 and 3 assume the IMX471 series by Kate Hsuan (Red Hat) as base
(they extend its `TBE20A0` entries); it is in linux-next as of July 2026.

## Trying it on Arch (out-of-tree, no kernel rebuild)

`install.sh` reproduces our setup on an Arch/Omarchy system that already runs
the RGB camera via [BenBJD/imx471-dkms] + `intel-ipu7-camera`:

1. builds the ACPI-enabled `vd55g1.ko` (`src/`) into
   `/usr/lib/modules/$(uname -r)/updates/`,
2. applies patches 2/3 to the `imx471-dkms` source tree and patch 4 to the
   `ipu7-drivers` DKMS tree, rebuilds both via DKMS,
3. `depmod`; reboot.

`revert.sh` undoes everything surgically. Both are idempotent; re-run after
package upgrades of `imx471-dkms-git` / `intel-ipu7-camera` (they replace the
patched `/usr/src` trees).

## Capturing frames

libcamera's software ISP cannot consume mono (`Unsupported input format R10`;
the camera is enumerated but gets "No valid configuration found"), so consume
raw V4L2 directly — for CV workloads (presence, face detection) that is what
you want anyway:

```sh
media-ctl -d /dev/media0 -V '"vd55g1 1-0010":0 [fmt:Y10_1X10/804x704]'
media-ctl -d /dev/media0 -V '"Intel IPU7 CSI2 2":0 [fmt:Y10_1X10/804x704]'
v4l2-ctl -d /dev/video16 --set-fmt-video=width=804,height=704,pixelformat='Y10 '  # note trailing space in fourcc
v4l2-ctl -d /dev/video16 --stream-mmap --stream-count=10 --stream-to=frames.raw
```

Layout: 10-bit values in 16-bit little-endian containers, stride 1664 bytes
(832 values per row, first 804 valid). Auto-exposure runs in the sensor
driver (`/dev/v4l-subdev4`: `auto_exposure` 0=Auto 1=Manual, plus manual
`exposure` / `analogue_gain` / `digital_gain`).

Device/entity numbers (`media0`, `video16`, `subdev4`) are from our machine —
check `media-ctl -p` on yours.

## Known gaps / gotchas

- **The IR emitter is not driven yet.** Under LED room lighting the scene is
  nearly black at the sensor's wavelength (LEDs emit no near-IR) — AE pegs at
  max gain and you get noise. Daylight and incandescent light work fine.
  Presumably another INT3472/GPIO or the `TBE20A2` ToF sibling; input welcome.
- **If you run the v4l2-relayd RGB stack: pin the camera name.** Once the IR
  camera enumerates, it becomes libcamera's first camera and an unpinned
  `libcamerasrc` in `/etc/v4l2-relayd.d/ipu7.conf` grabs it, killing
  `/dev/video50`. Fix: `camera-name=\\\_SB_.LNK0` in `VIDEOSRC` (three
  backslashes — the env-file parser eats one pair) and change the systemd
  drop-in to expand `$${VIDEOSRC}` at shell runtime rather than `${VIDEOSRC}`
  at unit parse time. Verify with: the relayd process cmdline must show
  `camera-name=\\_SB_.LNK0`.
- The privacy **shutter covers both apertures** (empirically settled).
- The `_DDN` module names on this unit: `CBG802N3A(P)` / `CJFPE90(P)`;
  Windows ships per-module IR tuning we don't use (raw capture needs none).

## Credits

- Kate Hsuan (Red Hat) — the IMX471 enablement series these patches build on
  ([RH bug 2483180]).
- Benjamin Mugnier & Sylvain Petinot (ST) — the mainline vd55g1 driver.
- [ocewers/x1c14-camera-imx471] — the RGB camera enablement on this machine,
  and the investigative playbook this repo reuses.
- [BenBJD/imx471-dkms] — the DKMS packaging these patches piggyback on.

## License

Patches: GPL-2.0 (kernel). Docs: CC-BY-4.0.

[RH bug 2483180]: https://bugzilla.redhat.com/show_bug.cgi?id=2483180
[ocewers/x1c14-camera-imx471]: https://github.com/ocewers/x1c14-camera-imx471
[BenBJD/imx471-dkms]: https://github.com/BenBJD/imx471-dkms
