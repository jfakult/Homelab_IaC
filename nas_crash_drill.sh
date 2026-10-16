#!/bin/bash
# NAS crash drill - run on butlah after a NAS reboot/crash (or any time).
# Read-only by default: checks every NAS-dependent VM and the services using
# the NAS. Exit status = number of problems found.
#   --write   also touch+rm a canary file on the rw shares (as ubuntu)
#   --fix     run nas-watchdog in remediation mode first (remounts/restarts)
set -uo pipefail

WRITE=0; FIX=0
for a in "$@"; do case $a in --write) WRITE=1;; --fix) FIX=1;; *) echo "usage: $0 [--write] [--fix]"; exit 2;; esac; done

problems=0
RED=$'\e[31m'; GRN=$'\e[32m'; OFF=$'\e[0m'
ok()   { echo "  ${GRN}ok${OFF}   $*"; }
fail() { echo "  ${RED}FAIL${OFF} $*"; problems=$((problems+1)); }

# vm <id> <cmd>: run in guest, print stdout, return the guest's exit code
vm() {
    local id=$1; shift
    local out
    out=$(qm guest exec "$id" --timeout 90 -- bash -c "$*" 2>&1) || { echo "guest agent error: $out"; return 255; }
    python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
sys.stdout.write(d.get("out-data", "") + d.get("err-data", ""))
sys.exit(d.get("exitcode", 0))' <<<"$out"
}

echo "== NAS (192.168.1.199)"
ping -c1 -W2 192.168.1.199 >/dev/null 2>&1 && ok "ping" || fail "NAS does not answer ping"
timeout 5 bash -c 'exec 3<>/dev/tcp/192.168.1.199/2049' 2>/dev/null && ok "NFS port 2049 open" || fail "NFS port 2049 closed"

# id  name     paths-to-read
HOSTS="201:bastion 205:webapps 206:media"
for h in $HOSTS; do
    id=${h%%:*}; name=${h##*:}
    echo "== $name ($id)"
    if ! vm "$id" true >/dev/null; then fail "guest agent not answering"; continue; fi

    if [ $FIX = 1 ]; then
        echo "  running nas-watchdog (fix mode):"; vm "$id" '/usr/local/sbin/nas-watchdog.sh' | sed 's/^/    /'
    fi

    # Watchdog report: per-mount readability + container-vs-host mount match
    rep=$(vm "$id" '/usr/local/sbin/nas-watchdog.sh --check'); rc=$?
    if [ $rc = 255 ] || [ -z "$rep" ]; then fail "nas-watchdog.sh missing/not runnable (is the nas tag deployed?)"; else
        echo "$rep" | while IFS= read -r l; do case $l in PROBLEM*) echo "  ${RED}FAIL${OFF} ${l#PROBLEM: }";; ok:*) echo "  ${GRN}ok${OFF}   ${l#ok: }";; *) echo "       $l";; esac; done
        problems=$((problems + rc))
    fi

    out=$(vm "$id" 'systemctl is-active nas-watchdog.timer docker-autoheal.timer | tr "\n" " "; systemctl is-enabled nas-wait.service 2>&1 | tr "\n" " "; [ -f /etc/systemd/system/docker.service.d/10-nas-order.conf ] && echo order-dropin')
    case $out in "active active enabled order-dropin"*) ok "watchdog+autoheal timers active, nas-wait enabled, docker ordered after it";; *) fail "safeguards incomplete: $out";; esac

    out=$(vm "$id" 'dmesg --since "-10min" 2>/dev/null | grep -iE "stale|state recovery failed|check lease failed" | tail -3')
    [ -z "$out" ] && ok "no NFS errors in kernel log (10 min)" || fail "recent NFS kernel errors: $out"

    out=$(vm "$id" 'docker ps -a --format "{{.Names}} {{.Status}}" | grep -vE "Up .*(healthy|[a-z])\)?$|Up [0-9]" ; docker ps --filter health=unhealthy --format "unhealthy: {{.Names}}"')
    [ -z "$out" ] && ok "all containers up, none unhealthy" || fail "containers: $out"

    out=$(vm "$id" 'systemctl --failed --no-legend | grep -vE "cloud-(final|init|config)|sysstat" | head')
    [ -z "$out" ] && ok "no unexpected failed units" || echo "       failed units (info): $out"
done

echo "== service-level reads"
# kiwix: search forces reads deep into every zim
for b in wikipedia_en_top1m_maxi_2025-09 wikipedia_en_top_maxi_2025-08; do
    code=$(vm 205 "curl -sL -o /dev/null -w '%{http_code}' --max-time 60 'localhost:3090/wikipedia/search?content=$b&pattern=linux+kernel'")
    [ "$code" = 200 ] && ok "kiwix search in $b" || fail "kiwix search in $b -> $code"
done
n=$(vm 205 'docker logs kiwix --since 10m 2>&1 | grep -c "Stale file handle"; true')
[ "$n" = 0 ] && ok "kiwix log: no stale handles" || fail "kiwix log has 'Stale file handle' ($n lines)"
# jellyfin: read bytes from a real media file, as the container sees it
out=$(vm 206 'f=$(find /srv/media/Movies -type f -size +2M 2>/dev/null | head -1); docker exec jellyfin head -c 1048576 "/media/${f#/srv/media/}" | wc -c' 2>&1 | tail -1)
[ "$out" = 1048576 ] && ok "jellyfin container reads a media file" || fail "jellyfin media read: $out"
# bastion: nginx serves content from the NAS docroot
code=$(vm 201 "curl -sk -o /dev/null -w '%{http_code}' -H 'Host: fakult.net' https://localhost/50x.html")
[ "$code" = 200 ] && ok "rp-nginx serves NAS docroot (50x.html)" || fail "rp-nginx 50x.html -> $code"
code=$(vm 201 "curl -sk -o /dev/null -w '%{http_code}' https://localhost/wikipedia/")
case $code in 2*|3*) ok "bastion -> kiwix proxy ($code)";; *) fail "bastion -> kiwix proxy -> $code";; esac

if [ $WRITE = 1 ]; then
    echo "== write canaries (rw mounts, as ubuntu)"
    for t in "205 /srv/www" "205 /srv/nas" "206 /srv/media"; do
        set -- $t
        vm "$1" "sudo -u ubuntu sh -c 'f=$2/.drill-canary.\$\$; echo x > \$f && rm \$f'" >/dev/null && ok "write $2 on $1" || fail "write $2 on $1"
    done
fi

echo
[ $problems = 0 ] && echo "${GRN}DRILL PASSED${OFF}" || echo "${RED}DRILL: $problems problem(s)${OFF}"
exit $problems
