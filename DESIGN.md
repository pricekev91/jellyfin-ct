# jellyfin-ct — Jellyfin on hlh-docker (IaC)

High-level design for running Jellyfin on LXC 109 (`hlh-docker`) as
infrastructure-as-code, with all media and configuration surviving a full
LXC nuke/rebuild.

- **Status:** **DEPLOYED 2026-10-06** — Jellyfin 12.2.0 running at `192.168.1.16:80` on LXC 109 (macvlan via shared pool `bench_lan`), library at `RaidZ1-6TB/vault/jellyfin` (import 2026-10-05, 204G, verified), SMB `\\prox01\\vault` serving, legacy `[media]` share retired. First-run wizard + library setup pending (manual, owner).
- **Target:** `jellyfin.mizertech.net` = `192.168.1.16`, port `80`
- **Repo:** `pricekev91/jellyfin-ct` (this repo)
- **Revision 2026-10-06:** media dataset renamed `media` → `vault` (library under `vault/jellyfin/`); vault is the accessible archive (host path `/mnt/RaidZ1-6TB/vault`, SMB `\\prox01\\vault`); long-term archive = offline external drive (media is non-mission-critical, owner-managed; no PBS4 backup).

---

## 1. Requirements (confirmed)

| # | Requirement | Decision |
|---|-------------|----------|
| R1 | Jellyfin running on hlh-docker (LXC 109), managed as IaC | Docker Compose stack inside 109, deployed by a script from the workstation |
| R2 | Storage must survive a nuke/rebuild of LXC 109 | Media + Jellyfin config live on **host-side ZFS datasets** (prox01), exposed to the container via `mp0` mounts. Images/rootfs are disposable and rebuilt by the deploy script |
| R3 | Dedicated IP `192.168.1.16` (`jellyfin.mizertech.net`), plain port 80 | Docker **macvlan** network; the Jellyfin container itself owns `192.168.1.16/24` and serves the web UI on **80** — no port in the URL (that's the point of the dedicated IP + DNS) |
| R4 | No transcoding needed (media pre-transcoded at file level) | No CPU/GPU transcoding budget; direct-play only |
| R5 | `jellyfin.mizertech.net` resolves | Static entry on the router (`192.168.1.1`) — **done** (A record `jellyfin.mizertech.net → 192.168.1.16` already in place) |

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
- `net0` has **no** `firewall=1`, so no Proxmox firewall rules block 80. (If a PVE firewall is ever enabled, allow 80/tcp on 109.)

### Storage (prox01 ZFS)

| Dataset | Mountpoint | Used | Notes |
|---------|-----------|------|-------|
| `RaidZ1-6TB` | `/mnt/RaidZ1-6TB` | 4.07T | ~1.27T available — plenty for ~204GB media |
| `RaidZ1-6TB/hlh-docker-data` | `/srv/data` (host) → `/srv/data` (LXC 109) | ~269M | **Quota 32 GiB** (verified). Holds docker root, grafana/prometheus state. Jellyfin config + image layers fit easily |
| `RaidZ1-6TB/vault` (renamed from `media` 2026-10-06) | `/mnt/RaidZ1-6TB/vault` (host) | 204G | **Library imported 2026-10-05** (263 files, count+size+md5 verified), restructured to `vault/jellyfin/` 2026-10-06; no quota. Accessible from the laptop as SMB share `\\prox01\\vault` |
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
- **Import completed 2026-10-05** into `RaidZ1-6TB/media` (204G, 263 files,
  count+size+md5 verified) — the promotion of the only media copy onto real ZFS
  storage is done; it lands under `RaidZ1-6TB/vault/jellyfin` after the rename.
  `p3.raw` (and the ro mount) is **kept indefinitely** — its retirement/deletion
  is a **manual decision by the owner**, never part of deploy, cron, or runbook automation.

### Networking

- `192.168.1.16`: free — `ip neigh` shows `FAILED`/no owner; no DHCP reservation needed (static).
- `192.168.1.9`: owned by 109 (ARP matches 109's hwaddr). **Conflict resolved:**
  PBS4 has been updated and re-addressed to `192.168.1.3` (in DNS); 109 keeps `.9`.
  `home-lab-architecture.md` updated to match.
- Known issues not touched by this project: Technitium DNS (192.168.1.2) down.

## 3. Design

### 3.1 Component view

```
prox01 (Proxmox host, 192.168.1.10)
├── ZFS: RaidZ1-6TB
│   ├── /vault            ← mp1 into 109 (renamed from "media" at deploy 2026-10-06)
│   │     └── jellyfin/   ← import from p3ntfs (204 GB, done 2026-10-05) — the library
│   ├── /srv/data (hlh-docker-data, quota 32G)
│   │     ├── docker/          (docker root — images, containers metadata)
│   │     └── jellyfin/config/ ← Jellyfin state (db, configdir w/ network.xml, cache)
│   └── /mnt/RaidZ1-6TB/p3img/p3.raw → /mnt/p3ntfs (ro NTFS, source only — kept indefinitely)
│
└── LXC 109 (hlh-docker, 192.168.1.9, unprivileged, 4c/4G)
    └── docker (rootful)
        ├── jellyfin  ← jellyfin/jellyfin:latest (12.2.0 as of deploy)
        │    network: macvlan — reuses shared pool `bench_lan` (parent eth0) → container IP 192.168.1.16/24
        │    volumes: /srv/data/jellyfin/config → /config
        │             /vault/jellyfin           → /media (ro)
        │    port **80/tcp** directly on 192.168.1.16 (no published-port indirection)
        ├── grafana (on bench_lan, 192.168.1.14) / prometheus / node-exporter / dockhand / technitium (existing, untouched)
```

### 3.2 Storage & survival (R2 — the core requirement)

**What survives a nuke of LXC 109** (everything that matters is host-side ZFS):

| Data | Lives in | Survives `pct destroy 109` + rebuild? |
|------|----------|----------------------------------------|
| Media library | `RaidZ1-6TB/vault/jellyfin` (host ZFS) | **Yes** — untouched by any container operation |
| Jellyfin config/db | `RaidZ1-6TB/hlh-docker-data` → `/srv/data/jellyfin/config` | **Yes** |
| Docker images | `RaidZ1-6TB/hlh-docker-data` → `/srv/data/docker` | **Yes** (re-pull if ever lost) |
| LXC rootfs | `RaidZ1-6TB/subvol-109-disk-0` | No — recreated by `hlh-docker` deploy |
| Docker networks (incl. macvlan) | container rootfs / docker state | No — recreated by `deploy-jellyfin-ct.sh` |

**Survival contract after a nuke:**
1. `hlh-docker` deploy rebuilds LXC 109 (existing repo, no changes required for its own stack).
2. `deploy-jellyfin-ct.sh` re-runs (idempotent):
   - ensures `mp1: /mnt/RaidZ1-6TB/vault,mp=/vault` is present in `109.conf` (adds it if absent, restarts 109 only when the line changed),
   - `docker compose up -d` recreates the macvlan network + container at the same IP,
   - config path `/config` is unchanged on disk → same library paths (`/media/...`) → **zero re-configuration**.
3. Media is never moved, copied-on-rebuild, or touched by the container at write time (`/media` mounted read-only).

**Backups / long-term storage (owner decision 2026-10-06):** media is
**non-mission-critical**, so there is **no PBS4 backup target for vault**. The
ZFS story stays as a simple local safety net: `zfs snapshot RaidZ1-6TB/vault@daily`
+ `RaidZ1-6TB/hlh-docker-data@daily` via a cron entry in the deploy runbook
(one-liner, no new infrastructure). **Long-term archive: offline external drive** —
the owner copies the library manually (from `\\prox01\\vault` on the laptop or
`/mnt/RaidZ1-6TB/vault` on the host); the drive stays powered off between copies.

### 3.3 Networking (R3)

- **Reuses the pre-existing macvlan pool `bench_lan`** (macvlan, parent `eth0`,
  subnet `192.168.1.0/24`) instead of defining its own network. Why: Docker
  refuses a second IPAM pool overlapping the same address space (`invalid pool
  request: Pool overlaps with other one on this address space`), and `bench_lan`
  already carries the LAN face of grafana (`192.168.1.14`). `bench_lan` is thus
  the shared LAN macvlan pool on 109: grafana `.14`, jellyfin `.16`.
  ```yaml
  networks:
    jellyfin_lan:
      external: true
      name: bench_lan
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
        - /vault/jellyfin:/media:ro
      cap_add: [NET_BIND_SERVICE]   # bind port 80 as the non-root jellyfin user
  ```
- No `ports:` mapping — the container speaks **80** directly on `192.168.1.16`.
- **Port 80, not Jellyfin's stock 8096:** as of Jellyfin **12.x** the web port
  lives in `<configdir>/network.xml` (`StoreKey "network"`, configdir =
  `JELLYFIN_CONFIG_DIR` = `/config/config`) — the legacy `/config/config.xml`
  `<WebPort>` pre-seed is **dead** in 12.x (verified: ignored, server boots on
  8096 regardless). The deploy script handles it post-first-boot:
  - `network.xml` missing (fresh instance, default 8096 in effect) → seed it with
    `<InternalHttpPort>80</InternalHttpPort>` + `<PublicHttpPort>80</PublicHttpPort>` and restart;
  - `network.xml` present with default 8096 → rewrite to 80 and restart;
  - any other port → user-managed (e.g. set via UI) — left alone.
  `NET_BIND_SERVICE` lets the non-root `jellyfin` user bind the privileged port.
- **Feasibility proven:** 109 has `cap_net_admin` and a macvlan dry-test passed
  (existing `bench_lan` proves the pattern in this LXC).
- **Constraints accepted:**
  - A macvlan container is L2-isolated from the rest of the LXC: it cannot reach
    109's own IP (192.168.1.9) or docker0 services, and vice versa. That's fine —
    Jellyfin is a standalone server here.
  - **No outbound internet from the container:** `bench_lan` has no default
    route, so Jellyfin's in-container plugin auto-update cannot reach
    `repo.jellyfin.org` (logs an error, harmless). Image updates are unaffected —
    `docker pull` runs on 109, which has internet. Accepted.
  - If the LXC is ever rebuilt with a different `eth0` (different hwaddr), the
    macvlan is recreated by the deploy script anyway — no drift.
  - `bench_lan` must not be deleted while jellyfin (or grafana) is attached;
    the deploy script's preflight re-checks IP ownership on re-runs.
- **Router:** static entry `jellyfin.mizertech.net → 192.168.1.16` (manual, R5).
  No DHCP reservation required; `.16` verified free before deploy.

### 3.4 Media migration (one-time — DONE)

- **Import: DONE 2026-10-05.** Source `/mnt/p3ntfs/Users/price/Videos` (ro NTFS
  loop mount of `p3.raw`) → `RaidZ1-6TB/media` via host-side `rsync -ah`
  (~50 min at ~220 MB/s sustained). Verified: 219,034,997,158 bytes / 263 files,
  exact byte parity, count+size+md5 spot-check. Byte-preserving, no renaming.
- **Vault rename + restructure: DONE 2026-10-06** (deploy step 2):
  1. `mkdir /mnt/RaidZ1-6TB/media/jellyfin`
  2. Moved the library entries into it (same-filesystem `mv` — instant, no data copy)
  3. `zfs rename RaidZ1-6TB/media RaidZ1-6TB/vault` (mountpoint followed to
     `/mnt/RaidZ1-6TB/vault`)
  → library lives at `RaidZ1-6TB/vault/jellyfin` (host path
  `/mnt/RaidZ1-6TB/vault/jellyfin`, exposed to the container as `/media` via the
  vault mount at `/vault`).
- **`p3.raw` is never retired by this project** — deleting the NTFS rescue image
  is a manual, explicit owner action. No deploy step, cron, or runbook entry touches it.

### 3.5 Sizing

- Jellyfin (no transcoding, direct-play) is light: well within 109's 4 cores /
  4 GB RAM alongside the existing monitoring stack. No LXC resize needed.
- Disk: 204 GB media into a pool with ~1.27 TB free. Config + image ≈ a few GB in
  the 32 GiB `hlh-docker-data` quota (currently ~270 MB used) — comfortable.
  **Do not** point the media at `hlh-docker-data` (quota would explode).

## 4. Deploy (two-script pattern — same shape as hlh-ai-engine-egpu)

KISS: **two executable files, pure bash, no ansible/opentofu.** One for
provision, one for configuration. The compose file is inlined as a heredoc in
the configure script — there is no `stacks/` directory.

Run from **prox01** (preferred — host-side steps run locally, 109 via
`pct exec`/`pct push`, **zero SSH keys**) or from the workstation (root+key
SSH to prox01 + 109). The script detects which it is.

- **`deploy-jellyfin-ct.sh`** — provisioning:
  1. **Preflight** — SSH both hosts; 109 running, docker up, `192.168.1.16`
     unclaimed — or claimed *by the jellyfin container* (re-run mode).
  2. **Vault rename** [prox01] — if the dataset is still `media`: restructure
     the library into `jellyfin/`, then `zfs rename` (same-filesystem, instant).
     Idempotent: skip when `RaidZ1-6TB/vault/jellyfin` holds the library.
  3. **Import guard** [prox01] — only if the library is empty **and** `/mnt/p3ntfs`
     is mounted (the import itself is done 2026-10-05 — §3.4).
  4. **LXC mount** [prox01] — ensure `mp1: /mnt/RaidZ1-6TB/vault,mp=/vault`;
     restart 109 **only** if the line was added (brief blip to the monitoring
     stack — expected, documented).
  5. **Root SSH access for 109** — interactive hidden prompt (with repeat
     confirm) for the LXC root password. Writes the same sshd drop-in as
     `hlh-ai-engine-egpu` (`99-root-login.conf`: `PermitRootLogin yes`,
     `PasswordAuthentication yes`) and sets the password via `chpasswd`
     over stdin (never argv — invisible in `ps`). Afterwards
     `ssh root@192.168.1.9` works from anywhere on the LAN. Re-runs:
     Enter = skip. Non-interactive (no tty): skipped with a note.
  6. **Stack + configure** [109] — `scp` (or `pct push`) the configure script
     into `/srv/data/jellyfin/` and run it there (next item).
  7. **SMB** [prox01] — add `[vault]` (`read only = yes`, `guest ok = yes`),
     retire the legacy `[media]` section in the same edit (timestamped backup
     first, `testparm` validated, smbd reloaded). Laptop browses
     **`\\prox01\\vault`**.
  8. **Verify** [workstation] — `curl http://192.168.1.16/health`.
- **`configure-jellyfin-ct.sh`** — configuration, runs **on 109** (pushed +
  executed by deploy; also runs standalone: `./configure-jellyfin-ct.sh --ip 192.168.1.16`):
  1. **Stack files** — compose + `.env` (heredocs) → `/srv/data/jellyfin/`.
  2. **Up** — `bench_lan` macvlan pool (create only if missing), image
     (pull only if missing), `docker compose up -d`.
  3. **Port 80** — via `network.xml` (§3.3): seed when missing, rewrite the
     stock 8096, never touch a user-changed port; restart only when changed.
  4. **Verify** — in-container health on 80, container IP, `/media` listing.

Both scripts are idempotent (every step checks state before acting) — a
re-run on the live system is a no-op. Live state as of 2026-10-06:
`/health` → `Healthy` at `192.168.1.16:80`, `/media` populated, SMB
advertises `vault` only.

**Remaining manual step (owner):** open `http://jellyfin.mizertech.net/`
(first-run wizard, default `admin/admin`), then add library roots under
`/media` (dirs listed in §2).

Repo layout:

```
jellyfin-ct/
├── DESIGN.md                     # this file
├── README.md                     # quickstart + runbook (DNS, first-run, import status)
├── deploy-jellyfin-ct.sh         # 1/2 — provisioning (workstation)
├── configure-jellyfin-ct.sh      # 2/2 — configuration (on 109, pushed by deploy)
└── CHANGELOG.md
```

## 5. Risks & open items

| Item | Risk | Mitigation / status |
|------|------|---------------------|
| ~~`p3.raw` was the **only** media copy~~ | — | **Resolved 2026-10-05** — import complete + verified (204G in `RaidZ1-6TB/media`); `p3.raw` still **kept indefinitely** — only the owner deletes it, manually, never automation |
| No automated off-site backup for vault | Media non-mission-critical (owner decision 2026-10-06); only local ZFS snapshots | Long-term archive is the **offline external drive** (manual, owner-initiated from `\\prox01\\vault`); accepted by owner |
| 32 GiB quota on `hlh-docker-data` | Future stack growth could fill it | Jellyfin uses only config there (~100 MB); media is on `RaidZ1-6TB/vault` with no quota; monitor via existing node-exporter |
| Nuke requires LXC 109 restart for `mp1` | ~30 s blip to monitoring stack during first deploy | Scheduled/accepted; restart skipped on re-runs when the line is already present |
| ~~`.9` conflict: PBS4 doc said .9, ARP says 109 owns .9~~ | — | **Resolved** — PBS4 re-addressed to `192.168.1.3` and in DNS; 109 owns `.9`; architecture doc updated |
| ~~PBS4 backups broken~~ | — | **Resolved** — PBS4 updated, in DNS at `192.168.1.3`; ZFS snapshot cron (§3.2) remains as a local extra |
| Technitium DNS down | Secondary DNS (.1.2) unavailable | Out of scope; resolution uses router static entry |
| Macvlan + future LXC IP change | Network recreated by deploy — no action | Idempotent deploy handles it |

## 6. Explicitly out of scope

- Transcoding (R4: not needed — direct-play only).
- Public exposure / reverse proxy / TLS (LAN-only at 192.168.1.16).
- Auth/users beyond Jellyfin's own (first-login is manual).
- Deleting/retiring `p3.raw` or any other storage — owner action only, manual and explicit (never automation).
- PBS4 backup of `RaidZ1-6TB/vault` — media is non-mission-critical (owner decision 2026-10-06); the long-term archive is the offline external drive, copied manually.
- Fixing Technitium DNS (separate workstream). (PBS4 and the `.9` conflict are now resolved.)
- Moving the existing monitoring stack or any other 109 service.
