#!/bin/bash
# Offline preparation of a Garden Linux image already written to the target disk.
#
# Runs from the *existing* OS (Ubuntu), as root, with the target disk NOT in use.
# Everything here must be done before the first boot: there is no OS-level
# console on this platform to fix it from afterwards.
#
# See README.md chapter 0 §6.
set -euo pipefail

# ---------------------------------------------------------------- config ----
DISK=/dev/nvme1n1                 # target disk (p1=/usr p2=ESP p3=/)
ROOT=/mnt/gl
ESP=/mnt/gl/efi

KEY='ssh-ed25519 AAAA...<your-public-key> <your-email>'
MAC='00:00:5e:00:53:52'           # NIC MAC - match on this, never on ifname
ADDR='10.20.154.203/19'
GW='10.20.159.254'
DNS=(10.23.2.235 10.23.2.236 10.20.128.15)
HOSTNAME='gpu-node-gl'
# -----------------------------------------------------------------------------

mkdir -p "$ROOT"
mount "${DISK}p3" "$ROOT"
mkdir -p "$ESP"
mount "${DISK}p2" "$ESP"

echo "=== 1. enable ssh.service (shipped but NOT enabled in the image) ==="
# No vendor symlink, no ssh.socket, no preset. Boot it untouched and nothing
# listens on port 22.
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/ssh.service \
       "$ROOT/etc/systemd/system/multi-user.target.wants/ssh.service"
ls -l "$ROOT/etc/systemd/system/multi-user.target.wants/ssh.service"

echo
echo "=== 2. inject root SSH key ==="
install -d -m 700 "$ROOT/root/.ssh"
printf '%s\n' "$KEY" > "$ROOT/root/.ssh/authorized_keys"
chmod 600 "$ROOT/root/.ssh/authorized_keys"
chown 0:0 "$ROOT/root/.ssh" "$ROOT/root/.ssh/authorized_keys"
cat "$ROOT/root/.ssh/authorized_keys"

echo
echo "=== 3. allow root login by key - EDIT sshd_config ITSELF ==="
# A drop-in in sshd_config.d/ does NOT work here. The image has
# 'PermitRootLogin no' on line 2 and the Include on line 45, and OpenSSH keeps
# the FIRST value it sees for a keyword. Anything in sshd_config.d/ is dead on
# arrival. This exact mistake cost a reboot cycle on the real run.
cp "$ROOT/etc/ssh/sshd_config" "$ROOT/etc/ssh/sshd_config.orig"
sed -i 's/^PermitRootLogin no$/PermitRootLogin prohibit-password/' \
  "$ROOT/etc/ssh/sshd_config"
grep -n '^PermitRootLogin' "$ROOT/etc/ssh/sshd_config"
# AuthenticationMethods publickey can stay - the injected key satisfies it.

echo
echo "=== 4. static network, matched by MAC ==="
# The old OS only calls its NIC eth0 because of net.ifnames=0 on its cmdline.
# Garden Linux will not; here it came up as eno1. Matching on name would have
# left the host unreachable with no console to fix it from.
{
  printf '[Match]\nMACAddress=%s\n\n[Network]\nAddress=%s\nGateway=%s\n' \
    "$MAC" "$ADDR" "$GW"
  printf 'DNS=%s\n' "${DNS[@]}"
} > "$ROOT/etc/systemd/network/10-host.network"
cat "$ROOT/etc/systemd/network/10-host.network"

echo
echo "--- resolv.conf in image ---"
ls -l "$ROOT/etc/resolv.conf" || true
if [ ! -L "$ROOT/etc/resolv.conf" ]; then
  printf 'nameserver %s\n' "${DNS[@]}" > "$ROOT/etc/resolv.conf"
  echo "(wrote static resolv.conf)"
fi

echo
echo "=== 5. serial console - add ttyS1 alongside ttyS0 ==="
# The BMC SOL on this platform carries UEFI firmware output but NOT the OS
# console on either ttyS0 or ttyS1 - markers written to both from the running
# OS never appeared. Added anyway; costs nothing and may help on other boards.
ENTRY=$(find "$ESP/loader/entries" -name '*.conf' | head -1)
echo "before: $(grep ^options "$ENTRY")"
grep -q 'console=ttyS1' "$ENTRY" || \
  sed -i 's/\(console=ttyS0,115200\)/\1 console=ttyS1,115200/' "$ENTRY"
echo "after:  $(grep ^options "$ENTRY")"

echo
echo "=== 6. hostname ==="
echo "$HOSTNAME" > "$ROOT/etc/hostname"
cat "$ROOT/etc/hostname"

echo
echo "=== 7. verification ==="
echo "root fs label : $(blkid -s LABEL -o value ${DISK}p3)"   # expect ROOT
echo "usr  fs label : $(blkid -s LABEL -o value ${DISK}p1)"   # expect USR
echo "ESP loader    : $(ls "$ESP/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || echo MISSING)"
echo "root= in entry: $(grep -ohE 'root=[^ ]+' "$ENTRY")"      # expect LABEL=ROOT
df -h "$ROOT" | tail -1

sync
umount "$ESP"
umount "$ROOT"
echo
echo "PREP COMPLETE - unmounted cleanly"
