#!/bin/bash
# Prepare a Garden Linux host to load the amdgpu driver safely:
#   1. blacklist amdgpu so every boot comes up clean even if a load hangs
#   2. fetch the firmware package (Garden Linux ships none)
#   3. install the blobs into the kernel's priority search path
#
# Does NOT load the driver. Run 1-gpu-test.sh for that.
# See README.md chapter 1 §2-3.
set -euo pipefail

# ---------------------------------------------------------------- config ----
DEB='firmware-amd-graphics_20260810-1~bpo13+1_all.deb'
# NOTE: https, not http. Over plain HTTP this hung for eight minutes against a
# dead mirror - both ports answered and the directory listing worked, but the
# file transfer stalled with no error. Over HTTPS: 3.8 seconds.
URL="https://deb.debian.org/debian/pool/non-free-firmware/f/firmware-nonfree/${DEB}"
# -----------------------------------------------------------------------------

echo "=== STEP 1a: blacklist amdgpu in /usr/lib/modprobe.d ==="
# /usr/lib, not /etc - gardener-node-agent reconciles /etc and may revert it.
mount -o remount,rw /usr
cat > /usr/lib/modprobe.d/blacklist-amdgpu.conf <<'EOF'
# Installed for the MI350P driver-load test. The host must always be able to
# boot even if loading amdgpu hangs it. Load manually with:
#   modprobe --ignore-install amdgpu
blacklist amdgpu
install amdgpu /bin/false
EOF
mount -o remount,ro /usr
cat /usr/lib/modprobe.d/blacklist-amdgpu.conf
echo
# 'blacklist' alone only stops alias/udev autoload; an explicit `modprobe
# amdgpu` would still work. 'install ... /bin/false' blocks that too, which is
# why every deliberate load needs --ignore-install.

echo "=== STEP 1b: blacklist on the kernel command line too ==="
# Survives a stale initramfs or a root filesystem in a bad state.
mount -o remount,rw /efi
E=$(find /efi/loader/entries -name '*.conf' | head -1)
if grep -q 'modprobe.blacklist=amdgpu' "$E"; then
  echo "(already present)"
else
  sed -i 's/ security=apparmor/ modprobe.blacklist=amdgpu security=apparmor/' "$E"
fi
grep ^options "$E"
sync
mount -o remount,ro /efi
echo

echo "=== STEP 2: fetch and unpack firmware ==="
cd /var/tmp
[ -f "$DEB" ] || curl -sLO "$URL"
ls -l "$DEB"
rm -rf fw && mkdir -p fw
dpkg-deb -x "$DEB" fw/
echo
echo "--- the six blobs an MI350P needs ---"
for f in psp_13_0_12_sos psp_13_0_12_ta gc_9_5_0_rlc gc_9_5_0_mec \
         sdma_4_4_4 vcn_5_0_1; do
  if [ -f "fw/usr/lib/firmware/amdgpu/$f.bin" ]; then
    printf '  %-24s %s bytes\n' "$f.bin" \
      "$(stat -c%s "fw/usr/lib/firmware/amdgpu/$f.bin")"
  else
    echo "  MISSING: $f.bin"
  fi
done
echo

echo "=== STEP 3: install into /usr/lib/firmware/updates ==="
# The kernel searches /lib/firmware/updates/ BEFORE /lib/firmware/, so this
# takes precedence and leaves the distribution tree untouched - which matters
# on an image-based OS where /usr may be replaced wholesale on upgrade.
# (/lib is a symlink to usr/lib here, so the two paths are the same place.)
mount -o remount,rw /usr
mkdir -p /usr/lib/firmware/updates
cp -a /var/tmp/fw/usr/lib/firmware/amdgpu /usr/lib/firmware/updates/
sync
mount -o remount,ro /usr

echo "  installed: $(ls /usr/lib/firmware/updates/amdgpu | wc -l) files, \
$(du -sh /usr/lib/firmware/updates/amdgpu | cut -f1)"
echo
echo "PREP COMPLETE - driver NOT loaded. Next: reboot, then ./1-gpu-test.sh"
