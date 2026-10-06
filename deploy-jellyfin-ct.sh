#!/usr/bin/env bash
# deploy-jellyfin-ct.sh — Jellyfin on hlh-docker (LXC 109) — provisioning (1st of 2 scripts)
#
# Pure bash, no ansible/opentofu. One for provision (this file), one for
# configuration (configure-jellyfin-ct.sh). Run from the workstation; operates
# prox01 (192.168.1.10) and LXC 109 (192.168.1.9) over SSH. Root+key auth
# required.
#
# Steps:
#   1) Preflight (re-run aware)                                   [workstation]
#   2) Vault rename media -> vault, library -> jellyfin/          [prox01]
#   3) Import guard (one-time import done 2026-10-05)             [prox01]
#   4) LXC mount mp1: vault -> /vault                             [prox01]
#   5) Push + run configure-jellyfin-ct.sh on 109                 [109]
#      (stack files, bench_lan pool, image, up, port 80, verify)
#   6) SMB [vault] share (+ retire legacy [media])                [prox01]
#   7) Verify (http://192.168.1.16/health)                        [workstation]
#
# Run from prox01 (preferred — no SSH keys needed at all: host steps run
# locally, 109 via pct exec/pct push) OR from the workstation (root+key SSH
# to prox01 + 109). Idempotent — safe to re-run (every step checks state
# before acting; on the live system a re-run is a no-op).
set -euo pipefail

HOST=192.168.1.10        # prox01 (Proxmox)
LXC_IP=192.168.1.9       # hlh-docker (LXC 109)
CT_ID=109
JELLYFIN_IP=192.168.1.16
VAULT=RaidZ1-6TB/vault
MEDIA=RaidZ1-6TB/media
MOUNT="/mnt/RaidZ1-6TB/vault"
SRC=/mnt/p3ntfs/Users/price/Videos

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGURE_SCRIPT="${SCRIPT_DIR}/configure-jellyfin-ct.sh"
[[ -f "$CONFIGURE_SCRIPT" ]] || { echo "ERROR: configure script not found: $CONFIGURE_SCRIPT" >&2; exit 1; }

h() { echo; echo "==> $*"; }

# Transport: on prox01 itself -> local exec + pct (zero keys); elsewhere -> SSH.
ON_HOST=false
if [[ " $(hostname -I 2>/dev/null || true) " == *" $HOST "* ]]; then
	ON_HOST=true
fi
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
hhost() {
	if $ON_HOST; then
		[[ "$1" == "bash" ]] && { shift; bash "$@"; return; }
		bash -c "$*"
	else
		ssh "${SSH_OPTS[@]}" root@"$HOST" "$@"
	fi
}
hlxc() {
	if $ON_HOST; then
		pct exec "${CT_ID}" -- bash -c "$*"
	else
		ssh "${SSH_OPTS[@]}" root@"$LXC_IP" "$*"
	fi
}
if $ON_HOST; then echo "running on prox01 — local exec + pct (no SSH)"; else echo "running remotely — SSH to prox01 + 109"; fi

# ---------------------------------------------------------------------------
h "1/7 Preflight"
hhost "true"
hlxc "true"
hhost "pct status ${CT_ID}" | grep -q running || { echo "ERROR: LXC ${CT_ID} not running" >&2; exit 1; }
echo "docker: $(hlxc 'docker info --format {{.ServerVersion}} 2>/dev/null')"
# NB: explicit "show" — this iproute2 build rejects implicit `ip neigh <addr>` (rc 255).
owner=$(hhost "ip -o neigh show ${JELLYFIN_IP} | head -n1" || true)
if [[ -n "$owner" ]]; then
	owner=$(hlxc "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' jellyfin 2>/dev/null" || true)
	[[ "$owner" == "$JELLYFIN_IP" ]] || { echo "ERROR: ${JELLYFIN_IP} is in use by something other than the jellyfin container" >&2; exit 1; }
	echo "${JELLYFIN_IP} already in use by the jellyfin container — re-run mode"
fi
hhost "zfs list -H ${VAULT}" 2>/dev/null || hhost "zfs list -H ${MEDIA}"

# ---------------------------------------------------------------------------
h "2/7 Vault rename (media -> vault, library -> jellyfin/)"
if hhost "zfs list -H ${VAULT}" >/dev/null 2>&1; then
	if hhost "test -d ${MOUNT}/jellyfin"; then
		echo "dataset already renamed — skipping"
	else
		echo "ERROR: ${VAULT} exists but ${MOUNT}/jellyfin missing — inspect manually" >&2
		exit 1
	fi
else
	hhost "zfs list -H ${MEDIA}" >/dev/null || { echo "ERROR: neither ${VAULT} nor ${MEDIA} dataset exists" >&2; exit 1; }
	# Restructure BEFORE the rename so the container always sees /vault/jellyfin.
	hhost "mkdir -p /mnt/RaidZ1-6TB/media/jellyfin"
	hhost "cd /mnt/RaidZ1-6TB/media && for f in *; do [[ \$f == jellyfin ]] || mv -- \"\$f\" jellyfin/; done"
	hhost "zfs rename ${MEDIA} ${VAULT}"
	echo "renamed: $(hhost "zfs list -H -o name,used ${VAULT}")"
fi
echo "library:"
hhost "ls ${MOUNT}/jellyfin"

# ---------------------------------------------------------------------------
h "3/7 Import guard (import done 2026-10-05; re-runs only if library empty)"
if hhost "test -n \"\$(ls -A ${MOUNT}/jellyfin 2>/dev/null)\""; then
	echo "library present — skipping"
else
	hhost "mountpoint -q /mnt/p3ntfs" || { echo "ERROR: library empty AND ${SRC} not mounted — import was not run; see DESIGN.md §3.4" >&2; exit 1; }
	echo "library empty — running one-time rsync from ${SRC}"
	hhost "rsync -ah --info=progress2 ${SRC}/ ${MOUNT}/jellyfin/ || { echo 'ERROR: rsync failed; source is ro, nothing lost — re-run' >&2; exit 1; }"
fi

# ---------------------------------------------------------------------------
h "4/7 LXC mount (mp1 -> /vault)"
if hhost "grep -q '^mp1: /mnt/RaidZ1-6TB/vault,mp=/vault$' /etc/pve/lxc/${CT_ID}.conf"; then
	hlxc "test -d /vault/jellyfin" && echo "mount ok"
else
	hhost "pct set ${CT_ID} --mp1 /mnt/RaidZ1-6TB/vault,mp=/vault"
	echo "mp1 added — restarting ${CT_ID} (brief blip to monitoring stack)"
	hhost "pct stop ${CT_ID} && pct start ${CT_ID}"
	for i in $(seq 1 30); do
		hlxc "test -d /vault/jellyfin" 2>/dev/null && { echo "mount ok"; break; }
		sleep 2
		[[ $i -eq 30 ]] && { echo "ERROR: /vault/jellyfin not visible after restart" >&2; exit 1; }
	done
fi

# ---------------------------------------------------------------------------
h "5/7 Stack + configure (pushed to and run on 109)"
hlxc "mkdir -p /srv/data/jellyfin"
if $ON_HOST; then
	pct push "${CT_ID}" "$CONFIGURE_SCRIPT" /srv/data/jellyfin/configure-jellyfin-ct.sh --perms 0755
else
	scp "${SSH_OPTS[@]}" "$CONFIGURE_SCRIPT" root@"${LXC_IP}":/srv/data/jellyfin/configure-jellyfin-ct.sh
	hlxc "chmod 755 /srv/data/jellyfin/configure-jellyfin-ct.sh"
fi
hlxc "bash /srv/data/jellyfin/configure-jellyfin-ct.sh --ip ${JELLYFIN_IP}"

# ---------------------------------------------------------------------------
h "6/7 SMB ([vault] share on prox01)"
hhost bash -s <<'SMB'
set -euo pipefail
CONF=/etc/samba/smb.conf
CHANGED=0
if grep -q '^\[vault\]' "$CONF"; then
	echo "[vault] share already present"
else
	cp "$CONF" "${CONF}.bak-$(date +%Y%m%d-%H%M%S)"
	cat >> "$CONF" <<'EOF'

[vault]
   comment = Home lab archive (Jellyfin library + future)
   path = /mnt/RaidZ1-6TB/vault
   browseable = yes
   read only = yes
   guest ok = yes
EOF
	CHANGED=1
	echo "[vault] share added"
fi
# Retire the legacy [media] section (pre-import source view) — comment out the whole block:
if grep -q '^\[media\]' "$CONF"; then
	cp "$CONF" "${CONF}.bak-$(date +%Y%m%d-%H%M%S)"
	awk '
		/^\[media\]/  { inmed=1; print "; retired " $0; next }
		inmed && /^\[/ { inmed=0 }
		inmed          { print "; retired " $0; next }
		{ print }
	' "$CONF" > "$CONF.new" && mv "$CONF.new" "$CONF"
	CHANGED=1
	echo "[media] section retired"
fi
if ! testparm -s >/dev/null 2>&1; then
	latest=$(ls -t "${CONF}.bak-"* 2>/dev/null | head -1 || true)
	if [[ -n "$latest" ]]; then mv "$latest" "$CONF"; echo "testparm failed — restored $latest" >&2; fi
	systemctl reload-or-restart smbd || systemctl restart smbd
	echo "ERROR: smb.conf invalid after edits" >&2
	exit 1
fi
if [[ "$CHANGED" -eq 1 ]]; then
	systemctl reload-or-restart smbd || systemctl restart smbd
	echo "smbd reloaded"
fi
SMB
echo "shares now:"
hhost "testparm -s 2>/dev/null | grep -E '^\[' || true"

# ---------------------------------------------------------------------------
h "7/7 Verify (workstation side)"
health=""
for i in $(seq 1 45); do
	health=$(curl -s -m 3 "http://${JELLYFIN_IP}/health" 2>/dev/null || true)
	[[ "$health" == *"Healthy"* ]] && break
	sleep 2
done
[[ "$health" == *"Healthy"* ]] || { echo "ERROR: Jellyfin not healthy after 90s (last: '$health')" >&2; exit 1; }
echo "health:       $health"
echo "container IP: $(hhost "ip -o neigh show ${JELLYFIN_IP} | head -n1")"
echo "in-container /media:"
hlxc "docker exec jellyfin ls /media"

echo
echo "Done. First run: open http://jellyfin.mizertech.net/ (admin/admin), add library roots under /media."
