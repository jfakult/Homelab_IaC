#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
update_cloud_init.sh - Regenerate a VM's cloud-init seed and optionally re-run cloud-init inside the guest.

USAGE:
  update_cloud_init.sh -v <VMID> [-g] [-d] [-h]

OPTIONS:
  -v <VMID>   VM ID to update (required)
  -g          Ask guest (via qemu-guest-agent) to: cloud-init clean --logs && reboot
  -d          Dump rendered cloud-init (user + network) after update
  -h          Help

NOTES:
  * Edit your snippet (e.g. /var/lib/vz/snippets/cloud-init.yaml) BEFORE running this.
  * -g requires the QEMU Guest Agent to be enabled and running in the VM.
EOF
}

VMID=""
DO_GUEST=false
DO_DUMP=false

while getopts ":v:gdh" opt; do
  case "$opt" in
    v) VMID="$OPTARG" ;;
    g) DO_GUEST=true ;;
    d) DO_DUMP=true ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -z "$VMID" ]] && { usage; exit 2; }

echo "[*] Regenerating cloud-init seed for VM $VMID..."
qm cloudinit update "$VMID"

if $DO_DUMP; then
  echo "[*] Rendered user-data:"
  qm cloudinit dump "$VMID" user || true
  echo
  echo "[*] Rendered network-data:"
  qm cloudinit dump "$VMID" network || true
fi

if $DO_GUEST; then
  echo "[*] Checking guest agent..."
  if qm guest ping "$VMID" >/dev/null 2>&1; then
    echo "[*] Asking guest to clean cloud-init state..."
    qm guest exec "$VMID" -- cloud-init clean --logs || true
    echo "[*] Rebooting guest..."
    qm guest exec "$VMID" -- reboot || qm reboot "$VMID"
  else
    echo "[!] Guest agent not responding; you can reboot the VM manually or run inside the VM:"
    echo "    sudo cloud-init clean --logs && sudo reboot"
  fi
fi

echo "[✓] Done."
