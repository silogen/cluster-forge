# AMD Enterprise AI on Garden Linux, under Gardener

This folder documents one scenario end to end: take a bare-metal AMD host,
install [Garden Linux](https://gardenlinux.io/) on it, make its Instinct GPU
usable, turn it into a [Gardener](https://gardener.cloud/)-managed Kubernetes
cluster, and install AMD Enterprise AI on the result.

## The scenario

**Everything runs on one machine.** The reference host is `gpu-node-gl`,
an EPYC 9965 with 768 threads, 1.5 TiB of memory and one AMD Instinct MI350P,
running Garden Linux 2150.8.0.

The design began as two hosts, one managing the other. That was abandoned
during the build: the two subnets complete a TCP handshake but reset the
connection on the first payload, in both directions, so the management host
could never reach the GPU host. The management plane was rebuilt on the GPU
host itself, and this guide documents that single-host result. Chapter 2 §1
records what the two-host arrangement was and when it is still the better
choice.

**The single host carries two Kubernetes control planes.** This is the part
that surprises people, and most of the care in this guide comes from it.
There is one node and one cluster, but two API servers:

```
┌──────────────────────────────────────────────────────────────────┐
│  one Garden Linux node — one kubelet, one cluster                │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ CONTROL PLANE 1 — the cluster itself                       │  │
│  │ kube-apiserver and etcd as static pods in kube-system,     │  │
│  │ created by `gardenadm init`. Reached at https://<node>.    │  │
│  │ This is where the AMD Enterprise AI platform is installed. │  │
│  └────────────────────────────────────────────────────────────┘  │
│                              ▲                                   │
│                              │ manages it as a Shoot             │
│                              │                                   │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ CONTROL PLANE 2 — the virtual garden                       │  │
│  │ The Gardener API, as ordinary pods in namespace `garden`,  │  │
│  │ behind an Istio gateway on its own MetalLB address.        │  │
│  │ It has no nodes of its own. Added by `gardenadm connect`.  │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

Gardener calls this a **self-hosted shoot**: the three usual layers — garden,
seed and shoot — collapsed onto one machine. Two consequences run through
everything below. You need a separate kubeconfig for each control plane, and
you must know which one a given command speaks to. And because the management
plane lives on the node it manages, deleting the wrong object does not merely
break Gardener, it can remove your own access to the machine.

> `gardenadm` is flagged upstream as **"highly experimental, do not use in
> production"** (GEP-0028). This scenario is an evaluation.

## What this guide installs

Chapters 0 to 4 build the host and the cluster from bare metal. Chapters 5 to
15 install AMD Enterprise AI on the result: they prepare the cluster, then
install the `demo-cpu` profile with [Spur](../../spur/README.md). Spur is the
correct path here, because its `default-cpu` profile already holds the storage
policy that a one-node cluster needs, and its database is one pod.

Read in order for a build from bare metal. Start at chapter 5 if the cluster
already exists — but read chapter 5 before you install anything, because a
Gardener cluster is not an empty cluster. It already runs its own control
plane, its own load balancer and its own storage class, and some of them are
the same components that the platform installs.

Every script lives in [`scripts/`](scripts/) and is prefixed with the chapter
that uses it. Chapter 15 describes each one and the order to run them in.

## Contents

| Chapter | Scripts |
|---|---|
| [0. Install Garden Linux on the host](#0-install-garden-linux-on-the-host) | [`0-gl-prep.sh`](scripts/0-gl-prep.sh) |
| [1. Make the GPU usable](#1-make-the-gpu-usable) | [`1-gl-gpu-prep.sh`](scripts/1-gl-gpu-prep.sh), [`1-gpu-test.sh`](scripts/1-gpu-test.sh), [`1-gpu-workload.py`](scripts/1-gpu-workload.py) |
| [2. The host and the target architecture](#2-the-host-and-the-target-architecture) | — |
| [3. Build the cluster on the host](#3-build-the-cluster-on-the-host) | — |
| [4. Deploy Gardener and connect the cluster](#4-deploy-gardener-and-connect-the-cluster) | — |
| [5. Telling the two control planes apart](#5-telling-the-two-control-planes-apart) | — |
| [6. What Gardener gives you, and what it takes away](#6-what-gardener-gives-you-and-what-it-takes-away) | — |
| [7. Before you start](#7-before-you-start) | — |
| [8. Prepare the cluster](#8-prepare-the-cluster) | [`8-preflight.sh`](scripts/8-preflight.sh), [`8-prepare.sh`](scripts/8-prepare.sh) |
| [9. Choose a domain](#9-choose-a-domain) | — |
| [10. Install the platform](#10-install-the-platform) | — |
| [11. Verify](#11-verify) | — |
| [12. Limits](#12-limits) | — |
| [13. When something fails](#13-when-something-fails) | — |
| [14. Remove the platform](#14-remove-the-platform) | — |
| [15. The scripts](#15-the-scripts) | all of them |

---

## 0. Install Garden Linux on the host

Writing the Garden Linux image to the second NVMe over OpenBMC, and preparing
it offline with [`0-gl-prep.sh`](scripts/0-gl-prep.sh) before its first boot:
the SSH key, the network and the root login all have to be in place in
advance, because a Garden Linux image has no installer and no console login.

The host ends up **dual boot**, and Ubuntu remains the default entry. Any
reboot returns the machine to Ubuntu and silently removes it from the
cluster. Chapter 4 §1.1 makes Garden Linux permanent; until you do that, every
boot needs a one-shot `efibootmgr --bootnext`.

How Garden Linux 2150.8.0 was installed on `gpu-node`
(`10.20.154.203`), alongside the existing Ubuntu 24.04 install rather than
over it.

> **Scripts:** the offline preparation in §6 is automated by
> [`scripts/0-gl-prep.sh`](scripts/0-gl-prep.sh). See
> [chapter 15 of the README](#15-the-scripts) for the full set and the
> order they run in. Check the config block at the top of any script before
> running it —
> `0-gl-prep.sh` hardcodes a target disk, SSH key, MAC and static IP.

### Outcome

```
PRETTY_NAME="Garden Linux 2150.8.0"   kernel 6.18.41-amd64   debian forky/sid
hostname  gpu-node-gl
/          /dev/nvme1n1p3  3.6T   (LABEL=ROOT)
/usr       /dev/nvme1n1p1  907M   (LABEL=USR, read-only)
/efi       /dev/nvme1n1p2   69M
network    eno1  10.20.154.203/19  via 10.20.159.254
```

Ubuntu is untouched on `nvme0n1` and remains the default boot entry. Total
elapsed about 35 minutes, including one round-trip back to Ubuntu to fix sshd.

---

### 1. Approach — why `dd` over SSH, not BMC virtual media

The Garden Linux artifact is a **whole-disk `.raw`** image, not an installer.
Virtual media is only a mechanism for getting those bytes onto a disk; `dd`
from the running OS does the identical job.

This host has two disks, which is what makes the approach attractive:

| Disk | Contents | Fate |
|---|---|---|
| `nvme0n1` 466 GB | Ubuntu 24.04 — ESP, swap, `/` | **Untouched** — the fallback |
| `nvme1n1` 3.6 TB | `/mnt/disk0`, `/var/lib/rancher` (247 GB RKE2) | **Destroyed** — the target |

Two reasons this beats virtual media even though the BMC offers it:

1. **Speed.** The host downloads the image itself at LAN speed instead of
   pushing several gigabytes from a laptop through the management link.
2. **Ubuntu survives.** Both OSes stay installed on separate physical disks, so
   you can flip between them on demand — invaluable when the point of the
   exercise is comparing OS behaviour on the same hardware.

This is firmware-level dual boot: two independent installs, each with its own
ESP and bootloader (Ubuntu uses shim+GRUB, Garden Linux uses systemd-boot).
Nothing is shared and nothing chainloads.

Because `efibootmgr --bootnext` is a **one-shot** setting consumed by the next
boot regardless of outcome, a failed Garden Linux boot falls back to Ubuntu
automatically on the following power cycle.

#### Pin the version deliberately

Used **2150.8.0 / commit `40f62d58`**, matching the other Garden Linux host
exactly. If the goal is a controlled comparison, a different Garden Linux
version reintroduces the kernel and userspace as variables.

---

### 2. Out-of-band access

| | |
|---|---|
| URL | `https://bmc.example.com` → `10.21.179.189` |
| Credentials | `root` / `<REDACTED>` — **OpenBMC factory default, never changed** |
| Firmware | `sp5-mi350p_v2.16.0.90` |
| KVM over IP | Yes, up to 4 concurrent sessions |
| Serial console | `ssh -p 2200 root@bmc.example.com`, 15 sessions |
| Virtual media | In the web UI only, **not** over Redfish |

Virtual media is at Operations → Virtual media, *"Load image from web browser"*,
which streams from your laptop over a websocket/NBD proxy. The Redfish
`VirtualMedia` resource returns 404, so it cannot be scripted. Keep it in
reserve as the rescue path.

**Confirm the BMC controls the host you think it does.** `LastResetTime`
`2026-09-11T13:29:14Z` against a host boot at `13:34:10Z` — a five-minute POST
gap — is the correlation that proves it. The BMC sits on a different subnet
from the host, so the naming is easy to misread.

Also true of this host, and worth knowing before you start:

- `/dev/ipmi0` is absent and `ipmi_si` reports `Interface detection failed`.
  There is no *in-band* IPMI; all management goes over the network to the BMC.
- **`/dev/watchdog` does not exist.** A hang needs a manual power cycle.
- The BMC SOL console carries UEFI firmware output but **no OS-level console** —
  see §9.6.

> **Rotate the BMC password.** Factory defaults on a controller offering KVM,
> power control and virtual media mean anyone who can reach it owns the
> machine. Store the new value in Vaultwarden, not in these notes.

#### Clear the boot override first — this one is a trap

The BMC was found set to:

```
BootSourceOverrideEnabled    Continuous
BootSourceOverrideTarget     BiosSetup
```

`Continuous`, not one-time. Left alone, **every** boot lands in BIOS Setup
instead of an OS. Over SSH that is indistinguishable from "the install failed
and the host is dead".

```bash
curl -sk -u 'root:<REDACTED>' -X PATCH \
  -H 'Content-Type: application/json' \
  https://bmc.example.com/redfish/v1/Systems/system \
  -d '{"Boot":{"BootSourceOverrideEnabled":"Disabled","BootSourceOverrideTarget":"None"}}'
```

Read it back and confirm `Disabled` / `None` before going further.

---

### 3. Prerequisites

- [ ] SSH to `amd@10.20.154.203` with working `sudo`
- [ ] Boot override cleared (above)
- [ ] Confirmation the target disk's contents are expendable
- [ ] The public key to inject (`~/.ssh/id_ed25519.pub`)
- [ ] BMC reachable for KVM and power control

If your `~/.ssh/config` routes through a jump host, bypass it on every
connection with `ssh -F /dev/null`.

---

### 4. Download and stage the image

Stage on `/`, which lives on `nvme0n1` and survives. **Never stage on the
target disk.**

```bash
VERSION=2150.8.0
COMMIT=40f62d58
IMG="baremetal-gardener_prod-amd64-${VERSION}-${COMMIT}"

cd /var/tmp
curl -LO "https://github.com/gardenlinux/gardenlinux/releases/download/${VERSION}/${IMG}.tar.xz"
tar -xJf "${IMG}.tar.xz" "${IMG}.raw"

sudo sfdisk -l "${IMG}.raw"
```

Expect three partitions: `p1` ~940M (`/usr`), `p2` ~70M (ESP), `p3` ~1006M (`/`).

---

### 5. Quiesce and write the target disk

**Destructive from here.** Verify the target by serial, not by device name —
enumeration can change between boots.

```bash
lsblk -dno MODEL,SERIAL /dev/nvme1n1    # MUST match the disk you intend to destroy
```

Stop everything using it:

```bash
sudo systemctl stop rke2-server
sudo systemctl disable rke2-server      # must not restart if we fall back to Ubuntu
sudo umount /var/lib/rancher /mnt/disk0
sudo swapoff -a
findmnt | grep nvme1n1 || echo "nvme1n1 clear"
```

Remove its entries from `/etc/fstab` too, or a fallback boot into Ubuntu blocks
waiting for filesystems that no longer exist:

```bash
sudo cp /etc/fstab /etc/fstab.pre-gardenlinux
sudo sed -i '/nvme1n1/s/^/#/' /etc/fstab
grep -n nvme1n1 /etc/fstab
```

> If `/etc/fstab` references partitions by UUID rather than device path, match
> on the UUIDs from `blkid /dev/nvme1n1p1 /dev/nvme1n1p2` instead.

Write it:

```bash
sudo dd if=/var/tmp/${IMG}.raw of=/dev/nvme1n1 bs=16M status=progress conv=fsync
sudo partprobe /dev/nvme1n1
lsblk /dev/nvme1n1
```

---

### 6. Prepare the image offline — the critical section

Do all of this **before** rebooting. There is no OS console to fix it from
afterwards.

> Steps 6.2–6.6 are automated by [`scripts/0-gl-prep.sh`](scripts/0-gl-prep.sh),
> which mounts the image, applies all of it and unmounts cleanly. Edit the
> config block at the top first. The partitioning in §6.1 is deliberately left
> manual — it is the destructive part.

#### 6.1 Repair the GPT and grow root

The image is ~2 GB written to a 3.6 TB disk, so the backup GPT header is in the
wrong place.

```bash
sudo sgdisk -e /dev/nvme1n1                              # move backup GPT to end of disk
echo ',+' | sudo sfdisk --no-reread --force -N 3 /dev/nvme1n1
sudo partx -u /dev/nvme1n1

sudo e2fsck -fy /dev/nvme1n1p3
sudo resize2fs /dev/nvme1n1p3
sudo e2fsck -fy /dev/nvme1n1p3        # REQUIRED - see below
```

`GPT PMBR size mismatch` warnings are expected and self-correcting.

> **The second `e2fsck` is not optional.** Garden Linux formats root with the
> ext4 `orphan_file` feature. Resizing it with Ubuntu 24.04's e2fsprogs 1.47.0
> leaves the orphan file inconsistent and the next mount fails outright:
>
> ```
> EXT4-fs error (device nvme1n1p3): ext4_init_orphan_info:625:
>   comm mount: orphan file block 0: bad checksum
> mount: /mnt/gl: can't read superblock on /dev/nvme1n1p3
> ```
>
> The filesystem is fine — `dumpe2fs` reports `clean with errors`. A plain
> `e2fsck -fy` clears it (`Orphan file (inode 12) block 0 is not clean.
> Clear? yes`). If that ever fails, drop the feature with
> `tune2fs -O ^orphan_file` and fsck again.

#### 6.2 Mount it

```bash
sudo mkdir -p /mnt/gl
sudo mount /dev/nvme1n1p3 /mnt/gl        # Garden Linux /
sudo mount /dev/nvme1n1p2 /mnt/gl/efi    # its ESP
ls /mnt/gl
```

Note that `/usr` is a **separate, read-only** partition (`p1`, LABEL=USR). If
you go looking for systemd units under `/mnt/gl/usr` without mounting it, they
will appear to be missing when they are simply not mounted.

#### 6.3 SSH — two separate problems, both lock you out

Garden Linux ships `AuthenticationMethods publickey` with no keys present.
Inject one:

```bash
sudo install -d -m 700 /mnt/gl/root/.ssh
sudo tee /mnt/gl/root/.ssh/authorized_keys >/dev/null <<'EOF'
ssh-ed25519 AAAA...<your-public-key> <your-email>
EOF
sudo chmod 600 /mnt/gl/root/.ssh/authorized_keys
```

**`ssh.service` is shipped but not enabled.** No vendor symlink in
`multi-user.target.wants/`, no `ssh.socket`, no systemd preset. Boot the image
untouched and nothing listens on port 22:

```bash
sudo ln -sf /usr/lib/systemd/system/ssh.service \
  /mnt/gl/etc/systemd/system/multi-user.target.wants/ssh.service
```

**A drop-in cannot enable root login.** `sshd_config` has `PermitRootLogin no`
on **line 2** and `Include /etc/ssh/sshd_config.d/*.conf` on **line 45**.
OpenSSH keeps the *first* value it sees for a keyword, so anything in
`sshd_config.d/` is dead on arrival. Edit the main file:

```bash
sudo cp /mnt/gl/etc/ssh/sshd_config /mnt/gl/etc/ssh/sshd_config.orig
sudo sed -i '2s/^PermitRootLogin no/PermitRootLogin prohibit-password/' \
  /mnt/gl/etc/ssh/sshd_config
sudo sed -n '1,3p' /mnt/gl/etc/ssh/sshd_config
```

`AuthenticationMethods publickey` can stay — the injected key satisfies it.
This is the step that cost an extra reboot cycle on the real run: sshd came up
fine and the network was fine, but every login was refused with
`Permission denied (publickey)`.

> Useful diagnostic: if `ssh amd@host` with a **password** is also refused with
> *publickey*, you are talking to Garden Linux, not Ubuntu. Ubuntu would have
> offered password auth.

#### 6.4 Network — match on MAC, never on interface name

**The Ubuntu host only calls its NIC `eth0` because its kernel cmdline sets
`net.ifnames=0`.** Garden Linux will not, and the interface came up as `eno1`.
Any config written against `eth0` silently never matches and the host is lost.

```bash
sudo tee /mnt/gl/etc/systemd/network/10-host.network >/dev/null <<'EOF'
[Match]
MACAddress=00:00:5e:00:53:52

[Network]
Address=10.20.154.203/19
Gateway=10.20.159.254
DNS=10.23.2.235
DNS=10.23.2.236
DNS=10.20.128.15
EOF
```

Use a **static** address unless you have confirmed a DHCP reservation exists
for that MAC. Confirm `systemd-networkd` is enabled in the image:

```bash
ls -l /mnt/gl/etc/systemd/system/multi-user.target.wants/ | grep -i networkd
```

#### 6.5 Check how the bootloader finds root

The image was built expecting to be the only disk. Here it is the second one,
so confirm the kernel command line identifies root by label or UUID and **not**
by a device path:

```bash
sudo grep -rhoE 'root=[^ ]+' /mnt/gl/efi/ 2>/dev/null | sort -u
sudo blkid /dev/nvme1n1p3
```

Garden Linux uses `root=LABEL=ROOT`, which resolves correctly on any disk — no
change needed. A literal `root=/dev/nvme0n1p3` would **not** be fine: that is
Ubuntu's root on the other disk.

If the image uses a Unified Kernel Image the cmdline is baked into the `.efi`
and cannot be edited this way. Check with
`sudo strings /mnt/gl/efi/EFI/*/*.efi | grep -m1 'root='` and fix it live from
the KVM console if it names a device path.

#### 6.6 Hostname, then unmount

```bash
echo 'gpu-node-gl' | sudo tee /mnt/gl/etc/hostname

sudo find /mnt/gl/efi -iname '*.efi' | head   # confirm a loader exists
sudo umount /mnt/gl/efi /mnt/gl
sync
```

---

### 7. Add a one-shot boot entry

Create an explicit entry rather than relying on the firmware's auto-created one:

```bash
sudo efibootmgr -c -d /dev/nvme1n1 -p 2 -L "GardenLinux" -l '\EFI\BOOT\BOOTX64.EFI'
sudo efibootmgr -v | grep -i garden
```

**`efibootmgr -c` silently prepends the new entry to `BootOrder`**, which
destroys the fallback and makes Garden Linux the permanent default. Put Ubuntu
back in front:

```bash
sudo efibootmgr -o 0007,0004,0005,0001,0006,0003,0002,0000,0008,0009
sudo efibootmgr --bootnext 0009       # the new GardenLinux entry
sudo efibootmgr | grep -E 'BootNext|BootOrder'
```

Expect `BootNext: 0009` with `BootOrder` still starting `0007`. That pairing is
the entire safety model: `BootNext` is consumed by the next boot and discarded
regardless of outcome, so any failure lands back in Ubuntu.

Verified in practice — a `ForceRestart` from the BMC while Garden Linux was
running returned the machine to Ubuntu with no intervention.

```bash
sudo reboot
```

Boot takes roughly 5½ minutes, most of it POST.

---

### 8. Verify

```bash
ssh -F /dev/null root@10.20.154.203

grep PRETTY_NAME /etc/os-release    # Garden Linux 2150.8.0
cat /etc/debian_version             # forky/sid
uname -r                            # 6.18.41-amd64
df -h /                             # full disk, not 476M
```

#### Switching between the two OSes

Ubuntu is the default. To boot Garden Linux once:

```bash
sudo efibootmgr --bootnext 0009 && sudo reboot
```

To get back, just reboot Garden Linux — `BootOrder` leads with `0007`. If it is
wedged, force it from the BMC:

```bash
curl -sk -u 'root:<REDACTED>' -X POST -H 'Content-Type: application/json' \
  https://bmc.example.com/redfish/v1/Systems/system/Actions/ComputerSystem.Reset \
  -d '{"ResetType":"ForceRestart"}'
```

> `BootNext` is **one-shot**. After one Garden Linux boot it is gone, and the
> next reboot returns to Ubuntu. Re-arm it every time — forgetting this was the
> cause of one wasted reboot cycle.

#### Rollback

Power-cycle the machine; it boots Ubuntu on its own. Then restore `/etc/fstab`
from `/etc/fstab.pre-gardenlinux` and re-enable `rke2-server` if wanted.

#### Making Garden Linux permanent

Only after it has proved reachable across at least one more reboot:

```bash
sudo efibootmgr -o <GL>,0007,0004,0005,0001,0006,0003,0002,0000,0008
```

Keeping `0007` second preserves the Ubuntu fallback.

---

### 9. What differed from expectation

Six surprises on the real run. Four would have produced an unreachable host.

1. **`resize2fs` broke the filesystem.** The ext4 `orphan_file` feature left a
   bad checksum and the next mount failed outright. A second `e2fsck -fy` fixes
   it. See §6.1.
2. **`ssh.service` is not enabled in the image.** Shipped but never wired to
   any target. See §6.3.
3. **`PermitRootLogin no` sits above the `Include` line**, so no drop-in can
   override it. This cost a reboot cycle. See §6.3.
4. **`efibootmgr -c` silently prepends to `BootOrder`**, which would have made
   Garden Linux permanent and removed the fallback. See §7.
5. **The NIC is `eno1`, not `eth0`.** Matching the `.network` file on MAC made
   this a non-event; matching on name would have been fatal.
6. **The BMC SOL console is not `ttyS0` or `ttyS1`.** Markers written to both
   from the running OS produced nothing on SOL, though UEFI firmware output
   comes through fine. You get boot-entry selection and kernel handoff — enough
   to confirm which OS was chosen — but no OS-level console. Worth solving
   before any test that could hang the host.

---

### 10. Checklist

- [x] Power-cycle path confirmed — BMC reachable, KVM available
- [x] **Boot override cleared** — `BootSourceOverrideEnabled` reads `Disabled`
- [x] Target disk contents confirmed expendable
- [x] Image 2150.8.0 / `40f62d58` downloaded and `sfdisk -l` looks sane
- [x] Target verified by serial `<disk-serial>`
- [x] `rke2-server` stopped **and disabled**, `nvme1n1` lines commented in `/etc/fstab`
- [x] Image written, `sgdisk -e` run, `p3` grown, `resize2fs` **and second fsck** done
- [x] **`ssh.service` symlinked into `multi-user.target.wants`**
- [x] **SSH key injected into `/root/.ssh/authorized_keys`**
- [x] **`PermitRootLogin` fixed in `sshd_config` itself, not a drop-in**
- [x] **Network config matched by MAC `00:00:5e:00:53:52`** — the NIC is `eno1`
- [x] Boot entry created, `BootOrder` restored to Ubuntu-first, `BootNext` set
- [x] Reachable after reboot, versions confirmed, disk full size

---

## 1. Make the GPU usable

Installing the firmware and the `amdgpu` driver on an Instinct MI350P, and
proving the card computes rather than merely enumerating.

The driver is **deliberately blacklisted** on this host, in
`/usr/lib/modprobe.d/` and on the kernel command line, so that a GPU hang can
never make the machine unbootable. That is why
[`1-gl-gpu-prep.sh`](scripts/1-gl-gpu-prep.sh) and
[`1-gpu-test.sh`](scripts/1-gpu-test.sh) are separate scripts: the first makes
the host safe to crash, the second is the only thing that loads the driver.
The consequence for the cluster is that **the GPU does not come back by
itself after a reboot**:

```bash
modprobe --ignore-install amdgpu
```

[`1-gpu-workload.py`](scripts/1-gpu-workload.py) then runs a PyTorch matmul
inside a ROCm container. The reference card sustained 58.5 TFLOP/s for 180 s
with no faults.

Getting an MI350P working on `gpu-node-gl` (`10.20.154.203`) with the
in-tree `amdgpu` driver, and proving it actually computes rather than merely
enumerating.

> **Scripts:** all three used here live in
> [`scripts/`](scripts/) — [`1-gl-gpu-prep.sh`](scripts/1-gl-gpu-prep.sh)
> (§2–3), [`1-gpu-test.sh`](scripts/1-gpu-test.sh) (§4) and
> [`1-gpu-workload.py`](scripts/1-gpu-workload.py) (§6). They are reproduced
> inline below so the chapter can be read without opening them, but the files
> in `scripts/` are the copies to actually run.

### Outcome

```
driver     in-tree amdgpu 3.64.0 (kernel 6.18.41)   [drm] Initialized
device     03:00.0 [1002:75a8]  AMD Instinct MI350P  gfx950 / CDNA 4
KFD        gpu_id 39602  simd_count 512 (128 CUs)  num_xcc 4  144 GiB
partitions 8 DRM cards, 8 render nodes (amdgpu_xcp_0..6)
firmware   661 blobs in /usr/lib/firmware/updates/amdgpu  (105 MB)
workload   9580 fp32 matmuls 8192x8192 in 180 s -- 58.5 TFLOP/s, ~10.5 PFLOP
stability  no RAS events, no faults, clean return to idle
```

---

### 1. The problem Garden Linux creates

**Garden Linux ships zero GPU firmware.** The `amdgpu` module is present and
in-tree, but with no blobs on disk the driver cannot bring up the PSP, so it
never binds. The card shows in `lspci` with no driver attached. That is the
entire problem; everything in §3 exists to solve it.

Two further Garden Linux properties shape how you fix it:

| Property | Consequence |
|---|---|
| `/usr` is a **separate, read-only** ext4 partition (LABEL=USR) | Must `mount -o remount,rw /usr` before writing anything under it |
| `/lib` is a symlink to `usr/lib` | `/lib/firmware/...` and `/usr/lib/firmware/...` are the same place |
| `/etc` is reconciled by `gardener-node-agent` | Put persistent config in `/usr/lib/modprobe.d/`, **not** `/etc/modprobe.d/` |

---

### 2. Safety model — set this up first

This host has **no `/dev/watchdog`**, so a driver load that hangs the machine
needs a manual power cycle from the BMC. Before loading anything, make certain
that every boot comes up *without* the driver, so a hang is always recoverable
by a power cycle alone.

#### 2.1 Blacklist at the module level

```bash
mount -o remount,rw /usr
cat > /usr/lib/modprobe.d/blacklist-amdgpu.conf <<'EOF'
# Installed for the MI350P driver-load test. The host must always be able to
# boot even if loading amdgpu hangs it. Load manually with:
#   modprobe --ignore-install amdgpu
blacklist amdgpu
install amdgpu /bin/false
EOF
mount -o remount,ro /usr
```

Both lines matter and they do different things:

- `blacklist amdgpu` stops *alias-based* autoloading — the udev/PCI-ID path.
  It does **not** stop an explicit `modprobe amdgpu`.
- `install amdgpu /bin/false` stops the explicit path too. This is what makes
  the blacklist actually hold.

Because of the second line, loading the driver deliberately requires
`modprobe --ignore-install amdgpu`. That asymmetry is the point: nothing loads
it by accident, and loading it is always an explicit act.

#### 2.2 Blacklist on the kernel command line as well

The module-level blacklist lives in the root filesystem. If an initramfs is
stale or the root filesystem is in a bad state, it may not be honoured. The
cmdline always is:

```bash
mount -o remount,rw /efi
E=$(find /efi/loader/entries -name '*.conf' | head -1)
sed -i 's/ security=apparmor/ modprobe.blacklist=amdgpu security=apparmor/' "$E"
grep ^options "$E"
sync
mount -o remount,ro /efi
```

Garden Linux uses systemd-boot with Boot Loader Specification type#1 entries,
so this is a plain text file — no `grub-mkconfig` step. The resulting line:

```
options root=LABEL=ROOT console=tty0 console=ttyS0,115200 console=ttyS1,115200 rw
        earlyprintk=ttyS1,115200 consoleblank=0 modprobe.blacklist=amdgpu security=apparmor
```

#### 2.3 Confirm remote power control works *before* the first load

```bash
curl -sk -u 'root:<REDACTED>' \
  https://bmc.example.com/redfish/v1/Systems/system | grep -i powerstate
```

If that doesn't answer, stop and fix it first.

---

### 3. Install the firmware

#### 3.1 Fetch the package

Use the **same build as any host you are comparing against** —
`firmware-amd-graphics` 20260810 here. Different firmware vintage is a
different experiment.

```bash
cd /var/tmp
DEB='firmware-amd-graphics_20260810-1~bpo13+1_all.deb'
curl -sLO "https://deb.debian.org/debian/pool/non-free-firmware/f/firmware-nonfree/${DEB}"
ls -l "$DEB"

rm -rf fw && mkdir -p fw
dpkg-deb -x "$DEB" fw/
```

> **Use `https://`, not `http://`.** Over plain HTTP this download hung for
> eight minutes against a dead mirror — the directory listing worked and both
> ports answered, but the file transfer stalled with no error. The same fetch
> over HTTPS completed in 3.8 seconds. If a Debian mirror appears to hang,
> switch scheme before debugging anything else.

Confirm the six blobs this card actually needs are present:

```bash
for f in psp_13_0_12_sos psp_13_0_12_ta gc_9_5_0_rlc gc_9_5_0_mec \
         sdma_4_4_4 vcn_5_0_1; do
  printf '  %-24s %s bytes\n' "$f.bin" \
    "$(stat -c%s "fw/usr/lib/firmware/amdgpu/$f.bin" 2>/dev/null || echo MISSING)"
done
```

(`modinfo -F firmware amdgpu` lists several hundred files — that is every ASIC
the module supports, not this card's requirement. The six above are the MI350P
set: PSP boot loader and trusted application, graphics RLC and MEC, SDMA, VCN.)

#### 3.2 Install into the updates directory

```bash
mount -o remount,rw /usr
mkdir -p /usr/lib/firmware/updates
cp -a /var/tmp/fw/usr/lib/firmware/amdgpu /usr/lib/firmware/updates/
sync
mount -o remount,ro /usr

ls /usr/lib/firmware/updates/amdgpu | wc -l      # 661
du -sh /usr/lib/firmware/updates/amdgpu          # 105M
```

**Why `updates/` and not `/usr/lib/firmware/amdgpu` directly.** The kernel
searches `/lib/firmware/updates/` *before* `/lib/firmware/`, so this location
takes precedence and keeps the distribution's own tree untouched — which
matters on an image-based OS where `/usr` may be replaced wholesale on upgrade.
The alternative is `firmware_class.path=` on the kernel cmdline, but the
updates directory needs no boot-time change.

---

### 4. Load the driver under the test harness

Don't just `modprobe` it. If the card faults, the useful state is only readable
while the driver is bound, and the host may die before you can read it. The
harness below captures the high-value data first, then samples until the
machine stops responding, calling `sync` after every write so nothing is lost
in a panic.

#### `/root/1-gpu-test.sh`

```bash
#!/bin/bash
# Runs ON the host, detached. Loads amdgpu once, captures everything it can
# before the card faults, then samples until the box dies.
#
# Safety: does NOT touch /usr/lib/modprobe.d/blacklist-amdgpu.conf, so whatever
# happens, the next boot comes up without amdgpu.

PARAMS="$*"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=/var/tmp/gpu-test-$STAMP.log
DEV=0000:03:00.0

# sync after every write so nothing is lost when the kernel dies
log() { echo "$@" >>"$OUT"; sync; }
run() { echo "--- \$ $* ---" >>"$OUT"; eval "$*" >>"$OUT" 2>&1; sync; }

log "=== gpu-test $STAMP  params='${PARAMS:-<default>}' ==="
log "boot: $(uptime -s)   kernel: $(uname -r)"
log "blacklist still in place: $(test -f /usr/lib/modprobe.d/blacklist-amdgpu.conf && echo YES || echo NO-ABORT)"
test -f /usr/lib/modprobe.d/blacklist-amdgpu.conf || { log "ABORT: no blacklist, refusing to load"; exit 1; }

log ""
log "=== T-0  loading amdgpu ==="
date >>"$OUT"; sync
modprobe --ignore-install amdgpu $PARAMS
log "modprobe exit=$?"
log "loaded: $(lsmod | grep -c '^amdgpu')"

# ---- highest-value data first, in case we only get a few seconds ----
log ""
log "=== firmware / IFWI versions (only readable while bound) ==="
if [ -d /sys/bus/pci/devices/$DEV/fw_version ]; then
    for f in /sys/bus/pci/devices/$DEV/fw_version/*; do
        log "  $(basename "$f") = $(cat "$f" 2>/dev/null)"
    done
else
    log "  fw_version dir absent - driver did not bind"
fi

log ""
log "=== VBIOS ==="
run "cat /sys/bus/pci/devices/$DEV/vbios_version 2>/dev/null"

log ""
log "=== RAS ==="
run "ls /sys/bus/pci/devices/$DEV/ras 2>/dev/null"
run "cat /sys/bus/pci/devices/$DEV/ras/features 2>/dev/null"
for r in /sys/bus/pci/devices/$DEV/ras/*_err_count; do
    [ -e "$r" ] && log "  $(basename "$r") = $(cat "$r" 2>/dev/null | tr '\n' ' ')"
done

log ""
log "=== KFD topology ==="
run "ls /sys/class/kfd/kfd/topology/nodes/ 2>/dev/null"
run "grep -H -E 'simd_count|gfx_target_version|vendor_id|device_id' /sys/class/kfd/kfd/topology/nodes/*/properties 2>/dev/null"

log ""
log "=== device nodes ==="
run "ls -l /dev/kfd /dev/dri/ 2>&1"

log ""
log "=== pci binding ==="
run "lspci -nnk -d 1002:75a8"

log ""
log "=== dmesg after load ==="
run "dmesg | tail -250"

# ---- now just sample until we die ----
log ""
log "=== sampling every 5s ==="
i=0
while true; do
    i=$((i+5))
    log ""
    log "--- T+${i}s  $(date +%H:%M:%S) ---"
    log "  amdgpu loaded: $(lsmod | grep -c '^amdgpu')   kfd: $(test -e /dev/kfd && echo yes || echo no)"
    dmesg | tail -25 >>"$OUT" 2>&1
    sync
    sleep 5
done
```

Note the guard near the top: the script **refuses to run** if the blacklist
file is missing. That prevents the obvious disaster of loading the driver on a
host that would then autoload it on every subsequent boot.

#### Running it

Detach it from the SSH session so a host hang doesn't take the log with it:

```bash
chmod +x /root/1-gpu-test.sh
setsid nohup /root/1-gpu-test.sh > /dev/null 2>&1 < /dev/null &
```

Optional module parameters go on the end, e.g. `/root/1-gpu-test.sh ras_enable=0`.

It samples forever — **stop it when you're done**:

```bash
pkill -f 1-gpu-test.sh
```

#### Pre-flight check

Before launching, confirm the state is actually clean:

```bash
lsmod | grep -c '^amdgpu'                            # expect 0
ls /usr/lib/firmware/updates/amdgpu | wc -l          # expect 661
grep -o 'modprobe.blacklist=amdgpu' /proc/cmdline    # expect a match
```

---

### 5. Verify the driver bound

```bash
D=/sys/bus/pci/devices/0000:03:00.0
ls $D/driver            # symlink to .../amdgpu  = bound
ls -l /dev/kfd          # compute device node exists
dmesg | grep -i 'Initialized amdgpu'
```

What a healthy MI350P bring-up looks like:

```
[drm] Initialized amdgpu 3.64.0 for 0000:03:00.0 on minor 1
```

plus seven further `amdgpu_xcp_N` lines, and in the KFD topology:

```
simd_count 512          # /4 SIMDs per CU = 128 CUs
gfx_target_version 90500   # gfx950 / CDNA 4 -- correct for MI350
num_xcc 4
vendor_id 4098          # 0x1002
device_id 30120         # 0x75A8
```

#### A benign message you will see, and should ignore

```
amdgpu: SMU: valid command, bad prerequisites: index:7 param:0x00000000
        message:RequestI2cTransaction
amdgpu: Failed to read EEPROM table header, res:-22
```

This appears on **every** MI350P we have tested under in-tree `amdgpu` 3.64.0
on kernel 6.18.41, including a card that is demonstrably healthy and sustains
full load. It means the RAS EEPROM cannot be read in-band. It is **not** a
fault indicator — we originally reported it to AMD as one and had to retract
that. Do not treat it as evidence of a bad card.

What *would* be a real fault signal: `ERREVENT_ATHUB_INTERRUPT`, uncorrectable
error counts, GPU reset, or ring timeouts.

```bash
dmesg | grep -iE "ERREVENT|ATHUB|poison|uncorrectable|GPU reset|ring timeout"
```

---

### 6. Prove it computes — a real workload

Binding the driver only shows the card is *present*. To show it works you need
a ROCm userspace, and Garden Linux has none. Rather than installing one into a
read-only `/usr`, run a container: `containerd` is already installed on the
image, just disabled.

#### 6.1 Start the runtime and pull the image

```bash
systemctl start containerd
ctr image pull docker.io/rocm/pytorch:latest        # 10.9 GB, ~7 min at 32 MiB/s
```

#### 6.2 Confirm ROCm userspace sees the card

```bash
ctr run --rm --privileged --net-host \
  --device /dev/kfd --device /dev/dri \
  docker.io/rocm/pytorch:latest rocmcheck rocminfo | grep -A3 'Agent 3'
```

Expect:

```
Name:             gfx950
Marketing Name:   AMD Instinct MI350P
Compute Unit:     128
```

If `rocminfo` reports no GPU agent, the ROCm version is too old for gfx950 —
CDNA 4 needs a recent release (the image used here carried ROCm 10.1 / HIP 7.16).

#### 6.3 The workload script

#### `/root/1-gpu-workload.py`

```python
import os, time, torch

print("=" * 64)
print("torch           :", torch.__version__)
print("ROCm/HIP version:", getattr(torch.version, "hip", None))
print("GPU available   :", torch.cuda.is_available())
n = torch.cuda.device_count()
print("device count    :", n)
for i in range(n):
    p = torch.cuda.get_device_properties(i)
    print(f"  [{i}] {p.name}  arch={getattr(p,'gcnArchName','?')}  "
          f"VRAM={p.total_memory/2**30:.1f} GiB  CUs={p.multi_processor_count}")
print("=" * 64, flush=True)

if not torch.cuda.is_available():
    raise SystemExit("no GPU visible to the ROCm runtime")

dev = torch.device("cuda:0")
N = int(os.environ.get("N", 8192))
SECS = int(os.environ.get("SECS", 120))

# allocate a few GB so VRAM usage is clearly visible from the host sysfs
a = torch.randn(N, N, device=dev, dtype=torch.float32)
b = torch.randn(N, N, device=dev, dtype=torch.float32)
ballast = torch.empty(int(8e9 // 4), device=dev, dtype=torch.float32)  # ~8 GB
torch.cuda.synchronize()
print(f"allocated: {torch.cuda.memory_allocated(dev)/2**30:.1f} GiB on device 0", flush=True)

flop_per_iter = 2.0 * N ** 3
t_end = time.time() + SECS
it = 0
t0 = time.time()
last = t0
while time.time() < t_end:
    c = a @ b
    it += 1
    if it % 20 == 0:
        torch.cuda.synchronize()
        now = time.time()
        tflops = 20 * flop_per_iter / (now - last) / 1e12
        print(f"  t+{now-t0:6.1f}s  iters={it:6d}  {tflops:7.1f} TFLOP/s fp32  "
              f"checksum={float(c[0,0]):.4f}", flush=True)
        last = now
torch.cuda.synchronize()
total = time.time() - t0
print("=" * 64)
print(f"DONE  {it} matmuls of {N}x{N} in {total:.1f}s  "
      f"avg {it*flop_per_iter/total/1e12:.1f} TFLOP/s fp32")
print("peak VRAM allocated: %.1f GiB" % (torch.cuda.max_memory_allocated(dev)/2**30))
print("=" * 64)
```

#### 6.4 Run it

```bash
ctr run --rm --privileged --net-host \
  --device /dev/kfd --device /dev/dri \
  --mount type=bind,src=/root/1-gpu-workload.py,dst=/workload.py,options=rbind:ro \
  --env SECS=180 --env N=8192 \
  docker.io/rocm/pytorch:latest gpuload python3 /workload.py
```

`SECS` controls the duration, `N` the matrix size. For a genuinely heavy
burn-in rather than a functional check, raise `N` to 16384 and switch the
tensors to `torch.bfloat16` — that exercises the matrix cores, where CDNA 4's
real throughput lives.

#### 6.5 Watch it from the host

These counters come straight from the driver and need no tooling at all:

```bash
D=/sys/bus/pci/devices/0000:03:00.0
watch -n2 "cat $D/gpu_busy_percent $D/mem_busy_percent $D/mem_info_vram_used \
           $D/hwmon/hwmon*/freq1_input"
```

> **`power1_average` and `temp1_input` are not exposed** by this driver build —
> only `power1_cap` and `freq1_input`. Power and temperature will read as
> absent or zero. Use the clock as the activity proxy; don't conclude the card
> is dead because power reads nothing.

---

### 7. Reading the output

A sample line looks like:

```
  t+  58.4s  iters=  3260     58.5 TFLOP/s fp32  checksum=-62.6513
```

| Field | Meaning |
|---|---|
| `t+ 58.4s` | seconds since the loop started, after allocation |
| `iters= 3260` | matmuls completed so far |
| `58.5 TFLOP/s` | throughput over the **last 20** iterations, not the average |
| `checksum=` | element `[0,0]` of the result |

**The checksum is the field to watch.** The same two matrices are multiplied
repeatedly, so the answer must be bit-identical every time. If it drifts
mid-run, the GPU is computing wrong answers — silent data corruption, which is
worse than a crash. (It differs *between* runs because `torch.randn` is
unseeded; that is expected.)

**Sanity-checking the throughput.** Theoretical fp32 peak is
`CUs × 64 lanes × 2 (FMA) × 2 (packed fp32) × clock`. At the 128 CUs this card
reports, that is 32768 × clock:

| Observed clock | Theoretical | Measured | Efficiency |
|---|---|---|---|
| 2189 MHz (boost) | 71.7 TFLOP/s | 71.3 | 99% |
| 1760 MHz (sustained) | 57.7 TFLOP/s | 58.1 | ~100% |

Hitting ~100% of theoretical on a real matmul is the result you want: rocBLAS
is picking good kernels and memory bandwidth is keeping the CUs fed.

**Throughput drifting downward is normal.** It tracks the clock, not
efficiency, and is explained by:

```
amdgpu: WARN: GPU is throttled, expect performance decrease. SOC.
```

That message is informational. Expect it under sustained all-CU load.

**Calibrate expectations:** fp32 is the *least* impressive path on CDNA 4. The
petaflop-scale MI350 headline figures are bf16/fp8/fp4 on the matrix cores, an
order of magnitude above anything fp32 will show.

---

### 8. Result of the 2026-10-13 run

```
torch 2.14.0+rocm10.1.0    HIP 7.16.26385
AMD Instinct MI350P   gfx950:sramecc+:xnack-   128 CUs   144.0 GiB

DONE  9580 matmuls of 8192x8192 in 180.1s  avg 58.5 TFLOP/s fp32
peak VRAM allocated: 8.5 GiB
```

- `gpu_busy_percent` pinned at **100** for the full run
- VRAM 0.3 → 9.3 GiB, clocks 95 MHz idle → 2189 MHz boost → ~1760 sustained
- Checksum bit-stable throughout
- **Zero** RAS events, ATHUB events, resets or ring timeouts
- Clean return to idle afterwards; host remained up

Firmware versions read off the card while bound:

```
smc (SMU)  0x00563d00     sos (PSP)  0x0045002f
ta_ras     0x1b45000a     ta_xgmi    0x20000014
mec/mec2   0x0000002c     rlc        0x0000002b
sdma       0x0000000e     vcn        0x0910d001
VBIOS      113-350P-01-1K1-0700
```

---

### 9. Gotchas

1. **`BootNext` is one-shot.** If you are dual-booting into Garden Linux, it is
   consumed by each boot and discarded. Re-arm it *every* time
   (`efibootmgr --bootnext 0009`) or your "reboot for a clean test" lands in
   Ubuntu. This cost one wasted cycle.
2. **Use `https://` for the Debian firmware mirror.** Plain HTTP hung for eight
   minutes with no error. See §3.1.
3. **`modprobe amdgpu` alone will not work** once `install amdgpu /bin/false`
   is in place. Use `--ignore-install`. This is deliberate.
4. **Remount `/usr` read-write** before touching firmware or `modprobe.d`, and
   put it back read-only afterwards.
5. **Don't put modprobe config in `/etc/modprobe.d/`** — `gardener-node-agent`
   reconciles `/etc` and may revert it. Use `/usr/lib/modprobe.d/`.
6. **The harness runs forever.** `pkill -f 1-gpu-test.sh` when finished.
7. **No OS-level serial console.** The BMC SOL carries UEFI output only, so a
   hang during a load test is silent. Rely on the blacklist plus a BMC power
   cycle rather than expecting to watch it fail.

---

### 10. Leftover state after this procedure

- `containerd` is **running but still `disabled`** — it will not come back after
  a reboot unless you `systemctl enable` it.
- `rocm/pytorch:latest` occupies ~30 GB unpacked. Remove with
  `ctr image rm docker.io/rocm/pytorch:latest`.
- `amdgpu` remains blacklisted at boot by design. Nothing loads the driver
  automatically; every load is explicit.
- To make the GPU available normally, remove
  `/usr/lib/modprobe.d/blacklist-amdgpu.conf` and the
  `modprobe.blacklist=amdgpu` cmdline token — but only once the card has proved
  stable, since you lose the guaranteed-clean boot.

---

## 2. The host and the target architecture

What the machine is, the state it starts in, and the addressing decisions
that have to be made before chapter 3.

---

### 1. The host

| | `10.20.154.203` |
|---|---|
| Hostname | `gpu-node-gl` |
| Role | Gardener management plane **and** GPU workload cluster |
| GPU | MI350P — healthy, verified |
| OS | Garden Linux 2150.8.0 (`40f62d58`) |
| Kernel | 6.18.41-amd64 |
| Board / BIOS | Chalupa / `TC1TG1008B_EDKII_GCC` |
| CPU | EPYC 9965 — 192C / 768T |
| Memory | 1511 GB |
| Disks | `nvme0n1` 466 GB (Ubuntu) + `nvme1n1` 3.6 TB (Garden Linux) |
| Network | `eno1` — 10.20.154.203/19 |
| Gateway | 10.20.159.254 |
| SSH | `root`, ed25519 key |
| BMC | `https://bmc.example.com`, `root` / `<REDACTED>` |
| Boot | **Dual boot — Ubuntu is the default** |

The GPU sustained 58.5 TFLOP/s for 180 s with no faults in chapter 1, which is
what qualifies one machine to carry the whole stack.

> **This began as a two-host design.** A second machine — plenty of CPU and
> memory, but a faulty accelerator — was to carry the Gardener management
> plane while this host ran the GPU workloads. It was abandoned during the
> build: the two subnets complete a TCP handshake but reset the connection on
> the first payload, in both directions, so `gardenadm connect` could never
> reach across. If your network does permit it, putting the management plane
> on a second host is the more conventional arrangement, and the procedure in
> chapters 3 and 4 is the same — only the addresses differ, and the two
> clusters then need non-overlapping pod and service ranges.

---

### 2. Starting state

**No Kubernetes, and the host never had any.** Garden Linux is installed and
running with a working GPU driver and 661 firmware blobs in place. None of the
Gardener prerequisites are present — no `gardenadm`, no registry, no container
images. Chapter 3 §2 installs them.

Two host-level items must be settled before the machine can be a cluster node.
Both are the subject of chapter 3 §1:

- **Ubuntu is still the default boot entry.** Garden Linux is reached only
  through a one-shot `efibootmgr --bootnext`, so any reboot silently returns
  the machine to Ubuntu and removes it from the cluster.
- **`amdgpu` is blacklisted** in `/usr/lib/modprobe.d/` *and* on the kernel
  command line. Correct for crash-safe driver testing, incompatible with
  serving GPU workloads.

---

### 3. Why `gardenadm`

Gardener **provisions** clusters rather than adopting existing machines. A
`Shoot` normally drives a cloud API plus `machine-controller-manager` to create
VMs, and with no programmable infrastructure there is no such API to drive.
Upstream calls this the *unmanaged infrastructure* case, and `gardenadm` is the
tool for it: it collapses the garden, seed and shoot layers onto hardware you
already have.

That collapse is what produces the two control planes on one node described at
the top of this page.

> `gardenadm` is upstream-flagged **"highly experimental, do not use in
> production"** (GEP-0028). Acceptable for an evaluation; worth stating.

---

### 4. Constraints that shape the build

**The pod CIDR must not contain the node address.** A configuration carried
over from an earlier deployment used:

```yaml
networking:
  nodes:    10.21.167.0/24
  pods:     10.20.0.0/16     # contains 10.20.154.203
  services: 10.2.0.0/16
```

Chapter 3 §3 sets the ranges that were actually used, and explains why this
particular overlap turned out to be harmless.

**MetalLB must serve the node's own subnet.** A pool is only useful if its
addresses sit on a network the node answers ARP for. This build uses
`10.20.154.250-252`, out of the node's own `/19`.

**VIPs are not excluded from DHCP.** DHCP is served centrally from
`10.22.15.2` and the VIP addresses have not been excluded from its pool. An
unexcluded VIP works until it does not, and the failure does not look like an
address conflict.

---

## 3. Build the cluster on the host

A single `gardenadm init` on the host produces the Kubernetes cluster that
everything else sits in: the control plane runs as static pods on the node
itself. The next chapter adds Gardener on top of it.

> **Where this procedure comes from.** The reference build ran these steps on
> two machines before collapsing onto one, so a few commands still read as
> though a second machine exists — the local registry in §2 in particular was
> populated by copying it from the other host. On a genuinely single-host
> build you need another way to fill that registry; everything else applies
> unchanged.

### 1. Host decisions to settle first

Two things about this host are currently configured for GPU *crash testing*,
not for production service. Both must change, and both are deliberate
trade-offs rather than oversights.

#### 1.1 Make Garden Linux the permanent boot entry

Today Ubuntu is the default and Garden Linux is reached only through a one-shot
`BootNext`. **Any reboot silently returns the machine to Ubuntu**, which would
remove it from the cluster with no obvious cause.

```bash
ssh -F /dev/null root@10.20.154.203
efibootmgr                      # identify the GardenLinux entry (was 0009)
efibootmgr -o 0009,0007,0004,0005,0001,0006,0003,0002,0000,0008
efibootmgr | grep BootOrder     # must now start 0009
```

Keeping `0007` (Ubuntu) second preserves the fallback. Confirm with a real
reboot **before** building a cluster on top of it:

```bash
reboot
# wait ~5.5 min, then:
ssh -F /dev/null root@10.20.154.203 'grep PRETTY_NAME /etc/os-release'
```

> This gives up the current safety property that every boot comes up in a known
> state. Once Garden Linux is the default, a boot-time failure needs the BMC
> (`https://bmc.example.com`, KVM available) rather than a power cycle.

#### 1.2 Decide what to do about the `amdgpu` blacklist

The driver is currently blocked at two levels, so that a GPU hang can never
make the host unbootable:

```
/usr/lib/modprobe.d/blacklist-amdgpu.conf    blacklist amdgpu
                                             install amdgpu /bin/false
kernel cmdline                               modprobe.blacklist=amdgpu
```

For the node to serve GPU workloads the driver must load automatically at boot,
which means removing both. See chapter 1 for what they do and why
they were added.

The card is known-good — it initialised fully and sustained 58.5 TFLOP/s for
180 s with no faults — so the risk is low. But the blacklist is the reason this
host has been trivially recoverable all along — an identical card in a second
machine killed it within seconds of driver init.

**Suggested order:** keep the blacklist while building and connecting the
cluster, and remove it only once the cluster is healthy and you are ready to
schedule GPU work. The cluster itself does not need the GPU.

---

### 2. Install the Gardener prerequisites

A host coming from chapters 0 and 1 has **none** of them. Everything below has
to be created from scratch.

#### 2.1 `gardenadm`

`/usr` is read-only on Garden Linux, so install under `~/bin`. The release
asset is a **gzip tar archive**, not a raw executable.

```bash
mkdir -p ~/silo-setup-gardener ~/bin extracted
cd ~/silo-setup-gardener

VERSION=v1.149.3        # must match the Gardener version on .78
curl -fsSL -o gardenadm-linux-amd64 \
  "https://github.com/gardener/gardener/releases/download/${VERSION}/gardenadm-linux-amd64"

head -c 2 gardenadm-linux-amd64 | od -An -tx1    # 1f 8b = gzip; 7f 45 = ELF
tar -xzf gardenadm-linux-amd64 -C extracted
mv extracted/gardenadm-linux-amd64 ~/bin/gardenadm
chmod +x ~/bin/gardenadm
export PATH="$HOME/bin:$PATH"
~/bin/gardenadm version
```

#### 2.2 `kubectl`

Garden Linux ships none. Match the server version.

```bash
curl -fsSLo ~/bin/kubectl https://dl.k8s.io/release/v1.35.4/bin/linux/amd64/kubectl
chmod +x ~/bin/kubectl
```

#### 2.3 Container runtime

`containerd` is present on the Garden Linux image but **disabled** — it was
started by hand for the GPU test. Enable it so it survives a reboot:

```bash
systemctl enable --now containerd
systemctl is-enabled containerd     # must read: enabled
```

#### 2.4 Local registry and image artifacts

**Why a registry is needed at all.** Not for ordinary images. The host has
internet egress and reaches Docker Hub, `registry.k8s.io`, `ghcr.io` and
`europe-docker.pkg.dev` directly, so kube-apiserver, etcd, Istio, gardenlet and
everything else pull normally. The registry exists for exactly four artifacts
that are **built from source by skaffold and published nowhere**:

```
local-skaffold_cloud-controller-manager-local
local-skaffold_gardener-extension-provider-local
local-skaffold_gardener-extension-provider-local_charts_extension
local-skaffold_gardener-extension-provider-local_loadbalancer
```

They are the `provider-local` extension. Since the whole deployment runs on
`provider-local`, this host needs them, and no public registry can supply them.

**Decision: give this host its own registry** (confirmed 2026-10-14, done). A
shared registry is not merely inelegant, it is impossible: **there is no usable
TCP data path between the two subnets in either direction.** The handshake
completes and the connection is reset as soon as any payload is sent — on every
port tried, for TLS and plain HTTP alike.

> **Test reachability by reading a byte back.** An earlier revision of this
> procedure called a port "open" on the strength of
> `echo > /dev/tcp/host/port`. That is not a test: it completes the handshake
> and never reads a response, so it cannot observe a connection that is reset
> on the first payload — which is exactly the failure that ended the two-host
> design. Always read something back:
>
> ```bash
> exec 3<>/dev/tcp/<host>/22; head -c 60 <&3     # expect an SSH banner
> ```

**Populating the registry.** The reference build had a second machine with an
already-populated registry at this point, and copied its storage directory
wholesale, which preserves every digest:

```bash
# on the machine that already has the images
sudo tar czf /tmp/registry-data.tgz -C /opt/local-registry data
# then on this host
systemctl stop local-registry
rm -rf /opt/local-registry/data
tar xzf /tmp/registry-data.tgz -C /opt/local-registry
systemctl start local-registry
```

With no such machine available you have to fill the registry another way —
pulling and pushing the Gardener images, or running `skaffold` against it.
That path was not exercised here, so treat it as unverified.

Setup script: `host-registry-setup.sh`, run unmodified. Note it does *not*
write `/etc/containerd/config.toml`. This host had none at all, so one was
written by hand, including `config_path = "/etc/containerd/certs.d"`.

#### 2.5 `/etc/hosts`

The cluster's own API server name must resolve on the node:

```
10.20.154.203   api.<name>.garden.external.local.gardener.cloud
127.0.0.1        registry.local.gardener.cloud        # if hosting locally
```

---

### 3. Plan the addressing and write the manifests

Start from the `manifests.yaml` of any previous deployment and change every
address and name. Four ranges are in play — the node subnet, the pod CIDR, the
service CIDR, and later the MetalLB pool — and none of them may overlap.

```yaml
metadata:
  name: gpu
spec:
  dns:
    domain: gpu.garden.external.local.gardener.cloud
  networking:
    nodes:    10.20.128.0/19           # this host's subnet
    pods:     10.244.0.0/16             # NOT 10.20.0.0/16 - see below
    services: 10.3.0.0/16
    type:     calico
  provider:
    workers:
      - name: control-plane
        minimum: 1
        maximum: 1
        controlPlane: {}
```

**Do not leave the pod CIDR at `10.20.0.0/16`.** A configuration carried over
from an earlier deployment used that range, and it contains this host's own
address `10.20.154.203`.

> **The Shoot's pod CIDR is not what Calico actually uses.** Verified on the
> reference host: Calico's `default-ipv4-ippool` is `10.1.0.0/16`, and pods are
> addressed from it whatever the `Shoot` says — a probe pod came up on
> `10.1.20.24`. The `10.20.0.0/16` overlap was therefore never in effect, and
> re-addressing was a correctness fix rather than the rescue it looked like.
> The practical consequence appears in chapter 4 §1: the `Garden` resource must
> declare the range Calico hands out, not the one in the `Shoot`.

Worth reviewing in the same file while it is open:

| Field | Value used | Note |
|---|---|---|
| `metadata.name` | `gpu` | The Shoot's name in the garden; it becomes `garden/gpu` |
| `spec.dns.domain` | `gpu.garden.external.local.gardener.cloud` | Must stay consistent with the `/etc/hosts` entry |
| `kubernetes.version` | `1.35.4` | The CloudProfile also offers 1.36.0 and 1.34.3 |
| worker pool `worker` | `min 1 / max 2` | There is only one machine, so chapter 4 §5 has to patch this to `minimum: 0` |

The `CloudProfile`, `Project`, `ControllerRegistration`, `ControllerDeployment`
and `Extension` resources in the original file are also needed for
`gardenadm init`. They are **cluster-scoped shared definitions**, so unlike the
`Shoot` they keep their original names (`local`, `garden`, `networking-calico`,
`provider-local`) and must match what chapter 4 §3 applies to the garden —
`gardenadm connect` verifies the `CloudProfile` and controller registrations
exist there by name, and aborts if they do not.

The `Shoot` is the only object that must be renamed.

---

### 4. Run `gardenadm init`

```bash
sudo ~/bin/gardenadm init --config-dir ~/silo-setup-gardener/manifests 2>&1 \
  | tee ~/gardenadm-init.log
```

Take a kubeconfig once it finishes, then carry on through §5 to §7, which are
the three post-init steps the cluster is not usable without:

```bash
sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $USER ~/.kube/config
kubectl get nodes
```

**`gardenadm init` cannot resume a failed run**, so reset fully before any
second attempt. The fixed reset script is staged at
`/root/silo-setup-gardener/scripts/host-reset-gardenadm.sh` (2026-10-14). It
unmounts the kubelet tree deepest-first before removing it, and flushes the
leftover kube-proxy and Calico rules that a reset previously left behind.

---

### 5. Fix in-cluster DNS for the API server

The `/etc/hosts` entry covers the kubelet and host-network pods but **not**
ordinary pods, which resolve through CoreDNS at `10.2.0.10`. Without this,
`cloud-controller-manager` sits in `CrashLoopBackOff` and no `LoadBalancer`
service ever gets an address.

```bash
kubectl -n kube-system patch cm coredns-custom --type merge \
  -p '{"data":{"apiserver.override":"hosts {\n  10.20.154.203 api.gpu.garden.external.local.gardener.cloud\n  fallthrough\n}\n"}}'
kubectl -n kube-system rollout restart deploy/coredns
kubectl -n kube-system rollout status deploy/coredns --timeout=120s

kubectl -n kube-system delete pod -l app=kubernetes,role=cloud-controller-manager
kubectl -n kube-system get pods -l app=kubernetes,role=cloud-controller-manager
```

`coredns-custom` is annotated `resources.gardener.cloud/ignore: "true"`, so
`gardener-resource-manager` will not revert it — which is why it is the durable
place for the mapping. Healthy means `1/1 Running` with
`Syncing backends for all LB services` in the log.

---

### 6. Untaint the control-plane node

`gardenadm` taints the node `node-role.kubernetes.io/control-plane:NoSchedule`
automatically, because the worker pool carries a `controlPlane:` block. On a
single-node cluster that reserves the entire machine for system components, and
**nothing you deploy afterwards will schedule**.

```bash
kubectl taint node localhost node-role.kubernetes.io/control-plane-
kubectl get node localhost -o jsonpath='{range .spec.taints[*]}{.key}{"\n"}{end}'
```

Empty output means no taints remain. Confirm end to end:

```bash
kubectl -n default run taint-probe --image=registry.k8s.io/pause:3.9 --restart=Never
kubectl -n default get pod taint-probe -o wide     # Running, not Pending
kubectl -n default delete pod taint-probe
```

The taint returns whenever the `Node` object is recreated, so make it
declarative in `manifests.yaml` rather than relying on the command.

---

### 7. MetalLB

The Gardener API is exposed through an Istio `LoadBalancer` service, so MetalLB
must exist first.

```bash
kubectl apply --server-side -f metallb-native.yaml     # v0.15.2
```

Then an `IPAddressPool` plus an `L2Advertisement` referencing it. The pool
exists in no repository and must be created by hand. This build uses
`gpu-cluster-ip-pool` = **`10.20.154.250-252`**, out of the node's own `/19`.
Three addresses because three services want port 443 — the Gardener Istio
ingress, the runtime nginx ingress, and the application gateway.

Finding free addresses — ARP is the reliable test, since a silent host answers
ARP while ignoring ping:

```bash
for i in $(seq 240 254); do ping -c1 -W1 10.20.154.$i >/dev/null 2>&1 & done; wait
ip neigh show | grep eno1    # FAILED = unclaimed, REACHABLE/STALE = in use
```

Validate the sweep against a known-used address — the gateway,
`10.20.159.254` — before trusting it.

> **Reserve the VIPs until MetalLB is ready for them.** DHCP for this subnet is
> served centrally from `10.22.15.1`, and a network-team exclusion was not
> obtainable. Instead the addresses were claimed directly on the host so that
> nothing else could be given them:
>
> ```bash
> ip addr add 10.20.154.250/32 dev eno1    # .251 and .252 likewise
> ```
>
> persisted in `/etc/systemd/network/99-default.network.d/10-reserved-vips.conf`.
> Because `arp_ignore=0` the host answers ARP and ICMP for all three, which
> makes a probing DHCP server skip them, and makes any client that is offered
> one send a `DHCPDECLINE` after duplicate-address detection. This is
> best-effort, not a guarantee: a DHCP server that neither probes nor honours
> declines could still hand an address out.
>
> **Release them before applying the `IPAddressPool`:**
>
> ```bash
> sudo rm /etc/systemd/network/99-default.network.d/10-reserved-vips.conf
> sudo networkctl reload
> for i in 250 251 252; do sudo ip addr del 10.20.154.$i/32 dev eno1; done
> ```
>
> Leaving them bound to the host while MetalLB also announces them is likely to
> work (same MAC either way) but has not been tested — release them instead.

> **Deleting a `LoadBalancer` service hangs.** `provider-local` implements
> `LoadBalancer` by starting a Docker container on the host; Garden Linux runs
> containerd with no Docker daemon, so cloud-controller-manager fails on every
> reconcile. Create them freely, but avoid deleting.

---

## 4. Deploy Gardener and connect the cluster

The cluster from chapter 3 now gets the Gardener control plane installed
*into itself*, and is then registered as a `Shoot` against that same garden.
This is what produces the second control plane described at the top of this
page.

> **Status.** Executed on the reference host 2026-10-14. The four problems
> that had to be solved during that run are called out inline, each marked
> **Fix**.

### 1. Deploy the Gardener control plane

This is what turns the cluster into a management plane.

#### 1.1 Install the operator

Safe on its own — it does nothing until a `Garden` resource exists.

```bash
helm install gardener-operator ./charts/gardener/operator \
  -n garden --set image.tag=v1.149.3
```

It lands in the `garden` namespace, which already contains `etcd-druid` and
`gardener-resource-manager` from `gardenadm init`. That looks alarming: the
same `etcd-druid` manages the cluster's own `etcd-main`/`etcd-events`. It does
not roll them, as long as both sides are the same Gardener version. Previously
observed: both etcd pods stayed `Running` with unchanged restart counts through
the whole reconciliation.

Take an etcd snapshot first anyway.

#### 1.2 Create the Garden

```bash
kubectl apply --server-side -f garden.yaml
```

`garden.yaml` is an `operator.gardener.cloud/v1alpha1` `Garden`. There is no
copy in this repository — take the upstream example and change the networking,
which is the part that has to agree with what this cluster actually uses:

```yaml
apiVersion: operator.gardener.cloud/v1alpha1
kind: Garden
metadata:
  name: garden
spec:
  runtimeCluster:
    networking:
      pods:     10.1.0.0/16      # what Calico hands out - see chapter 3 §3
      services: 10.4.0.0/16
  virtualCluster:
    networking:
      services: 10.5.0.0/16
```

**The pod range must be the one Calico actually hands out**, not the one the
`Shoot` declares. Chapter 3 §3 explains why those differ; getting it wrong
here is the kind of mistake that only shows up much later, as pods that cannot
reach the virtual garden.

All three service ranges — the cluster's own, the runtime's and the virtual
cluster's — must be distinct from each other and from the pod range.

Reconciliation takes roughly **seven minutes**:

```bash
kubectl get garden garden \
  -o jsonpath='{.status.lastOperation.state} {.status.lastOperation.progress}% {.status.lastOperation.description}'
```

Done when all four conditions are `True`:

```
VirtualGardenAPIServerAvailable   RuntimeComponentsHealthy
VirtualComponentsHealthy          ObservabilityComponentsHealthy
```

Two deliberate choices in that file:

- **No `spec.dns` provider** — so the operator creates no `DNSRecord`s. DNS
  here is real records plus the CoreDNS hosts entry.
- **No `loadBalancerServices.annotations`** — that block applies to *every*
  LoadBalancer the operator creates, and Istio and the runtime nginx ingress
  both want port 443. Pinning one address there makes them collide. MetalLB
  auto-assigns instead.

---

### 2. DNS and reaching the Gardener API

| Record | Points to | Why |
|---|---|---|
| `api.virtual-garden.gpu.gardener.example.com` | `10.20.154.250` | Longest match beats the wildcard |
| `gardener.example.com`, `*.gardener.example.com` | `10.20.154.251` | Application gateway |

**The hostname is not optional.** Istio routes by SNI, and pointing `kubectl`
at the raw IP fails with `421 Misdirected Request` — setting `tls-server-name`
fixes SNI but the HTTP `Host` header still carries the IP and Istio rejects the
mismatch.

Extract the kubeconfig (12-hour service account token; re-extract when it
lapses rather than assuming it is stale):

```bash
kubectl get secret gardener -n garden -o jsonpath='{.data.kubeconfig}' \
  | base64 -d > kubeconfig-virtual-garden.yaml
```

Prove you reached the Gardener and not the host's own apiserver —
`core.gardener.cloud` is served only by the Gardener control plane:

```bash
kubectl --kubeconfig kubeconfig-virtual-garden.yaml get projects
```

> That kubeconfig carries a live token. Do not commit it.

---

### 3. Seed the garden with CloudProfile and controller registrations

`gardenadm connect` **will not create these**. It only checks they exist, and
fails with *"this is not created by 'gardenadm connect' and must exist in the
garden cluster"*. Apply them to the Gardener API first.

Required before §5 can connect:

| Resource | Source |
|---|---|
| `CloudProfile` | The one named in the cluster's manifests — `local` in the originals |
| `ControllerRegistration` + `ControllerDeployment` | `networking-calico` (and `networking-cilium` if referenced) |
| `Project` | Created by `connect`, but the namespace must be consistent |

```bash
export KUBECONFIG=~/kubeconfig-virtual-garden.yaml
kubectl apply --server-side -f <cloudprofile-and-registrations.yaml>
kubectl get cloudprofile,controllerregistration,controllerdeployment
```

The backup at `backups/pre-wipe-20261013/silo-setup-gardener-config.tar.gz`
contains exactly these objects (verified):

```
CloudProfile            local
ControllerDeployment    networking-calico, networking-cilium
ControllerRegistration  networking-calico, networking-cilium
Extension               provider-local
Namespace               garden
Project                 garden
Secret                  backup-local
Shoot                   root
```

Two things to note before reusing them:

- **The provider is `provider-local`.** That is Gardener's development/testing
  provider, not a production one. It is what the previous deployment ran on
  for 43 days, so it works — but the `CloudProfile` and every `Shoot` must stay
  consistent with it.
- **Shoot names must be unique in the garden.** An earlier deployment used
  `root` in namespace `garden`; this build uses `garden/gpu`, set in chapter 3
  §3. Two Shoots of the same name collide.

---

### 4. Create the bootstrap token

Chapter 4 needs a token, the CA bundle and the API address. One command emits
all three, provided `KUBECONFIG` points at **the garden cluster** rather than
this host's own apiserver:

```bash
export KUBECONFIG=~/kubeconfig-virtual-garden.yaml
~/bin/gardenadm token create \
  --print-connect-command \
  --shoot-namespace garden \
  --shoot-name gpu \
  --validity 2h
```

Output is directly runnable on the host:

```
gardenadm connect --bootstrap-token <id>.<secret> --ca-certificate "<base64>" <garden-api-host>
```

`--shoot-namespace` and `--shoot-name` are **mandatory** with
`--print-connect-command` and must match the `Shoot` that `connect` will
create from the cluster's manifests. Validity defaults to 1 hour, maximum 24.

> Use `--print-connect-command`, not `--print-join-command`. The latter adds a
> *node* to this cluster and validates the kubeconfig points at a Shoot, which
> fails against the garden.

---

### 5. Connect the cluster to its own garden

This is the step that realises the architecture: it deploys `gardenlet` on this
host and registers the cluster with the garden running on this same machine.

#### 5.0 What `connect` actually does

Read from the v1.149.3 source (`pkg/gardenadm/cmd/connect/connect.go`), because
the CLI reference is thin. The flow is:

1. Build a client to the **garden cluster** from the positional address, the CA
   and the bootstrap token.
2. Retrieve a short-lived kubeconfig for the garden cluster.
3. **Prepare Gardener resources in the garden cluster** — creates `Project`,
   `ConfigMap`, `Secret`, `WorkloadIdentity`, `SecretBinding`,
   `CredentialsBinding`, and the **`Shoot`** representing this cluster, then
   patches the Shoot status.
4. **Deploy gardenlet** into this self-hosted shoot (Helm chart pulled from OCI).
5. Wait until gardenlet is ready.

So the `Shoot` resource is created *for* you — this is precisely the
"management cluster plus a resource describing the managed cluster" model.

> **Prerequisite that `connect` does NOT create.** It only *checks* for
> `CloudProfile`, `ControllerRegistration` and `ControllerDeployment`, failing
> with *"this is not created by 'gardenadm connect' and must exist in the
> garden cluster"*. Those must be applied to the garden beforehand —
> see chapter 3 §9a.

#### 5.1 Create the token on the garden — `--print-connect-command`

There is a dedicated flag that emits the entire command, CA included. Run it
**with `KUBECONFIG` pointing at the garden cluster**, not the host's
own apiserver:

```bash
export KUBECONFIG=~/kubeconfig-virtual-garden.yaml
~/bin/gardenadm token create \
  --print-connect-command \
  --shoot-namespace garden \
  --shoot-name gpu \
  --validity 2h
```

Output is directly runnable:

```
gardenadm connect --bootstrap-token <id>.<secret> --ca-certificate "<base64>" <garden-api-host>
```

Rules enforced by the code:

| Rule | Detail |
|---|---|
| Must point at the garden | Validates `core.gardener.cloud/v1beta1 Shoot` is served, else refuses |
| `--shoot-namespace` **and** `--shoot-name` required | With `--print-connect-command` both are mandatory |
| Must match the Shoot that will be created | From this cluster's manifests — `garden/gpu` here |
| `--description` is rejected | Conflicts with the auto-generated description |
| Validity | Default 1 h, minimum 10 m, maximum 24 h |
| Kubeconfig resolution | `$KUBECONFIG`, else `/etc/kubernetes/admin.conf` |

> Use `--print-connect-command`, **not** `--print-join-command`. The latter is
> for adding a *node* to an existing cluster and validates that the kubeconfig
> points at a Shoot, which would fail here.

#### 5.2 Run connect

The address is a **positional argument**, which the CLI reference example
omits:

```bash
sudo ~/bin/gardenadm connect \
  --bootstrap-token <id>.<secret> \
  --ca-certificate "<base64>" \
  https://api.virtual-garden.gpu.gardener.example.com
```

- `--config-dir` can be omitted — it defaults to the path `gardenadm init`
  recorded at `/var/lib/gardenadm/config-directory`, i.e. **this cluster's**
  manifests.
- The address becomes the REST `Host` with the Gardener scheme, so it is the
  **Gardener API endpoint**, not the cluster's own apiserver.

> **This host must resolve the Gardener hostname.** `--print-connect-command`
> emits whatever host the kubeconfig used, and Istio routes by SNI — a raw IP
> returns `421 Misdirected Request`. Add it to `/etc/hosts` unless real DNS
> already covers it:
>
> ```
> 10.20.154.250   api.virtual-garden.gpu.gardener.example.com
> ```

#### 5.3 Verify the registration

Against the Gardener API:

```bash
kubectl --kubeconfig kubeconfig-virtual-garden.yaml get shoots -A
kubectl --kubeconfig kubeconfig-virtual-garden.yaml get seeds
```

On the host:

```bash
kubectl get pods -A | grep gardenlet
```

A `gardenlet` pod running here plus the cluster appearing through the Gardener
API is the success condition for the whole exercise.

---

### 6. Enable the GPU for workloads

Only after the cluster is healthy and connected.

#### 6.1 Remove the blacklist

```bash
mount -o remount,rw /usr
rm /usr/lib/modprobe.d/blacklist-amdgpu.conf
mount -o remount,ro /usr

mount -o remount,rw /efi
E=$(find /efi/loader/entries -name '*.conf' | head -1)
sed -i 's/ modprobe.blacklist=amdgpu//' "$E"
grep ^options "$E"
sync
mount -o remount,ro /efi
```

Reboot and confirm the driver loads on its own:

```bash
lsmod | grep amdgpu
ls /dev/kfd
```

Firmware is already installed — 661 blobs in `/usr/lib/firmware/updates/amdgpu`.
See chapter 1.

#### 6.2 AMD GPU operator

The previous deployment ran `amd-gpu-operator` with a `DeviceConfig`. Two
things were needed there and will be again:

- the `DeviceConfig` node selector must match this node;
- **driver build must be disabled** — the operator defaults to compiling the
  driver, which does not work on Garden Linux. Use the in-tree `amdgpu` that is
  already proven on this host.

#### 6.3 Verify GPU scheduling

```bash
kubectl get nodes -o json \
  | jq '.items[].status.allocatable | with_entries(select(.key|test("amd")))'
```

Then run the workload from chapter 1 §6 as a Pod rather than via
`ctr`, to confirm the device reaches a container through Kubernetes.

---

### 7. Verification checklist

- [ ] Garden Linux is the **permanent** boot entry; survived a real reboot
- [ ] `containerd` is `enabled`, not just active
- [ ] `gardenadm` v1.149.3 and `kubectl` v1.35.4 installed under `~/bin`
- [ ] Registry decision made and images reachable
- [ ] Manifests written with non-overlapping node/pod/service CIDRs
- [ ] `gardenadm init` completed; node `Ready`
- [ ] CoreDNS override applied; control-plane taint removed
- [ ] `gardenadm connect` completed; `gardenlet` running
- [ ] Cluster visible through the Gardener API
- [ ] Blacklist removed; `amdgpu` loads automatically after reboot
- [ ] GPU resources advertised on the node and schedulable in a Pod

---

And on the Gardener side:

- [ ] Prerequisites intact — containerd, local registry, `/etc/hosts`, `gardenadm`
- [ ] Pod CIDR changed away from `10.20.0.0/16`
- [ ] `gardenadm init` completed; `kubectl get nodes` shows `Ready`
- [ ] CoreDNS override applied; `cloud-controller-manager` is `1/1 Running`
- [ ] Control-plane taint removed; a tolerationless pod schedules
- [ ] MetalLB installed, pool created, a `LoadBalancer` service gets an address
- [ ] `gardener-operator` installed in `garden`
- [ ] `Garden` reconciles `Succeeded`, all four conditions `True`
- [ ] DNS records resolve; `kubectl get projects` works against the Gardener API
- [ ] Bootstrap token obtained for chapter 4

---

### 8. Known gotchas and risks

1. **`gardenadm init` cannot be retried** without a full reset. See §4.
2. ~~**The reset script aborts on busy mounts.**~~ Fixed 2026-10-14 — it now unmounts deepest-first and flushes leftover kube-proxy/Calico rules.
3. **The control-plane taint silently blocks everything** you deploy. See §6.
4. **CoreDNS must know the API server name** or `cloud-controller-manager`
   crash-loops and no `LoadBalancer` ever gets an address. See §5.
5. **Deleting a `LoadBalancer` service hangs** under `provider-local` on
   containerd. See §7.
6. **Pass the full MetalLB range** if any installer re-applies the pool. A
   narrower range overwrites `cluster-bloom-ip-pool`, strands Istio's `.200`
   outside it and takes the Gardener API offline.
7. **`gardenadm` is upstream-experimental** (GEP-0028), explicitly not for
   production.

---

| Risk | Mitigation |
|---|---|
| Making Garden Linux the default boot removes the automatic Ubuntu fallback | BMC with KVM is available on this host; keep Ubuntu second in `BootOrder` |
| Removing the blacklist means a GPU hang can make the host unbootable | Card is verified good; do it last, and only after the cluster is proven |
| `gardenadm connect` has never been run to completion here | Semantics now confirmed from v1.149.3 source (§5.0); still unexecuted |
| `connect` aborts if `CloudProfile`/controller registrations are missing in the garden | Apply them first — chapter 3 §9a |
| Shoot name collides with one already in the garden | This build uses `garden/gpu` — chapter 3 §3 |
| `gardenadm init` cannot be retried | Fixed reset script already staged at `/root/silo-setup-gardener/scripts/` (2026-10-14) |
| Depending on another machine's registry couples the two | Keep the registry local to this host |
| `gardenadm` is upstream-experimental (GEP-0028) | Accepted for evaluation |

---

---

## 5. Telling the two control planes apart

You install the platform into control plane 1, the cluster itself — never
into the Gardener API. To see which one a kubeconfig speaks to, ask it for a
`Shoot`:

```bash
kubectl get shoots.core.gardener.cloud -A
```

The cluster API answers `the server doesn't have a resource type "shoots"`.
That is the API you want for the installation. The Gardener API answers with a
list, and you need that API for one step only: the pod limit, in section 8.1.

### Namespaces you must not change

Gardener owns these namespaces. If you delete an object in one of them, you
stop the management plane. On a self-hosted shoot the control plane is on the
same node, so you can also lose your own access.

```
garden                        the Gardener API and its controllers
kube-system                   the control plane, gardenlet, CoreDNS, Calico
istio-system                  the ingress that serves the Gardener API
virtual-garden-istio-ingress  the same, for the virtual garden
metallb-system                the load balancer (see section 8.2)
extension-provider-local      a Gardener extension
extension-networking-calico   a Gardener extension
```

`8-preflight.sh` reads this list and stops if the platform wants one of them.

---

## 6. What Gardener gives you, and what it takes away

### It gives you

| Component | Detail | Effect |
|---|---|---|
| Storage class `default` | `rancher.io/local-path` | The platform needs a class with this name. It is already here. |
| MetalLB | v0.15.2, an L2 pool of three addresses | Envoy Gateway gets an address with no change. See section 8.2. |
| CoreDNS | with a `coredns-custom` ConfigMap | You can add names without a DNS server. |
| Internet | the node pulls from public registries | The air-gap procedure is not necessary. |

### It takes away

| Limit | Value on the test node | Effect |
|---|---|---|
| Pod limit | `maxPods: 110`, and Gardener uses 82 | Only 28 pods are free. This is not sufficient. See section 8.1. |
| Node capacity | 100 CPU and 100Gi, on hardware with 768 cores and 1.5Ti | The scheduler sees the smaller number. |
| Network policies | 17 of them in `kube-system` | A pod that you start in `kube-system` has no network. |
| `/usr` | read-only, and 90% full | Install host binaries in `/root/bin`, not in `/usr`. |
| `/etc` | `gardener-node-agent` reconciles it | A manual change to `/etc` can be removed again. |

Measure the first two on your own cluster:

```bash
kubectl get node -o jsonpath='{.items[0].status.capacity}' | python3 -m json.tool
echo "pods now: $(kubectl get pods -A --no-headers | wc -l)"
```

---

## 7. Before you start

### The cluster

| Item | Requirement |
|---|---|
| Kubernetes | 1.28 or newer. The test used 1.35.4. |
| Nodes | One is sufficient. The node must not have a taint, or the charts need a toleration. |
| Storage class | One class named `default`. Gardener supplies it. |
| GPU | Not necessary for `demo-cpu`. The test node has one MI350P, and `demo-cpu` does not use it. |
| Addresses | One free address in the MetalLB pool. Gardener uses one of three. |
| Network | The node pulls from `docker.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`, `gcr.io` and `github.io`. |

### Your workstation

Spur needs `go`, `helm`, `just`, `kubectl` and the network to build its
binary. The scripts in this directory need `bash` 4 or newer, `kubectl` and
`python3`.

### A kubeconfig for the cluster

Take the kubeconfig from the node, at `/root/.kube/config`. Its `server` field
holds a name that only the node resolves. Replace the name with the node
address, and keep the name for the certificate:

```yaml
server: https://<node-address>
tls-server-name: <the original name>
```

With `tls-server-name` you do not need an `/etc/hosts` entry. The token in
this file is a static cluster-admin token, and it does not expire. Protect the
file, and do not commit it.

### A kubeconfig for the Gardener API

Section 8.1 needs this one. It is in the secret `garden/gardener`:

```bash
kubectl get secret -n garden gardener -o jsonpath='{.data.kubeconfig}' \
  | base64 -d > garden.kubeconfig
```

This token rotates. When the file reports 401, read the secret again.

The Gardener API is behind an Istio gateway that routes on the host name, so
`tls-server-name` is not sufficient for this one. The gateway answers `421
Misdirected Request` when the `Host` header holds an address. Put the name in
`/etc/hosts`, or use `curl --resolve`.

---

## 8. Prepare the cluster

Run the two workstation scripts. Both are safe to run again.

```bash
cd docs/gardener/scripts
./8-preflight.sh                 # reports, changes nothing
./8-prepare.sh --dry-run         # shows each change
./8-prepare.sh                   # makes the changes
```

`8-preflight.sh` reports one line for each check, and it exits 1 if a check
fails. The sections below explain what each step corrects, and why.

### 8.1 Raise the pod limit

The platform does not fit in the 28 free pod slots. Raise `maxPods` to 250.

This takes two steps on a self-hosted shoot, and the second step is easy to
miss. Give `8-prepare.sh` the Gardener API kubeconfig, and it does both:

```bash
GARDEN_KUBECONFIG=garden.kubeconfig ./8-prepare.sh
```

**Step one — change the `Shoot`.** `maxPods` is in the kubelet configuration,
which `gardener-node-agent` reconciles, so a change to the file alone does not
stay. Each worker pool can hold its own value, and the pool value wins. Find
the pool of your node first:

```bash
kubectl get node <node> -o jsonpath='{.metadata.labels.worker\.gardener\.cloud/pool}'
```

Then patch that pool:

```bash
kubectl --kubeconfig garden.kubeconfig patch shoot <name> -n garden --type=json -p '[
  {"op":"test","path":"/spec/provider/workers/0/name","value":"<pool>"},
  {"op":"add","path":"/spec/provider/workers/0/kubernetes","value":{"kubelet":{"maxPods":250}}}
]'
```

Gardener now writes a new `OperatingSystemConfig`, in a new secret, with a new
name. The `Shoot` reports `Succeeded`.

**Step two — point the node agent at the new secret.** The node does not
change yet. A usual Gardener cluster replaces the machine when the
`OperatingSystemConfig` changes, and the new machine learns the new secret
name when it starts. A self-hosted shoot has no machine controller, so no
machine is replaced, and the node agent keeps the old name. The old secret is
deleted, and Gardener's node authorizer refuses the read:

```
secrets "gardener-node-agent-<pool>-<old>" is forbidden:
gardener-node-agent can only access secrets [...] in "kube-system" namespace
```

The name is in two places. Correct both, then restart the agent:

```bash
NEW=$(kubectl get secret -n kube-system -o name \
      | grep -o "gardener-node-agent-<pool>-[a-f0-9]*")

kubectl label node <node> \
  worker.gardener.cloud/gardener-node-agent-secret-name="$NEW" --overwrite

sudo sed -i "s|secretName: gardener-node-agent-<pool>-.*|secretName: $NEW|" \
  /var/lib/gardener-node-agent/config-v*.yaml

sudo systemctl restart gardener-node-agent
```

The agent then writes the kubelet configuration and restarts the kubelet. The
node does not drain, and the pods continue to run, but the static pods of the
control plane restart. Do this before the installation, not during it.

Confirm the result:

```bash
kubectl get node <node> -o jsonpath='{.status.allocatable.pods}'
```

Every later kubelet change needs step two again.

### 8.2 Check the load balancer, and change nothing

Gardener installs MetalLB with one `IPAddressPool`. On the test cluster the
pool holds `10.20.154.250-10.20.154.252`, and the Gardener API uses `.250`.

The pool has `autoAssign: true` and no `serviceAllocation`, so **any**
`LoadBalancer` service in **any** namespace gets an address from it. Envoy
Gateway needs no new pool and no new address range.

Confirm this on your cluster before you install:

```bash
kubectl get ipaddresspool -n metallb-system -o yaml | grep -A3 -E 'addresses|serviceAllocation'
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

If the pool holds a `serviceAllocation` block, or if no address is free, add a
second pool. Do not change the pool that Gardener made. Find free addresses
first, because an address that answers an ARP request is in use:

```bash
arping -c 3 -I <interface> <address>
```

MetalLB gives the next free address, and that address can change if you
reinstall. Ask for a fixed address when a DNS record points at it:

```yaml
metadata:
  annotations:
    metallb.io/loadBalancerIPs: 10.20.154.251
```

### 8.3 Keep the storage class

The platform needs a storage class with the name `default`. Gardener supplies
one, with the `rancher.io/local-path` provisioner. Do not replace it.

`local-path` gives `ReadWriteOnce` volumes only, and several charts ask for
`ReadWriteMany`. You do not need to correct this by hand: the `default-cpu`
profile holds the package `kyverno-policies-storage-local-path`, which changes
those requests to `ReadWriteOnce`.

### 8.4 The AMD device plugin, for the GPU profile only

`demo-cpu` does not install the AMD GPU Operator, so a device plugin that
somebody installed by hand does no damage. Leave it.

The `demo` profile does install the operator, and the operator starts its own
`rocm/k8s-device-plugin` from a `DeviceConfig`. Two device plugins on one node
compete for the same socket, and the GPU count then changes between 0 and 1.
Remove the manual one before you install `demo`:

```bash
kubectl delete daemonset amdgpu-device-plugin-daemonset -n kube-system --ignore-not-found
```

`8-prepare.sh` removes it only with `--gpu`.

### 8.5 Protect the Gardener namespaces

`8-prepare.sh` adds the label `gardener.cloud/protected=true` to the namespaces
in section 5. The label changes no behaviour. It is a marker, so that a person
who reads `kubectl get ns` sees which namespaces belong to Gardener.

---

## 9. Choose a domain

The platform serves its routes under one domain, and Keycloak and Dex write
that domain into their configuration. A later change needs a reinstallation,
so choose the domain now.

### For a test: nip.io

`nip.io` resolves `<address>.nip.io` to `<address>`, so it needs no DNS
server. The test cluster resolves it from the node and from the workstation:

```bash
getent hosts 10.20.154.251.nip.io
```

Use the address that MetalLB gives to Envoy Gateway, and pin that address with
the annotation in section 8.2.

The `selfsigned-tls` package then issues the certificate, and the browser
reports a warning.

### For a real name

A real name gives a wildcard certificate as well, and the browser reports no
warning. The test cluster uses `garden-shoot.example.com`.

Create the apex and the wildcard A record together, and point both at the
address that Envoy Gateway takes. A private address is correct here: the
name resolves to `10.20.154.251`, which only the internal network reaches.
Let's Encrypt validates with DNS-01, so it does not connect to the address.

The profile still installs `selfsigned-tls`, because the package list is
inside the Spur binary. Replace the certificate after the installation. The
Gateway reads the Secret `cluster-tls` in `envoy-gateway-system`, and
cert-manager owns that Secret, so remove the `Certificate` first:

```bash
kubectl delete certificate selfsigned-cert -n envoy-gateway-system

kubectl create secret tls cluster-tls -n envoy-gateway-system \
  --cert=fullchain.pem --key=privkey.pem \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment -n envoy-gateway-system \
  -l app.kubernetes.io/name=envoy
```

`fullchain.pem` holds the leaf and both intermediates. Confirm the result
without `-k`, because `-k` hides the fault you are looking for:

```bash
curl -s -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' \
  https://aiwbui.<domain>/
```

`verify=0` means the browser trusts it too.

A later `install` of the same profile makes the `Certificate` again and takes
the Secret back. Do these three commands again after each install.

---

## 10. Install the platform

Build the Spur binary once. This needs `go`, `helm` and the network:

```bash
cd spur
just all
```

Then install the demo. `--no-gpu` adds `-cpu` to the profile name, so this
installs `demo-cpu`:

```bash
export KUBECONFIG=/path/to/cluster.kubeconfig
cd spur
just install demo --no-gpu --var domain=10.20.154.251.nip.io
```

The pool of section 8.2 gives the gateway an address, so `gatewayServiceType`
keeps its default of `LoadBalancer`, and you do not set `gatewayExternalIP`.

Spur prints the UI address, the login name and the password command when it
finishes. The profile holds 17 packages, and Spur installs them in order, so
a failure stops at one package and names it. Run the same command again after
you correct the cause; an install is idempotent.

Give Spur a Docker Hub credential to lift the pull limit of section 12:

```bash
just install demo --no-gpu --var domain=<domain> \
  --pull-secret ~/.docker/config.json
```

Remove `--no-gpu` to use the GPU. Do section 8.4 first.

Do not use cluster-bloom. cluster-bloom installs RKE2, a storage provisioner,
MetalLB and node labels. Gardener already supplies these, and
`gardener-node-agent` reconciles the files that cluster-bloom writes.

Do not install a second ingress controller. The platform installs Envoy
Gateway. The Istio gateway in `istio-system` serves the Gardener API only, and
the two do not conflict, because they listen on different addresses.

---

## 11. Verify

```bash
kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"'
kubectl get svc -A --field-selector spec.type=LoadBalancer
```

Then run the Spur smoke tests:

```bash
cd spur
just smoke-demo      # the core serves a model
just smoke-ui        # login, API, deploy and chat
```

Check that the Gardener side is still correct:

```bash
kubectl --kubeconfig garden.kubeconfig get shoot -n garden
```

The `Shoot` must stay `Succeeded`. Two conditions are `False` on a self-hosted
shoot, and this is normal:

- `ControlPlaneHealthy` — etcd runs as static pods, so the StatefulSet that
  etcd-druid owns has 0 replicas, and druid never writes `status.ready`.
- `ObservabilityComponentsHealthy` — a self-hosted shoot has no shoot
  observability stack, so `kube-state-metrics` is absent.

---

## 12. Limits

- **One node.** Each chart runs one replica. A node restart stops the
  platform.
- **CPU inference.** `demo-cpu` answers slowly, and a large model does not
  fit. Use `demo` for real work.
- **One GPU**, with the `demo` profile. One model serves at a time.
- **Local storage.** `local-path` volumes are on the node. They do not move,
  and a node loss is a data loss.
- **A new Kubernetes version.** The test used 1.35.4. The platform is tested
  on older versions, so a chart can fail on a removed API.
- **Docker Hub limits.** Anonymous pulls are limited to 100 each hour, for
  each source address. The address is shared, because the node is behind NAT.
  A large installation can stop with `429 toomanyrequests`. Wait one hour, and
  run the installation again, or give the cluster a Docker Hub credential.

---

## 13. When something fails

| Symptom | Cause | Action |
|---|---|---|
| A pod stays `Pending`, and the event says `Insufficient memory` | The node advertises 100Gi, not the installed memory. | Lower the request, or examine the node capacity. |
| A pod stays `Pending`, and the event says `Too many pods` | `maxPods` is 110. | Section 8.1. |
| The node reports the old `maxPods` after a `Shoot` change | The node agent holds the old secret name. | Section 8.1, step two. |
| The node agent logs `secrets "gardener-node-agent-..." is forbidden` | The same cause. | Section 8.1, step two. |
| A `PersistentVolumeClaim` stays `Pending` | The Kyverno storage policy is absent. | Use a profile that extends `default-cpu`. Section 8.3. |
| A `Service` of type `LoadBalancer` has no address | The MetalLB pool is full. | Section 8.2. |
| The GPU count changes between 0 and 1 | Two device plugins, with the `demo` profile. | Section 8.4. |
| A pod in `kube-system` has no network | A Gardener network policy denies it. | Use a different namespace. |
| An image pull reports `429 toomanyrequests` | The Docker Hub limit. | Section 12. |
| The browser warns about the certificate after a reinstall | The profile made the self-signed `Certificate` again. | Section 9, the three commands. |
| `kubectl get aimcatalogentries` finds nothing | That kind does not exist. | The catalog is in `aimclustermodels`. |
| The Gardener kubeconfig reports 401 | The token rotated. | Read the secret `garden/gardener` again. Section 7. |
| The Gardener API answers `421 Misdirected Request` | The `Host` header holds an address. | Use the name. Section 7. |

---

## 14. Remove the platform

```bash
cd spur
spur-aims/spur-aims uninstall demo-cpu
```

Spur shows what goes, and it asks before it removes anything. Add `--yes` to
answer the question in a script, and `--keep-data` to keep the volumes and
the custom resource definitions.

Do not remove the storage class `default`, and do not remove MetalLB. Gardener
needs both. The `maxPods` value and the namespace labels do no damage, so you
can leave them.

---

## 15. The scripts

Everything executable that the chapters above reference lives in
[`scripts/`](scripts/), prefixed with the chapter that uses it. The four host
scripts were run for real on `gpu-node` on 2026-10-13; the two cluster
scripts were run on 2026-10-15.

| Script | Runs on | Used by | Purpose |
|---|---|---|---|
| [`0-gl-prep.sh`](scripts/0-gl-prep.sh) | the **old** OS (Ubuntu) | chapter 0, §6 | Offline preparation of the Garden Linux image after `dd`, before first boot |
| [`1-gl-gpu-prep.sh`](scripts/1-gl-gpu-prep.sh) | Garden Linux | chapter 1, §2–3 | Blacklist `amdgpu`, fetch and install firmware. Does not load the driver |
| [`1-gpu-test.sh`](scripts/1-gpu-test.sh) | Garden Linux | chapter 1, §4 | Load the driver under capture; survives a host crash |
| [`1-gpu-workload.py`](scripts/1-gpu-workload.py) | inside a ROCm container | chapter 1, §6 | PyTorch matmul benchmark — proves the GPU computes, not just enumerates |
| [`8-preflight.sh`](scripts/8-preflight.sh) | your workstation | chapter 8 | Report whether the cluster can take the platform. Changes nothing, exits 1 on a failed check |
| [`8-prepare.sh`](scripts/8-prepare.sh) | your workstation | chapter 8 | Make the changes in chapter 8. Safe to run again |

### Order of use

```
chapter 0    on the old OS, target disk unmounted
             dd image  →  0-gl-prep.sh  →  reboot into Garden Linux

chapter 1    on Garden Linux
             1-gl-gpu-prep.sh  →  reboot  →  1-gpu-test.sh  →  1-gpu-workload.py

chapters     build the cluster
3 and 4      gardenadm init  →  gardenadm connect

chapter 8    from your workstation, against the cluster
             8-preflight.sh  →  8-prepare.sh --dry-run  →  8-prepare.sh  →  install
```

`1-gl-gpu-prep.sh` and `1-gpu-test.sh` are deliberately separate. The first makes
the host safe to crash; the second is the only thing that loads the driver.
Never merge them.

### Copying the host scripts over

```bash
scp -F /dev/null scripts/1-gpu-test.sh scripts/1-gpu-workload.py \
    root@10.20.154.203:/root/
ssh -F /dev/null root@10.20.154.203 'chmod +x /root/1-gpu-test.sh'
```

### Before running anything

Each host script has a config block at the top. **Check it.** `0-gl-prep.sh` in
particular hardcodes a target disk, an SSH public key, a MAC address and a
static IP; running it unmodified against a different host will either fail or
strand the machine with no console.

The two cluster scripts take no such block. `8-preflight.sh` reads `PROFILE`
from the environment, which defaults to `demo-cpu`; set `PROFILE=demo` to
check the GPU profile instead. `8-prepare.sh` takes `--dry-run`, `--gpu`, and
`GARDEN_KUBECONFIG` for the pod-limit step in section 8.1.

### Safety notes

- `1-gpu-test.sh` **refuses to run** unless
  `/usr/lib/modprobe.d/blacklist-amdgpu.conf` exists. That guard is there so
  the driver can never be loaded on a host that would then autoload it on
  every subsequent boot. Don't remove it.
- `1-gpu-test.sh` samples **forever**. Stop it with `pkill -f 1-gpu-test.sh`.
- Both Garden Linux scripts remount `/usr` read-write and put it back. If one
  aborts midway, check with `findmnt -no OPTIONS /usr` and remount `ro`.
- There is no `/dev/watchdog` on this host. A hang needs a BMC power cycle.

### Two corrections already applied

These scripts are **not** verbatim copies of what ran first time — two bugs
found during the real run are fixed here:

1. `0-gl-prep.sh` originally wrote `/etc/ssh/sshd_config.d/99-rescue.conf`. That
   does nothing: the image has `PermitRootLogin no` on line 2 and the `Include`
   on line 45, and OpenSSH keeps the first value it sees. It now edits
   `sshd_config` directly. The original cost a reboot cycle.
2. `1-gl-gpu-prep.sh` fetched the firmware over `http://`, which hung for eight
   minutes against a dead mirror. It now uses `https://`.
