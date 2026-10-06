# jellyfin-ct

Jellyfin on `hlh-docker` (LXC 109) as infrastructure-as-code.

- Service URL: `http://jellyfin.mizertech.net` (192.168.1.16, port 80 — no port in the URL)
- High-level design: [DESIGN.md](DESIGN.md)

## Layout

| Path | Purpose |
|------|---------|
| `DESIGN.md` | High-level design: storage survival, macvlan networking, media migration |
| `deploy-jellyfin-ct.sh` | Idempotent deploy (host-side over SSH) — pending implementation |
| `stacks/jellyfin/` | docker-compose stack — pending implementation |

## Runbook

- **DNS (done):** router (192.168.1.1) static A record `jellyfin.mizertech.net → 192.168.1.16` already in place
- **First-run:** after deploy, log in at `http://jellyfin.mizertech.net/` (port 80; default admin/admin), add library roots under `/media` (Dragon Ball, GRIMM, Finding Dory, Cars 3, ...)
- **Media source:** `p3.raw` NTFS image on prox01 (`/mnt/p3ntfs/Users/price/Videos`, 204 GB) — one-time import into the vault dataset **done 2026-10-05** (dataset renamed `media` → `vault`, library under `vault/jellyfin/`) (219,034,997,158 bytes, 263 files, count+size+md5 verified). **`p3.raw` is never deleted by automation** — retiring the old storage is a manual, explicit owner action, if ever
- **Rebuild survival:** media (`RaidZ1-6TB/vault/jellyfin`) and config (`/srv/data/jellyfin/config` on `RaidZ1-6TB/hlh-docker-data`) are host-side ZFS; a nuke/rebuild of LXC 109 loses nothing but the container, which the deploy recreates
