# Adding a new `<name>.fakult.net` subdomain

Every public-facing subdomain (`sso.fakult.net`, `chat.fakult.net`, and
whatever comes next) is driven from **one list**:
`inventory/group_vars/all/main.yml` → `subdomains`.

```yaml
subdomains:
  - name: sso
    upstream_host: "{{ hostvars['sso'].ansible_host }}"
    upstream_port: 1411
  - name: chat
    upstream_host: "{{ hostvars['compute'].ansible_host }}"
    upstream_port: 3000
```

That one entry is the only thing you should ever need to hand-write. It
drives three things automatically:

| Consumer | What it does |
|---|---|
| `roles/dns/templates/static-hosts.conf.j2` | Internal LAN resolution (`<name>.fakult.net` → `bastion`, 192.168.1.201) |
| `roles/bastion/tasks/render_subdomains.yml` | Renders `/etc/nginx/conf.d/subdomains/<name>.fakult.net.conf` (a full nginx vhost: HTTP→HTTPS redirect, `/.well-known/acme-challenge/` handling, and the proxy to `upstream_host:upstream_port`) |
| `roles/bastion/tasks/main.yml`'s certbot loop | Issues `<name>.fakult.net` its own Let's Encrypt cert (`certbot certonly --cert-name <name>.fakult.net`) |

It also gets you a `fakult.net/<name>` → `https://<name>.fakult.net` redirect
for free (`roles/bastion/templates/subdomain-redirects.conf.j2`), so people
who type the path out of habit still land somewhere.

## Why a subdomain, not a path prefix

The default instinct is `fakult.net/<name>` (matches `/journal`, `/jellyfin/`,
`/wikipedia`). That only works for apps that are actually built to be
reverse-proxied under a subpath. Some aren't - Open WebUI's maintainers have
explicitly rejected subpath support (their frontend hardcodes asset/API
requests to `/`, and multiple community nginx workarounds have failed - see
[open-webui/open-webui#12002](https://github.com/open-webui/open-webui/pull/12002)
and [#6650](https://github.com/open-webui/open-webui/discussions/6650)).
Rather than discover this per-app, every new *standalone web app* (not a
path glued into an existing app like Blinko's `/journal`) gets a subdomain
by default. It's zero extra cost (one list entry) and always works.

## Steps to add one

1. Add the entry to `subdomains` in `inventory/group_vars/all/main.yml`.
2. **Public DNS** (the one step Ansible can't do): add a `<name>.fakult.net`
   A/CNAME record at whatever DNS provider hosts `fakult.net` publicly,
   pointing at the same public IP `sso.fakult.net`/`chat.fakult.net`
   already use. Let's Encrypt's HTTP-01 validator hits this over the real
   internet - the internal dnsmasq entry (step below) does not help it.
3. Run, in order (a normal full `site.yml` run does this automatically in
   the right order - split out here just so you know what's happening):
   ```
   ansible-playbook -i inventory/hosts.ini site.yml --limit dns -J
   ansible-playbook -i inventory/hosts.ini site.yml --tags nginx,certbot --limit bastion -J
   ```
   The bastion play renders the vhost **twice**: once before the cert
   exists (HTTP-only, so certbot's webroot challenge has something to hit),
   then again after certbot issues it (activates the HTTPS block). This is
   why `--tags nginx,certbot` together in one run works from a cold start -
   splitting them across two separate invocations also works, just requires
   running the `nginx`-tagged tasks a second time after `certbot`.
4. If the backend needs SSO, create its Pocket-ID OAuth client by hand at
   `https://sso.fakult.net` (no API/CLI for this) - redirect URI is
   `https://<name>.fakult.net/<app's OAuth callback path>`.

## Files involved (for when something breaks)

- `inventory/group_vars/all/main.yml` - the `subdomains` list itself. Lives
  in `all/` (not `external.yml`) because both `dns` (`[infra]` group) and
  `bastion` (`[external]` group) need to see it, and `group_vars` files
  don't cross inventory groups.
- `roles/bastion/templates/nginx/conf.d/subdomain.conf.j2` - the generic
  per-subdomain vhost template. Lives alongside the other `conf.d/*.conf.j2`
  files for discoverability, but is excluded by name from the blanket
  `with_filetree` push in `roles/bastion/tasks/main.yml` (it needs per-item
  loop vars that push doesn't have) - `render_subdomains.yml` renders it
  separately, once per `subdomains` entry.
- `roles/bastion/templates/nginx/snippets/subdomain-redirects.conf.j2` - the
  `fakult.net/<name>` redirect snippet template. Same exclusion as above.
- `roles/bastion/tasks/render_subdomains.yml` - stats each cert, renders
  both templates. Imported twice from `roles/bastion/tasks/main.yml`.
- `roles/bastion/tasks/main.yml` - the certbot loop, and the two
  `render_subdomains.yml` import points (bootstrap pass, activation pass).
- `roles/dns/templates/static-hosts.conf.j2` - loops `subdomains` for
  internal resolution.

Don't hand-edit anything under `/etc/nginx/conf.d/subdomains/` on the host -
it's fully regenerated every run.
