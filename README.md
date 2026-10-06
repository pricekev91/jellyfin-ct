# jellyfin-ct

Jellyfin on `hlh-docker` (LXC 109) as infrastructure-as-code.

- Service URL: `http://jellyfin.mizertech.net` (192.168.1.16, port 80 — no port in the URL)
- Status: **deployed 2026-10-06** (Jellyfin 12.2.0 on LXC 109, verified)
- High-level design: [DESIGN.md](DESIGN.md)

## Layout

| Path | Purpose |
|------|---------|
| `DESIGN.md` | High-level design + as-built: storage survival, macvlan networking, media migration |
| `deploy-jellyfin-ct.sh` | **1/2** provisioning (run from prox01 — local exec + `pct`, zero keys — or from the workstation over SSH) — idempotent, executed 2026-10-06, safe to re-run |
| `configure-jellyfin-ct.sh` | **2/2** configuration (runs on 109; pushed + executed by the deploy script; compose inlined as heredoc) |

Two-script pattern (same shape as `hlh-ai-engine-egpu`): one for provision,
one for configuration. Pure bash — no `stacks/` directory, no ansible/opentofu.

## Runbook

- **DNS (done):** router (192.168.1.1) static A record `jellyfin.mizertech.net → 192.168.1.16` already in place
- **Deploy:** `./deploy-jellyfin-ct.sh` from prox01 (preferred — no SSH keys needed) or the workstation (idempotent; on the live system it passes as no-ops)
- **Root SSH to 109:** the deploy prompts for a 109 root password (step 5; Enter skips) — then `ssh root@192.168.1.9`. Manual alternative: `pct exec 109 -- passwd root`
- **First-run (pending, owner):** log in at `http://jellyfin.mizertech.net/` (default admin/admin), add library roots under `/media` (Dragon Ball, GRIMM, Finding Dory, Cars 3, ...)
- **Network:** container joins the shared macvlan pool `bench_lan` (192.168.1.0/24) at 192.168.1.16 — do not delete `bench_lan` while jellyfin/grafana are attached; container has no outbound internet (accepted, DESIGN.md §3.3)
- **Web port:** set in `/srv/data/jellyfin/config/config/network.xml` (`<InternalHttpPort>80</InternalHttpPort>`); changing it via the UI is fine — the deploy script never overwrites a user-changed port
- **Media source:** `p3.raw` NTFS image on prox01 (`/mnt/p3ntfs/Users/price/Videos`, 204 GB) — one-time import into the vault dataset **done 2026-10-05** (dataset renamed `media` → `vault`, library under `vault/jellyfin/`) (219,034,997,158 bytes, 263 files, count+size+md5 verified). **`p3.raw` is never deleted by automation** — retiring the old storage is a manual, explicit owner action, if ever
- **Rebuild survival:** media (`RaidZ1-6TB/vault/jellyfin`) and config (`/srv/data/jellyfin/config` on `RaidZ1-6TB/hlh-docker-data`) are host-side ZFS; a nuke/rebuild of LXC 109 loses nothing but the container, which the deploy recreates
