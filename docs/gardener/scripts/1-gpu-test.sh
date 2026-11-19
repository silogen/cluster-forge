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
