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
# NOTE: sso.fakult.net is deliberately skipped here. It must resolve via real
# DNS to bastion (nginx), which holds the trusted Let's Encrypt cert and
# proxies to pocket-id. A direct /etc/hosts entry bypasses nginx and exposes
# pocket-id's self-signed cert to OIDC clients. The bare `sso` short name
# above is unaffected.
echo "! Generating FQDN hostnames"
ansible-inventory -J -i "$INVENTORY" --list \
  | jq -r '
      ._meta.hostvars
      | to_entries[]
      | select(.value.ansible_host != null and .key != "sso")
      | "\(.value.ansible_host)\t\(.key).fakult.net"
    ' | sort -n


echo "Paste this into your /etc/hosts (not including the ! printed lines)"