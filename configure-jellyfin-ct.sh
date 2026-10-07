#!/usr/bin/env bash
# configure-jellyfin-ct.sh — Jellyfin stack configuration (2nd of 2 scripts)
# Pure bash, no ansible/opentofu. One for provision (deploy), one for configuration.
#
# Runs ON LXC 109 (hlh-docker) as root — normally pushed + executed by
# deploy-jellyfin-ct.sh. Also runs standalone on 109:
#
#   ./configure-jellyfin-ct.sh --ip 192.168.1.16
#
# Steps:
#   1) Stack files (compose + .env, heredoc — /srv/data/jellyfin)
#   2) direct_lan macvlan (create if missing, with gateway) + image + `up -d`
#   3) Web port 80 via Jellyfin 12.x network.xml (first-boot fix)
#   4) Verify (health + /media visible in container)
#
# Idempotent — safe to re-run.
set -euo pipefail

JELLYFIN_IP=""
usage() {
	cat <<'EOF'
Usage: ./configure-jellyfin-ct.sh [--ip <container-ip>]

  --ip <ip>  Container's LAN IP (default 192.168.1.16)
  -h, --help Show this help.
EOF
}
while [[ $# -gt 0 ]]; do
	case "$1" in
		--ip)
			[[ $# -ge 2 ]] || { echo "ERROR: --ip requires a value" >&2; exit 1; }
			JELLYFIN_IP="$2"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "ERROR: Unknown option: $1" >&2; usage; exit 1 ;;
	esac
	shift
done
JELLYFIN_IP="${JELLYFIN_IP:-192.168.1.16}"

STK=/srv/data/jellyfin          # stack files (compose, .env)
CFG="$STK/config"               # jellyfin state (configdir /config) — survives container rebuild
NETXML="$CFG/config/network.xml"

wait_health() {
	# $1 = expected health string; polls in-container curl on port 80
	local i
	for i in $(seq 1 45); do
		local h
		h=$(docker exec jellyfin curl -fsS -m 2 http://localhost:80/health 2>/dev/null || true)
		if [[ "$h" == *"$1"* ]]; then
			return 0
		fi
		sleep 2
	done
	return 1
}

echo "==> 1/4 Stack files ($STK)"
mkdir -p "$STK"
cat > "$STK/docker-compose.yml" <<'COMPOSE'
# Jellyfin — deployed by deploy-jellyfin-ct.sh (see DESIGN.md §3.3)
#
# Networking: macvlan `direct_lan` (parent eth0, 192.168.1.0/24,
# --gateway 192.168.1.1) — the container owns 192.168.1.16 directly on the LAN.
# The explicit --gateway installs a default route, so the container HAS full
# outbound internet (metadata: TheTVDb/TMDb/OMDb/MusicBrainz, plugin repo).
# (The retired `bench_lan` had no gateway → no default route → every metadata
# fetch died with ENETUNREACH. See DESIGN.md §3.3.)
# No `ports:` — the container serves port 80 directly on 192.168.1.16
# (jellyfin.mizertech.net; no port in the URL).
#
# Storage: /config  = /srv/data/jellyfin/config  (host ZFS, survives nuke)
#          /media   = /vault/jellyfin           (RaidZ1-6TB/vault, read-only)
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    environment:
      - HEALTHCHECK_URL=http://localhost:80/health   # image default points at 8096
    networks:
      jellyfin_lan:
        ipv4_address: ${JELLYFIN_IP}
    volumes:
      - /srv/data/jellyfin/config:/config
      - /vault/jellyfin:/media:ro
    cap_add:
      - NET_BIND_SERVICE   # bind port 80 as the non-root jellyfin user

networks:
  jellyfin_lan:
    external: true
    name: direct_lan
COMPOSE
cat > "$STK/.env" <<ENV
JELLYFIN_IP=${JELLYFIN_IP}
ENV

echo "==> 2/4 direct_lan + image + up"
if ! docker network inspect direct_lan >/dev/null 2>&1; then
	if docker network inspect bench_lan >/dev/null 2>&1; then
		echo "ERROR: legacy bench_lan still exists — Docker refuses a second IPAM pool on 192.168.1.0/24." >&2
		echo "       Detach its containers, 'docker network rm bench_lan', then re-run." >&2
		exit 1
	fi
	docker network create -d macvlan --opt parent=eth0 --subnet 192.168.1.0/24 --gateway 192.168.1.1 direct_lan
fi
docker image inspect jellyfin/jellyfin:latest >/dev/null 2>&1 || \
	docker compose -f "$STK/docker-compose.yml" pull
docker compose -f "$STK/docker-compose.yml" up -d

# First boot (fresh instance) listens on the stock 8096 until step 3 flips it.
echo "Waiting for Jellyfin to answer (80 or 8096)..."
for i in $(seq 1 45); do
	if docker exec jellyfin curl -fsS -m 2 http://localhost:8096/health 2>/dev/null || \
	   docker exec jellyfin curl -fsS -m 2 http://localhost:80/health 2>/dev/null; then
		break
	fi
	sleep 2
done

echo "==> 3/4 Web port 80 (Jellyfin 12.x: port lives in network.xml, not config.xml)"
sleep 3
if [[ ! -f "$NETXML" ]]; then
	# Fresh instance (still on default 8096): seed the config file.
	echo "network.xml missing (fresh instance, default 8096) — seeding port 80"
	mkdir -p "$CFG/config"
	cat > "$NETXML" <<'XML'
<NetworkConfiguration>
  <InternalHttpPort>80</InternalHttpPort>
  <PublicHttpPort>80</PublicHttpPort>
</NetworkConfiguration>
XML
	docker restart jellyfin
	wait_health Healthy
elif grep -q '<InternalHttpPort>8096</InternalHttpPort>' "$NETXML"; then
	echo "network.xml at default 8096 — rewriting to 80"
	sed -i 's|<InternalHttpPort>8096</InternalHttpPort>|<InternalHttpPort>80</InternalHttpPort>|; s|<PublicHttpPort>8096</PublicHttpPort>|<PublicHttpPort>80</PublicHttpPort>|' "$NETXML"
	docker restart jellyfin
	wait_health Healthy
else
	echo "network.xml has a non-default port — user-managed, leaving alone"
fi

echo "==> 4/4 Verify"
health=$(docker exec jellyfin curl -fsS -m 5 http://localhost:80/health)
[[ "$health" == *"Healthy"* ]] || { echo "ERROR: expected Healthy, got: $health" >&2; exit 1; }
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' jellyfin)
[[ "$ip" == "$JELLYFIN_IP" ]] || { echo "ERROR: container IP $ip != $JELLYFIN_IP" >&2; exit 1; }
# Outbound egress is load-bearing (remote metadata) — verify it, don't assume it.
egress=$(docker exec jellyfin curl -fsS -m 8 -o /dev/null -w '%{http_code}' https://1.1.1.1/ 2>/dev/null || true)
[[ "$egress" =~ ^[23] ]] || { echo "ERROR: no outbound internet from container (https://1.1.1.1 → '$egress') — check direct_lan gateway" >&2; exit 1; }
echo "health: $health (in-container, port 80)"
echo "container IP: $ip"
echo "outbound egress: HTTP $egress (https://1.1.1.1)"
echo "/media (vault/jellyfin):"
docker exec jellyfin ls /media
echo "configure: OK"
