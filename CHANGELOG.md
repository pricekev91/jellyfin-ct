# Changelog

## [0.3.0] - 2026-10-07

### Changed

- **Network: `bench_lan` → `direct_lan`, with outbound internet.** The
  macvlan pool is now `direct_lan`, created by the configure script with
  `--gateway 192.168.1.1`. The explicit gateway is what installs the
  container's default route — restoring **all remote metadata fetching**
  (TheTVDb/TMDb/OMDb/MusicBrainz). Root cause of the missing show/episode
  metadata: the old gateway-less `bench_lan` had no default route, so every
  provider call died with `ENETUNREACH` while import/playback (local disk)
  kept working. `bench_lan` retired 2026-10-07 (Docker refuses two IPAM pools
  on one subnet — the old network had to be deleted first).
- `configure-jellyfin-ct.sh`: creates `direct_lan` (hard error with migration
  instructions if legacy `bench_lan` still exists); verify step now asserts
  outbound egress from the container (HTTP 2xx/3xx from `https://1.1.1.1`).
- DESIGN.md §3.3 rewritten (gateway rationale, migration note, grafana
  re-attach step); README network line updated.

### Fixed

- **Preflight no longer trips on stale ARP entries.** After the container is
  removed the kernel keeps a `FAILED` probe entry for `192.168.1.16`, and the
  old check (neighbor entry present + no live jellyfin container) aborted
  fresh deploys with "in use by something other than the jellyfin container"
  even though nothing answered the IP. Ownership is now judged by a live
  jellyfin container on that IP **or** a live ping reply; stale entries are
  flushed (`ip neigh flush to <ip>/32` — this iproute2 build rejects
  `flush host <ip>`).

### Note (manual, owner)

- After re-deploy: trigger a metadata refresh in Jellyfin (Dashboard →
  Library → *Shows* → **Refresh metadata**) to backfill descriptions,
  episode titles, and artwork.
- Grafana's `.14` LAN face needs re-attach: `docker network connect
  --ip 192.168.1.14 direct_lan grafana` (or re-run its deploy, which
  auto-reuses any macvlan on the subnet).

## [0.2.0] - 2026-10-06

### Added

- **Deployed 2026-10-06** — Jellyfin 12.2.0 running on LXC 109 at
  `192.168.1.16:80` (`http://jellyfin.mizertech.net`), verified end-to-end
  (`/health` → `Healthy`, `/media` populated in-container, SMB advertises `vault`).
  `deploy-jellyfin-ct.sh` + `stacks/jellyfin/` implemented per DESIGN.md §4; the
  script is fully idempotent (re-run passes all 7 steps as no-ops).
- `RaidZ1-6TB/vault` dataset: renamed from `media` (2026-10-06), library
  restructured to `vault/jellyfin/`, mounted into 109 as `/vault` via
  `mp1: /mnt/RaidZ1-6TB/vault,mp=/vault`.
- SMB share `[vault]` on prox01 (`/mnt/RaidZ1-6TB/vault`, ro, guest) — the
  laptop browses the archive at `\\prox01\\vault`.
- One-time media import **completed 2026-10-05**: 219,034,997,158 bytes / 263 files
  from `/mnt/p3ntfs/Users/price/Videos` to `RaidZ1-6TB/media` in ~50 min; verified
  by file count, exact byte parity, rsync size/mtime parity pass, and md5
  spot-check. `p3.raw` untouched (still the safety net, owner-retired only).

### Added

- **Root SSH access step (deploy step 5):** interactive hidden prompt sets the
  LXC 109 root password — writes the same `99-root-login.conf` sshd drop-in as
  `hlh-ai-engine-egpu` (`PermitRootLogin yes`, `PasswordAuthentication yes`),
  sets the password via `chpasswd` over stdin (never argv). `ssh root@192.168.1.9`
  then works from any LAN machine. Re-run: Enter skips.

### Changed

- **Repo restructured to the two-script pattern** (same shape as
  `hlh-ai-engine-egpu`, KISS): `deploy-jellyfin-ct.sh` (provisioning,
  workstation-side over SSH) + `configure-jellyfin-ct.sh` (configuration, runs
  on 109, pushed + executed by the deploy script). The docker-compose file and
  `.env` are inlined as heredocs in the configure script — the `stacks/`
  directory is gone. Both scripts stay idempotent.
- **Runs keyless from prox01:** deploy auto-detects its launch point — on
  prox01 the host-side steps run locally and 109 is reached via `pct
  exec`/`pct push` (zero SSH keys); from anywhere else it falls back to
  root+key SSH (with `StrictHostKeyChecking=accept-new`).
- Web port 8096 → **80**: dedicated IP + DNS means no port in the URL
  (`http://jellyfin.mizertech.net`). Compose adds `cap_add: [NET_BIND_SERVICE]`.
  As of Jellyfin 12.x the port lives in `<configdir>/network.xml`
  (`JELLYFIN_CONFIG_DIR=/config/config`), **not** the legacy
  `/config/config.xml` `<WebPort>` (verified dead in 12.x). The deploy script
  seeds/rewrites `network.xml` with `<InternalHttpPort>80</InternalHttpPort>`
  after first boot and restarts only if the port actually changed; a
  user-changed port is never touched.
- Networking: the compose stack **reuses the pre-existing macvlan pool
  `bench_lan`** (192.168.1.0/24, parent eth0) instead of defining its own —
  Docker rejects a second IPAM pool overlapping the same address space, and
  `bench_lan` already carries grafana's LAN IP (192.168.1.14). Known accepted
  limitation: `bench_lan` has no default route, so the container has no
  outbound internet (in-container plugin auto-update logs a harmless error;
  image updates via `docker pull` on 109 are unaffected).
- Router DNS A record `jellyfin.mizertech.net → 192.168.1.16` is already in place
  — no longer a pending manual step.
- `p3.raw` is now **never retired by deploy/automation** — deletion of the old NTFS
  rescue image is a manual, explicit owner action.
- PBS4: updated and in DNS at `192.168.1.3`; the `.9` conflict with LXC 109 is
  resolved (home-lab-architecture.md and related docs updated).
- Legacy SMB `[media]` share on `/mnt/p3ntfs` **retired** (superseded by
  `[vault]`; pre-import source view no longer needed). Long-term archive =
  offline external drive (no PBS4 backup — media non-mission-critical, owner decision 2026-10-06).

## [0.1.0] - 2026-10-05

### Added

- High-level design (DESIGN.md): Jellyfin on LXC 109 via Docker Compose macvlan at
  192.168.1.16:8096; media + config on host-side ZFS (RaidZ1-6TB/media,
  RaidZ1-6TB/hlh-docker-data) to survive a full LXC nuke/rebuild; one-time
  204 GB media import from the p3.raw NTFS rescue image.
- Discovery findings verified live on prox01/109 (2026-10-05): cap_net_admin in
  109 + working macvlan dry-test, free IP 192.168.1.16, empty pre-created media
  dataset, 32 GiB quota on hlh-docker-data, media located at
  /mnt/p3ntfs/Users/price/Videos (204 GB, only copy on the host).
