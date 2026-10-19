#!/bin/bash
# NAS NFS watchdog. Run by nas-watchdog.timer (1m). For each path in
# NAS_MOUNTS (/etc/nas-resilience.conf):
#   1. Is it a readable NFS mount? If not and the NAS answers on 2049,
#      unmount + remount it. If the NAS is down, do nothing (hard mounts
#      resume by themselves; restarting containers would just loop).
#   2. For every running container that bind-mounts something under that
#      path, compare the container's view with the host's (st_dev:inode via
#      /proc/<pid>/root). A mismatch means the container is holding a stale
#      mount or an empty directory that was there before the NAS mounted.
#      Restart it (at most once per RESTART_COOLDOWN per container).
#   3. A container that FAILED TO START (e.g. at boot, while the NAS mount was
#      still missing: "error mounting /srv/... no such device") stays down even
#      with restart: unless-stopped. Once the path is healthy again, start every
#      such container (State.Error set, restart policy not "no") that binds
#      something under that path. Containers stopped by hand have no State.Error
#      and are left alone.
#
#   --check   report only: no remount, no restart. Exit status = number of
#             problems. Used by nas_crash_drill.sh.
set -uo pipefail
. /etc/nas-resilience.conf

MODE=run; [ "${1:-}" = "--check" ] && MODE=check
STATE=/run/nas-watchdog
RESTART_COOLDOWN=600
mkdir -p "$STATE"
problems=0

say()  { echo "$*"; }
bad()  { echo "PROBLEM: $*"; problems=$((problems+1)); }
t()    { timeout -k 5 "$@"; }

path_ok() { t 10 ls -f "$1" >/dev/null 2>&1 && findmnt -n -t nfs4 -M "$1" >/dev/null 2>&1; }
nas_up()  { t 5 bash -c "exec 3<>/dev/tcp/$NAS_IP/2049" 2>/dev/null; }

for p in $NAS_MOUNTS; do
    if path_ok "$p"; then
        say "ok: $p mounted and readable"
        healthy=1
    else
        bad "$p not a readable NFS mount"
        healthy=0
        if [ "$MODE" = run ]; then
            if nas_up; then
                say "$p: NAS reachable, remounting"
                t 30 umount -f "$p" >/dev/null 2>&1 || t 30 umount -l "$p" >/dev/null 2>&1
                t 60 mount "$p" >/dev/null 2>&1
                if path_ok "$p"; then say "$p: recovered"; healthy=1; else say "$p: remount FAILED"; fi
            else
                say "$p: NAS not answering on $NAS_IP:2049 - waiting"
            fi
        else
            nas_up || say "  (NAS $NAS_IP:2049 not answering)"
        fi
    fi

    command -v docker >/dev/null || continue
    for c in $(docker ps -a --filter status=created --filter status=exited --format '{{.Names}}'); do
        [ -n "$(docker inspect -f '{{.State.Error}}' "$c")" ] || continue
        pol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c")
        [ -n "$pol" ] && [ "$pol" != no ] || continue
        docker inspect -f '{{json .HostConfig.Binds}}' "$c" | grep -q "\"$p[/\":]" || continue
        bad "$c failed to start and is down (binds $p)"
        [ "$MODE" = run ] && [ "$healthy" = 1 ] || continue
        last=$(cat "$STATE/start.$c" 2>/dev/null || echo 0)
        if [ $(( $(date +%s) - last )) -lt "$RESTART_COOLDOWN" ]; then
            say "$c: started recently, not again yet"
            continue
        fi
        date +%s > "$STATE/start.$c"
        say "$c: starting (it failed to start earlier)"
        docker start "$c" >/dev/null
    done
    for c in $(docker ps --format '{{.Names}}'); do
        pid=$(docker inspect -f '{{.State.Pid}}' "$c")
        while read -r src dst; do
            [ -n "$src" ] || continue
            case "$src" in "$p"|"$p"/*) ;; *) continue ;; esac
            hv=$(t 10 stat -c '%d:%i' "$src" 2>/dev/null)
            cv=$(t 10 stat -c '%d:%i' "/proc/$pid/root$dst" 2>/dev/null)
            if [ -n "$hv" ] && [ "$hv" = "$cv" ]; then
                say "ok: $c $dst -> $src"
                continue
            fi
            bad "$c: $dst does not match host $src (host=${hv:-unreadable} container=${cv:-unreadable})"
            [ "$MODE" = run ] && [ "$healthy" = 1 ] && [ -n "$hv" ] || continue
            last=$(cat "$STATE/restart.$c" 2>/dev/null || echo 0)
            if [ $(( $(date +%s) - last )) -lt "$RESTART_COOLDOWN" ]; then
                say "$c: restarted recently, not again yet"
                continue
            fi
            date +%s > "$STATE/restart.$c"
            say "$c: restarting to pick up fresh $src"
            docker restart "$c" >/dev/null
            break
        done < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} {{.Destination}}{{println}}{{end}}{{end}}' "$c")
    done
done

date -u +%FT%TZ > "$STATE/last-run"
exit "$problems"
