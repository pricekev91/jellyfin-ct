# Changelog

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
