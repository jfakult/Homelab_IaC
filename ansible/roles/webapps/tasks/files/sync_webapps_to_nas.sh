#!/bin/bash
# Mirror the live webapps (/srv/webapps, local disk) to the NAS copy
# (/srv/www/_webapps = Server_WebappsCache share). One-way, local wins:
# changed files on the NAS side are overwritten, nothing is ever deleted there.
# Run by webapps-nas-sync.timer (every 3h). See /srv/www/_webapps/context.md.
set -euo pipefail

SRC=/srv/webapps/
DEST=/srv/www/_webapps/

# /srv/www is an NFS automount. Touching it triggers the mount; then make sure
# it really is the NAS and not the bare local mountpoint dir before writing.
if [ ! -d "$DEST" ] || ! findmnt -t nfs4 -M /srv/www >/dev/null; then
    echo "NAS share not mounted at /srv/www (or $DEST missing) - skipping sync" >&2
    exit 1
fi

# -a: recurse, keep mtimes/perms/symlinks (mtime+size decides what is re-copied,
#     so a normal run only stats files and copies what changed)
# --chown: match the NAS share's existing ownership (ubuntu:users)
# no --delete: files that only exist on the NAS (e.g. context.md) are kept
rsync -a --chown=1000:100 --exclude=/context.md "$SRC" "$DEST"

echo "Synced $SRC -> $DEST"
