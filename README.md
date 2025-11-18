# FoxDen core

This is the monorepo to control the FoxDen homelab pretty much in its entirety.

A from-zero setup of `router`, `router-backup` or `redfox` is currently impossible. Hence we keep regular backups of those devices around.

I am not sure whether I plan to instrument RouterOS enough to make this possible or not, especially since dynamic portions of RouterOS config, such as DynDNS keys, DNS entries and even firewall rules are already under management.

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

- **Locator**: Rack; Lenovo tiny mini-PC
- **OS**: NixOS
- **CPU**: AMD Ryzen 7 PRO 470GE
- **RAM**: 64GB, DDR4, 3200 MT/s
- **Storage**:
	- nix: XFS: RAID1: 2TB NVMe SSD + 2TB SATA3 SSD
- **Network**: 1GbE (RJ45)

### IceFox

- **Locator**: Hetzner
- **OS**: NixOS
- **CPU**: AMD Ryzen 9 3900
- **RAM**: 128GB, DDR4, 2666 MT/s
- **Storage**:
	- nix: xfs: RAID1: 2 * 1TB NVMe SSD
	- ztank: ZFS:
		- RAIDZ2: 10 * 14 TB SATA3 HDD
- **Network**: 1GbE (no traffic limit)

### RedFox

- **Locator**: Vultr
- **OS**: MikroTik RouterOS
- **CPU**: 1 vCPU "Intel high performance"
- **RAM**: 1 GB
- **Storage**: vdisk 25 GB NVMe SSD
- **Network**: >= 1GbE (max 2 TB traffic)

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

## Notes

zfs must be mountpoint=legacy

DO NOT use /var/run, always use /run, or the entire OS explodes
