#!/usr/bin/env bash

# gen_etc_hosts.sh — print lines you could add to /etc/hosts from Ansible inventory

INVENTORY="$IAC/ansible/inventory/hosts.ini"

echo "! Generating short hostnames"
ansible-inventory -J -i "$INVENTORY" --list \
  | jq -r '
      ._meta.hostvars
      | to_entries[]
      | select(.value.ansible_host != null)
      | "\(.value.ansible_host)\t\(.key)"
    ' | sort -n

# Also add entries for [name].fakult.net
echo "! Generating FQDN hostnames"
ansible-inventory -J -i "$INVENTORY" --list \
  | jq -r '
      ._meta.hostvars
      | to_entries[]
      | select(.value.ansible_host != null)
      | "\(.value.ansible_host)\t\(.key).fakult.net"
    ' | sort -n


echo "Paste this into your /etc/hosts (not including the ! printed lines)"