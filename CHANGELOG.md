# Changelog

## [Unreleased]

### Changed

- Web port 8096 → **80**: dedicated IP + DNS means no port in the URL
  (`http://jellyfin.mizertech.net`). Compose adds `cap_add: [NET_BIND_SERVICE]`;
  first deploy pre-seeds `<webPort>80</webPort>` in the persistent config.
- Router DNS A record `jellyfin.mizertech.net → 192.168.1.16` is already in place
  — no longer a pending manual step.
- `p3.raw` is now **never retired by deploy/automation** — deletion of the old NTFS
  rescue image is a manual, explicit owner action.
- PBS4: updated and in DNS at `192.168.1.3`; the `.9` conflict with LXC 109 is
  resolved (home-lab-architecture.md and related docs updated).
- Media dataset to be renamed `media` → `vault` at deploy (library moves under
  `vault/jellyfin/`); SMB `\\prox01\\vault` share added; long-term archive =
  offline external drive (no PBS4 backup — media non-mission-critical, owner decision 2026-10-06).

### Added

- One-time media import **completed 2026-10-05**: 219,034,997,158 bytes / 263 files
  from `/mnt/p3ntfs/Users/price/Videos` to `RaidZ1-6TB/media` in ~50 min; verified
  by file count, exact byte parity, rsync size/mtime parity pass, and md5
  spot-check. `p3.raw` untouched (still the safety net, owner-retired only).

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
