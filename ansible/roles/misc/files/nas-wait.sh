#!/bin/bash
# Boot-time gate: wait (bounded) for the NAS NFS mounts before docker starts,
# so containers don't bind-mount an empty mountpoint directory. Always exits 0:
# if the NAS is still down after NAS_WAIT_SECONDS, docker starts anyway (a
# hard dependency would take down every container on the VM) and
# nas-watchdog restarts the dependent containers once the NAS is back.
set -uo pipefail
. /etc/nas-resilience.conf

deadline=$(( $(date +%s) + NAS_WAIT_SECONDS ))
pending="$NAS_MOUNTS"
while [ -n "$pending" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    still=""
    for p in $pending; do
        # ls triggers an x-systemd.automount; findmnt confirms a real NFS mount
        if timeout -k 3 10 ls -f "$p" >/dev/null 2>&1 && findmnt -n -t nfs4 -M "$p" >/dev/null; then
            echo "nas-wait: $p ready"
        else
            still="$still $p"
        fi
    done
    pending="${still# }"
    [ -n "$pending" ] && sleep 5
done
[ -n "$pending" ] && echo "nas-wait: GAVE UP waiting for: $pending - starting docker anyway"
exit 0
