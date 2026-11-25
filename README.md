# FoxDen core

This is the monorepo to control the FoxDen homelab pretty much in its entirety.

`router`, `router-backup` and `redfox` can be rebuilt from a reset by `mikrotik/configure.py`, except for users, passwords, certificates and WireGuard keys and peers (the VPN portal manages the `wg-vpn` peers itself). The addressing plan (VLANs, VRRP addresses, router addresses) lives in `nix/modules/lib/routers.nix`. We still keep regular backups of those devices around.

## Machines

### BengalFox

- **Locator**: Rack; 2U, Supermicro chassis
- **OS**: NixOS
- **CPU**: Dual Xeon E5-2690v4
- **RAM**: 256GB, DDR4-ECC, 2400 MT/s
- **Storage**:
	- nix: XFS: RAID1: 2 * 2TB NVMe SSD
	- zhdd: ZFS:
		- RAIDZ2: 8 * 18 TB SATA3 HDD
		- metadata special RAID1: 2 * 1TB SAS3 SSD (partition)
	- zssd: XFS: RAID1: 2 * 3TB SAS3 SSD (partition)
- **Network**: 25GbE (SFP28; Mellanox ConnectX-6 Dx)

### IslandFox

- **Locator**: Rack; Miniforum UM980 Pro
- **OS**: NixOS
- **CPU**: AMD Ryzen 9 PRO 8945HS
- **RAM**: 96GB, DDR5, 5600 MT/s
- **Storage**:
	- nix: XFS: RAID1: 2 * 2TB NVMe SSS
- **Network**: 25GbE (SFP28; Mellanox ConnectX-4 Lx USB4)

### IceFox

- **Locator**: OVH
- **OS**: NixOS
- **CPU**: Xeon D-2141I
- **RAM**: 32GB, DDR4, 2133 MT/s
- **Storage**:
	- nix: xfs: RAID1: 2 * 480GB SATA3 SSD
	- ztank: ZFS:
		- MIRROR: 2 * 8 TB SATA3 HDD
- **Network**: 1GbE (no traffic limit)

### RedFox

- **Locator**: Vultr
- **OS**: MikroTik RouterOS
- **CPU**: 1 vCPU "Intel high performance"
- **RAM**: 2 GB
- **Storage**: vdisk 50 GB NVMe SSD
- **Network**: >= 1GbE (max 3 TB traffic)

### Router

- **Locator**: Rack; 1U, white MikroTik CCR2004
- **OS**: MikroTik RouterOS
- **CPU**: 4 core ARM64 "AL32400"
- **RAM**: 4 GB
- **Storage**: 128 MB NAND
- **Network**:
	- LAN: 25 GbE (SFP28)
	- WAN: 10 GbE (SFP+)

### Router Backup

- **Locator**: Rack; 1U, black MikroTik RB5009
- **OS**: MikroTik RouterOS
- **CPU**: 4 core ARM64 "88F7040"
- **RAM**: 1 GB
- **Storage**: 1 GB NAND
- **Network**:
	- LAN: 10 GbE (SFP+)
	- WAN: 2.5 GbE (RJ45)

## Continuous deployment

Merging to `main` deploys. Two workflows do it:

- `deploy.yml`: NixOS hosts, on changes to `nix/` or the Go sources nix builds (`vpn/`, `packetfox/`). Each host pulls `main` and runs `nixos-rebuild switch`.
- `apply.yml`: everything else, on changes to `nix/`, `dns/`, `cdn/`, `mikrotik/` or `dashboard/` (and by hand from the Actions tab). It runs these in order and stops at the first failure:
  1. pushes the dashboard image, unless an image tagged with the git tree of `dashboard/` already exists,
  2. `dns/dns.py apply --yes`,
  3. `cdn/cdn.py apply --yes`,
  4. `mikrotik/configure.py`, which reads the ClouDNS DynamicURL keys and ACME zones and pulls the new dashboard image.

  All three reconcilers run on every push the workflow matches. They're idempotent, so this is a no-op where nothing changed. Runs are queued and never cancelled, so a run never stops halfway through the routers.

### Setup

Repository secrets (Settings → Actions → Secrets). Workflows on any branch pushed to this repo can read them, including Renovate's.

| Secret | Used by | What |
| --- | --- | --- |
| `EXT_GITHUB_TOKEN` | all | exists already (nix's GitHub rate limit) |
| `CLOUDNS_AUTH_ID`, `CLOUDNS_PASSWORD` | dns, mikrotik | a ClouDNS API user (not a sub-user, since `dns.py` creates zones). Give it its own API user and set its allowed IPs to the home WAN addresses. |
| `OVH_APPLICATION_KEY`, `OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY` | dns | an OVH application whose consumer key is limited to `GET /ip`, `GET /ip/*/reverse`, `GET /ip/*/reverse/*`, `POST /ip/*/reverse` and `DELETE /ip/*/reverse/*` |
| `FASTLY_API_KEY` | cdn | a Fastly automation token, scope `global`. It must cover the whole account, since `cdn.py` searches services and manages domains and TLS subscriptions. |
| `MIKROTIK_SSH_KEY` | mikrotik | private key of the router user `foxden-ci` (below) |
| `MIKROTIK_SOPS_AGE_KEY` | mikrotik | age identity (`AGE-SECRET-KEY-…`) that decrypts `mikrotik/secrets/` |

`OVH_ENDPOINT` is a variable rather than a secret and defaults to `ovh-us`.

The sops key: `age-keygen -o foxden-ci.age` prints its public key. Add the key as a recipient for `^mikrotik/secrets/` in `.sops.yaml`, then run `sops updatekeys mikrotik/secrets/*.yaml` and commit the result. Store the private key as `MIKROTIK_SOPS_AGE_KEY`, then delete `foxden-ci.age`.

The router user: on `router`, `router-backup` and `redfox` (users aren't managed by `configure.py`), add a user that may only log in from the runners. Those are the `forgejo-runner-container` hosts, which are the same subnets `nixpush` allows in `nix/modules/nixos/deploy/push.nix`:

```
/user/add name=foxden-ci group=full password=[:rndstr length=64] comment="Forgejo Actions, core apply.yml" address=10.6.11.0/24,fd2c:f4cb:63be:6::b00/120
/user/ssh-keys/add user=foxden-ci key="ssh-ed25519 AAAA… foxden-ci"
```

The generated password is thrown away. A user with an SSH key can't log in to SSH with a password, and the address list covers SSH, API and WinBox alike. Make the key with `ssh-keygen -t ed25519 -N '' -C foxden-ci -f foxden-ci` and store `foxden-ci` (the private half) as `MIKROTIK_SSH_KEY`. `configure.py` uses it the same way it uses your own admin login: over SSH it gives the temporary API user `foxden-core-configure` a random password, uses it for the run and disables it afterwards. The rsync of container files also goes over SSH.

The routers' SSH host keys are pinned in `mikrotik/known_hosts`. Update that file if a router is reinstalled.

## TODO: Not-yet automated update cycles

- Every GitHub release artifact download where upstream does not have a digest (likely big files, currently carvera-controller and njs/acme.js)
- ZFS Linux kernel lag-behind
- Kanidm version in nix
- Anything RouterOS

## Notes

- zfs must be mountpoint=legacy
- DO NOT use /var/run, always use /run, or the entire OS explodes
