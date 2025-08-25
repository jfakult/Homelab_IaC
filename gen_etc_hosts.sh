#!/usr/bin/env bash

# gen_etc_hosts.sh — print lines you could add to /etc/hosts from Ansible inventory

INVENTORY="$IAC/ansible/inventory/hosts.ini"

ansible-inventory -i "$INVENTORY" --list \
  | jq -r '
      ._meta.hostvars
      | to_entries[]
      | select(.value.ansible_host != null)
      | "\(.value.ansible_host)\t\(.key)"
    '
