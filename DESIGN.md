# jellyfin-ct — Jellyfin on hlh-docker (IaC)

High-level design for running Jellyfin on LXC 109 (`hlh-docker`) as
infrastructure-as-code, with all media and configuration surviving a full
LXC nuke/rebuild.

- **Status:** Planning complete (discovery verified 2026-10-05). Implementation is the next session.
- **Target:** `jellyfin.mizertech.net` = `192.168.1.16`, port `8096`
- **Repo:** `pricekev91/jellyfin-ct` (this repo)

---

## 1. Requirements (confirmed)

| # | Requirement | Decision |
|---|-------------|----------|
| R1 | Jellyfin running on hlh-docker (LXC 109), managed as IaC | Docker Compose stack inside 109, deployed by a script from the workstation |
| R2 | Storage must survive a nuke/rebuild of LXC 109 | Media + Jellyfin config live on **host-side ZFS datasets** (prox01), exposed to the container via `mp0` mounts. Images/rootfs are disposable and rebuilt by the deploy script |
| R3 | Dedicated IP `192.168.1.16` (`jellyfin.mizertech.net`) | Docker **macvlan** network; the Jellyfin container itself owns `192.168.1.16/24` |
| R4 | No transcoding needed (media pre-transcoded at file level) | No CPU/GPU transcoding budget; direct-play only |
| R5 | `jellyfin.mizertech.net` resolves | Static entry on the router (`192.168.1.1`) — manual step, documented in deploy runbook |

## 2. Verified environment facts (discovery, 2026-10-05)

### LXC 109 (`hlh-docker`, 192.168.1.9)

- `/etc/pve/lxc/109.conf` (as read on prox01):
  - `unprivileged: 1`, `ostype: ubuntu`, `cores: 4`, `memory: 4096`, `swap: 0`
  - `rootfs: RaidZ1-6TB:subvol-109-disk-0,size=32G`
  - `mp0: /srv/data,mp=/srv/data` (the one existing data mount)
  - `net0: veth, bridge=vmbr0, ip=192.168.1.9/24, hwaddr=BC:24:11:D4:B7:B4`
  - `features: nesting=1,keyctl=1`, `onboot: 1`
- Effective capabilities **include `cap_net_admin`** (verified in-container via `/proc/self/status`) and a live `ip link add ... type macvlan` dry-test **succeeded**. The macvlan approach (R3) works in this unprivileged LXC.
- Docker: rootful `dockerd` (root), Server 29.8.1, Compose v5.5.1, storage driver `overlayfs`, **Docker Root Dir `/srv/data/docker`** (i.e. inside the surviving dataset — see below).
- `jellyfin/jellyfin:latest` manifest resolves from 109 (pull path is open).
- Existing macvlan precedent: network `bench_lan` (macvlan, parent `eth0`, subnet `192.168.1.0/24`).
- `net0` has **no** `firewall=1`, so no Proxmox firewall rules block 8096. (If a PVE firewall is ever enabled, allow 8096/tcp on 109.)

### Storage (prox01 ZFS)

| Dataset | Mountpoint | Used | Notes |
|---------|-----------|------|-------|
| `RaidZ1-6TB` | `/mnt/RaidZ1-6TB` | 4.07T | ~1.27T available — plenty for ~204GB media |
| `RaidZ1-6TB/hlh-docker-data` | `/srv/data` (host) → `/srv/data` (LXC 109) | ~269M | **Quota 32 GiB** (verified). Holds docker root, grafana/prometheus state. Jellyfin config + image layers fit easily |
| `RaidZ1-6TB/media` | `/mnt/RaidZ1-6TB/media` (host) | 128K (empty) | **Pre-created, empty, no quota — the target media dataset** |
| `RaidZ1-6TB/subvol-109-disk-0` | — | 2.44G | 109 rootfs (quota 30G) — disposable |
| `RaidZ1-6TB/p3img` | `/mnt/RaidZ1-6TB/p3img` | ~2.5T | Rescued Windows disk: `p3.img` + `p3.raw` (NTFS) |

### The media (found)

- `/etc/fstab` on prox01 mounts `p3.raw` read-only:
  `/mnt/RaidZ1-6TB/p3img/p3.raw /mnt/p3ntfs ntfs-3g loop,ro,nofail 0 0`
- The library lives at **`/mnt/p3ntfs/Users/price/Videos/` — 204 GB**, containing:
  `Captures/`, `Cars 3/`, `Dragon Ball/`, `Dragon Ball Z/`, `Finding Dory/`,
  `GRIMM/`, `Little House on the Prairie/`, `Dmd-Idiocracy.mp4`, `desktop.ini`
- **No other copy of this media exists anywhere on prox01** (swept `/mnt/RaidZ1-6TB`
  incl. all LXC subvols, `/srv`, `/var`, Raid0-2TB, and the unmounted
  `docker-data`/`dockhand-data` datasets). `p3.raw` is the only source.
- Implication: the import into `RaidZ1-6TB/media` is a **promotion of the only
  media copy onto real ZFS storage**. Keep `p3.raw` (and the ro mount) until the
  import is verified, then it can be dropped to free ~2TB.

### Networking

- `192.168.1.16`: free — `ip neigh` shows `FAILED`/no owner; no DHCP reservation needed (static).
- `192.168.1.9`: owned by 109 (ARP matches 109's hwaddr). PBS4 (VMID 103, running)
  is documented at .9 in `home-lab-architecture.md` — **stale doc or real conflict;
  out of scope here but worth resolving separately.**
- Known issues not touched by this project: Technitium DNS (192.168.1.2) down, PBS4
  backups broken.

## 3. Design

### 3.1 Component view

```
prox01 (Proxmox host, 192.168.1.10)
├── ZFS: RaidZ1-6TB
│   ├── /media            ← NEW: mp0 into 109 (dataset already exists, empty)
│   │     └── <Movies/TV dirs>   ← one-time import from p3ntfs (204 GB)
│   ├── /srv/data (hlh-docker-data, quota 32G)
│   │     ├── docker/          (docker root — images, containers metadata)
│   │     └── jellyfin/config/ ← NEW: Jellyfin state (db, config.xml, cache)
│   └── /mnt/RaidZ1-6TB/p3img/p3.raw → /mnt/p3ntfs (ro NTFS, source only)
│
└── LXC 109 (hlh-docker, 192.168.1.9, unprivileged, 4c/4G)
    └── docker (rootful)
        ├── jellyfin  ← NEW: jellyfin/jellyfin:latest
        │    network: macvlan "jellyfin_lan" (parent eth0) → container IP 192.168.1.16/24
        │    volumes: /srv/data/jellyfin/config → /config
        │             /media                    → /media (ro)
        │    port 8096/tcp directly on 192.168.1.16 (no published-port indirection)
        ├── grafana / prometheus / node-exporter / dockhand / technitium (existing, untouched)
```

### 3.2 Storage & survival (R2 — the core requirement)

**What survives a nuke of LXC 109** (everything that matters is host-side ZFS):

| Data | Lives in | Survives `pct destroy 109` + rebuild? |
|------|----------|----------------------------------------|
| Media library | `RaidZ1-6TB/media` (host ZFS) | **Yes** — untouched by any container operation |
| Jellyfin config/db | `RaidZ1-6TB/hlh-docker-data` → `/srv/data/jellyfin/config` | **Yes** |
| Docker images | `RaidZ1-6TB/hlh-docker-data` → `/srv/data/docker` | **Yes** (re-pull if ever lost) |
| LXC rootfs | `RaidZ1-6TB/subvol-109-disk-0` | No — recreated by `hlh-docker` deploy |
| Docker networks (incl. macvlan) | container rootfs / docker state | No — recreated by `deploy-jellyfin-ct.sh` |

**Survival contract after a nuke:**
1. `hlh-docker` deploy rebuilds LXC 109 (existing repo, no changes required for its own stack).
2. `deploy-jellyfin-ct.sh` re-runs (idempotent):
   - ensures `mp0: /mnt/RaidZ1-6TB/media,mp=/media` is present in `109.conf` (adds it if absent, restarts 109 only when the line changed),
   - `docker compose up -d` recreates the macvlan network + container at the same IP,
   - config path `/config` is unchanged on disk → same library paths (`/media/...`) → **zero re-configuration**.
3. Media is never moved, copied-on-rebuild, or touched by the container at write time (`/media` mounted read-only).

**Backups:** PBS4 is broken (known issue), so the interim story is ZFS:
`zfs snapshot RaidZ1-6TB/media@daily` + `RaidZ1-6TB/hlh-docker-data@daily` via a cron
entry in the deploy runbook (one-liner, no new infrastructure).

### 3.3 Networking (R3)

- Compose-defined macvlan network:
  ```yaml
  networks:
    jellyfin_lan:
      driver: macvlan
      driver_opts: { parent: eth0 }
      ipam:
        config:
          - subnet: 192.168.1.0/24
            gateway: 192.168.1.1
  services:
    jellyfin:
      image: jellyfin/jellyfin:latest
      container_name: jellyfin
      restart: unless-stopped
      networks:
        jellyfin_lan:
          ipv4_address: 192.168.1.16
      volumes:
        - /srv/data/jellyfin/config:/config
        - /media:/media:ro
  ```
- No `ports:` mapping — the container speaks 8096 directly on `192.168.1.16`.
- **Feasibility proven:** 109 has `cap_net_admin` and a macvlan dry-test passed
  (existing `bench_lan` proves the pattern in this LXC).
- **Constraints accepted:**
  - A macvlan container is L2-isolated from the rest of the LXC: it cannot reach
    109's own IP (192.168.1.9) or docker0 services, and vice versa. That's fine —
    Jellyfin is a standalone server here.
  - If the LXC is ever rebuilt with a different `eth0` (different hwaddr), the
    macvlan is recreated by the deploy script anyway — no drift.
- **Router:** static entry `jellyfin.mizertech.net → 192.168.1.16` (manual, R5).
  No DHCP reservation required; `.16` verified free.

### 3.4 Media migration (one-time)

- Source: `/mnt/p3ntfs/Users/price/Videos` (ro NTFS loop mount of `p3.raw`, 204 GB).
- Target: `RaidZ1-6TB/media` (host mount `/mnt/RaidZ1-6TB/media`, exposed to the
  container as `/media`).
- Mechanism: host-side `rsync -ah --info=progress2 /mnt/p3ntfs/Users/price/Videos/ /mnt/RaidZ1-6TB/media/`
  on prox01 (same machine, no network hop; NTFS read + ZFS write, expect ~30–90 min).
  Resumable by design.
- Runbook order: import **before** first `docker compose up` (or concurrently —
  Jellyfin will just scan later). After verification (file counts + sizes match,
  one spot-checked file plays), `p3.raw` may be retired (frees ~2 TB) — separate
  explicit decision, not part of this deploy.
- Filename hygiene: NTFS names with spaces are fine for Jellyfin; the import is
  byte-preserving, no renaming.

### 3.5 Sizing

- Jellyfin (no transcoding, direct-play) is light: well within 109's 4 cores /
  4 GB RAM alongside the existing monitoring stack. No LXC resize needed.
- Disk: 204 GB media into a pool with ~1.27 TB free. Config + image ≈ a few GB in
  the 32 GiB `hlh-docker-data` quota (currently ~270 MB used) — comfortable.
  **Do not** point the media at `hlh-docker-data` (quota would explode).

## 4. Deploy plan (next session — not this one)

`deploy-jellyfin-ct.sh` (workstation-side, runs over SSH to prox01 + 109,
root+key auth confirmed working for both):

1. **Preflight** — SSH both hosts; verify `RaidZ1-6TB/media` exists (`zfs create -n` guarded),
   109 running, docker healthy, `192.168.1.16` unclaimed (`ip neigh`).
2. **Import** (only if `/mnt/RaidZ1-6TB/media` is empty and `/mnt/p3ntfs` is mounted) —
   rsync with progress; on completion verify count/size parity.
3. **LXC mount** — ensure `mp0: /mnt/RaidZ1-6TB/media,mp=/media` in `109.conf`;
   `pct stop/start 109` **only if the line was added/changed** (brief blip to
   grafana/prometheus/dockhand — expected, documented).
4. **Stack** — write `/srv/data/jellyfin/` (compose file + `.env`), `docker compose up -d`.
5. **Verify** — `curl http://192.168.1.16:8096/health` (or `/web/` 200), confirm
   container IP from the workstation, confirm `/media` visible + readable in-container,
   log first-boot admin credentials to the runbook (default `admin/admin`, user changes on first login).
6. **Handoff** — router static DNS entry (manual), first-run library setup:
   add Movies/TV roots under `/media` (dirs listed in §2).

Repo layout (planned):

```
jellyfin-ct/
├── DESIGN.md                     # this file
├── README.md                     # quickstart + runbook (DNS, first-run, import status)
├── deploy-jellyfin-ct.sh         # the idempotent deploy (section 4)
├── stacks/jellyfin/
│   ├── docker-compose.yml
│   └── .env
└── CHANGELOG.md
```

## 5. Risks & open items

| Item | Risk | Mitigation / status |
|------|------|---------------------|
| `p3.raw` is the **only** media copy until import completes | Import failure mid-flight = media stuck in NTFS image | Import is the first deploy step, resumable rsync; don't retire `p3.raw` until verified |
| 32 GiB quota on `hlh-docker-data` | Future stack growth could fill it | Jellyfin uses only config there (~100 MB); media is on `RaidZ1-6TB/media` with no quota; monitor via existing node-exporter |
| Nuke requires LXC 109 restart for `mp0` | ~30 s blip to monitoring stack during first deploy | Scheduled/accepted; restart skipped on re-runs when the line is already present |
| `.9` conflict: PBS4 (103) doc says .9, ARP says 109 owns .9 | Possible stale doc or latent conflict | Out of scope; tracked in `home-lab-architecture.md` known issues |
| PBS4 backups broken | No VM/LXC-level snapshots as safety net | ZFS snapshot cron (§3.2) covers media + config; PBS4 is a separate known issue |
| Technitium DNS down | Secondary DNS (.1.2) unavailable | Out of scope; resolution uses router static entry |
| Macvlan + future LXC IP change | Network recreated by deploy — no action | Idempotent deploy handles it |

## 6. Explicitly out of scope

- Transcoding (R4: not needed — direct-play only).
- Public exposure / reverse proxy / TLS (LAN-only at 192.168.1.16).
- Auth/users beyond Jellyfin's own (first-login is manual).
- Fixing PBS4, the .9 conflict, or Technitium (separate workstreams).
- Moving the existing monitoring stack or any other 109 service.
