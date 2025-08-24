#!/usr/bin/env bash
set -euo pipefail

BASE_PKGS="qemu-guest-agent iproute2 net-tools iputils-ping traceroute dnsutils curl wget procps htop sysstat lsof ncdu nano less man-db"

usage() {
  cat <<EOF
goldenize.sh — make a golden image by installing baseline tools

USAGE:
  goldenize.sh -i SOURCE.img -o OUTPUT.img [-p "extra pkgs"] [-h]

OPTIONS:
  -i  Source cloud image (e.g., ubuntu-24.04-server-cloudimg-amd64.img)
  -o  Output image (will be created; source left untouched)
  -p  Extra packages (space-separated) in addition to baseline
  -h  Show this help

Notes:
  • Requires: virt-customize (libguestfs-tools).
EOF
}

SRC=""; DST=""; EXTRA_PKGS=""
while getopts ":i:o:p:h" opt; do
  case "$opt" in
    i) SRC="$OPTARG" ;;
    o) DST="$OPTARG" ;;
    p) EXTRA_PKGS="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -z "$SRC" || -z "$DST" ]] && { usage; exit 2; }
command -v virt-customize >/dev/null || { echo "virt-customize not found (install libguestfs-tools)"; exit 1; }
[[ -f "$SRC" ]] || { echo "Source not found: $SRC"; exit 1; }
[[ -f "$DST" ]] && { echo "Refusing to overwrite existing $DST"; exit 1; }

# Copy source to destination (reflink if supported; falls back to normal copy)
cp --reflink=auto "$SRC" "$DST" 2>/dev/null || cp "$SRC" "$DST"

# Build final package list (comma-separated for virt-customize)
ALL_PKGS="$(echo "$BASE_PKGS $EXTRA_PKGS" | xargs)"
PKGS_CSV="${ALL_PKGS// /,}"

echo "[*] Installing packages into $DST:"
echo "    $ALL_PKGS"
virt-customize -a "$DST" --install "$PKGS_CSV"

echo "[✓] Golden image ready: $DST"
