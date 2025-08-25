#!/usr/bin/env bash
set -euo pipefail

INVENTORY="${IAC:-$PWD}/ansible/inventory/hosts.ini"
KNOWNHOSTS="$HOME/.ssh/known_hosts"
TMP=$(mktemp)

# Collect hostnames
ansible all -i "$INVENTORY" --list-hosts | tail -n +2 > "$TMP.names"

# Collect ansible_host IPs
ansible-inventory -i "$INVENTORY" --list \
  | jq -r '._meta.hostvars | to_entries[] | .value.ansible_host? // empty' > "$TMP.ips"

# Merge + dedupe
sort -u "$TMP.names" "$TMP.ips" > "$TMP.targets"

# Backup and rebuild known_hosts
cp -f "$KNOWNHOSTS" "$KNOWNHOSTS.bak.$(date +%s)" 2>/dev/null || true
: > "$KNOWNHOSTS"

while read -r target; do
  [[ -z "$target" ]] && continue
  echo "[*] $target"
  ssh-keyscan -t ed25519 -H "$target" 2>/dev/null >> "$KNOWNHOSTS"
done < "$TMP.targets"

rm -f "$TMP."*
echo "[✓] Rebuilt $KNOWNHOSTS with names + IPs"
