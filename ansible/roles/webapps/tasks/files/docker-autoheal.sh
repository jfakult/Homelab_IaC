#!/bin/bash
# Restart containers labelled autoheal=true that are broken - Docker itself
# never restarts an unhealthy container. Main use: the Unraid NAS drops NFS
# file handles ("Stale file handle", errno 116) under containers reading from
# it (kiwix); a restart reopens everything. Run by docker-autoheal.timer (2m).
#
# A container counts as broken when either:
#   - Docker reports it unhealthy (its healthcheck failed), or
#   - its label autoheal.log_pattern (grep -E regex) matches its log output
#     since the previous run. For errors a healthcheck can't see - kiwix
#     serves some requests fine while others die on a stale handle.
set -uo pipefail

WINDOW=6m   # a bit more than the timer interval, so no log line is missed

for c in $(docker ps --filter label=autoheal=true --format '{{.Names}}'); do
    reason=""
    if [ "$(docker inspect "$c" --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')" = unhealthy ]; then
        reason="healthcheck unhealthy"
    fi

    pattern=$(docker inspect "$c" --format '{{index .Config.Labels "autoheal.log_pattern"}}')
    if [ -z "$reason" ] && [ -n "$pattern" ]; then
        # Only look at logs from the current run of the container, so lines
        # from before our own last restart don't trigger another one.
        since=$(date -u -d "-${WINDOW%m} minutes" +%s)
        started=$(date -u -d "$(docker inspect "$c" --format '{{.State.StartedAt}}')" +%s)
        [ "$started" -gt "$since" ] && since=$started
        hits=$(docker logs --since "$since" "$c" 2>&1 | grep -cE -- "$pattern")
        [ "$hits" -gt 0 ] && reason="$hits log line(s) matching '$pattern'"
    fi

    [ -n "$reason" ] || continue

    # If a bind source is unreadable on the host as well, the NAS itself is
    # down - a restart won't help, so leave it rather than restart-looping.
    # (-k: hard NFS mounts only die to SIGKILL)
    ok=1
    for src in $(docker inspect "$c" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} {{end}}{{end}}'); do
        if ! timeout -k 5 10 ls "$src" >/dev/null 2>&1; then
            echo "$c: $reason, but host path $src unreadable (NAS down?) - not restarting"
            ok=0
        fi
    done
    [ "$ok" = 1 ] || continue

    echo "$c: $reason - restarting"
    docker restart "$c"
done
