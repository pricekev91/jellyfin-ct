# jellyfin-ct

Jellyfin on `hlh-docker` (LXC 109) as infrastructure-as-code.

- Service URL: `http://jellyfin.mizertech.net:8096` (192.168.1.16, port 8096)
- High-level design: [DESIGN.md](DESIGN.md)

## Layout

| Path | Purpose |
|------|---------|
| `DESIGN.md` | High-level design: storage survival, macvlan networking, media migration |
| `deploy-jellyfin-ct.sh` | Idempotent deploy (host-side over SSH) — pending implementation |
| `stacks/jellyfin/` | docker-compose stack — pending implementation |

## Runbook

- **Static DNS (manual, one-time):** router (192.168.1.1) → `jellyfin.mizertech.net` A record → `192.168.1.16`
- **First-run:** after deploy, log in at `http://jellyfin.mizertech.net:8096/` (default admin/admin), add library roots under `/media` (Dragon Ball, GRIMM, Finding Dory, Cars 3, ...)
- **Media source:** `p3.raw` NTFS image on prox01 (`/mnt/p3ntfs/Users/price/Videos`, 204 GB) — one-time import into `RaidZ1-6TB/media`; do not retire `p3.raw` until the import is verified
- **Rebuild survival:** media (`RaidZ1-6TB/media`) and config (`/srv/data/jellyfin/config` on `RaidZ1-6TB/hlh-docker-data`) are host-side ZFS; a nuke/rebuild of LXC 109 loses nothing but the container, which the deploy recreates
