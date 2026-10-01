# FoxDen VPN

A WireGuard client manager for macOS and Linux, plus a small self-service portal for registering devices.

- **`foxden-vpnd`** is the root daemon. It owns the device key, brings the tunnel up when away from home and down when at home, and keeps the endpoint fresh.
- **`foxden-vpn-tray`** is the menu bar / system tray applet: a native `NSStatusItem` on macOS and a StatusNotifierItem on KDE Plasma.
- **`foxden-vpn-portal`** runs on islandfox. Users log in with Kanidm and add, replace or remove their own devices.

## How it fits together

```
 laptop                                   islandfox                         routers
┌──────────────────────┐   Kanidm login  ┌───────────────────┐  RouterOS   ┌──────────────────┐
│ tray ──unix socket── │ ──────────────▶ │ foxden-vpn-portal │ ──API:8728─▶│ router (primary) │
│        foxden-vpnd   │                 └─────────┬─────────┘             │ router-backup    │
│          │     ▲     │                           │ Fastly API            │  wg-vpn peers =  │
│          │     │     │                           ▼                       │  the database    │
│          │     └─────┼──── GET blob ───── cdn.foxden.network             └────────▲─────────┘
│          └───────────┼──────────── WireGuard (vpn.foxden.network:13231) ──────────┘
└──────────────────────┘
```

**The routers' `wg-vpn` peer table is the only database.** A portal-managed peer is named `<user>-<device>` and carries the comment `vpn-portal owner=<user>`. Its addresses are its `allowed-address`.

**Provisioning goes through the CDN, not the portal.** For every peer, the portal publishes a blob to the `vpn_peers` Fastly dictionary at `https://cdn.foxden.network/vpn/peers/<sha256(pubkey)>`. The blob is a NaCl box from the `wg-vpn` server key to the device key; WireGuard keys are plain Curve25519 keys, so no extra key material is involved. It holds everything the client needs:

- its addresses
- the server key and port
- DNS servers and domains
- the per-VLAN prefixes and LAN resolvers

Only the device can open its blob, and only the holder of the `wg-vpn` key can have made it. The client pins that public key (`-server-key`).

### What keeps working when things are down

| Down | Effect |
|---|---|
| Kanidm | Nobody can register or change devices. Every existing device keeps connecting. |
| islandfox / the portal | Same as above. Peers live on the routers, blobs live on Fastly, and clients also cache their blob locally. Changes made on the router directly sync to router-backup and the CDN once the portal is back. |
| Fastly | Clients keep their cached configuration. Only never-provisioned devices are stuck. |
| router | router-backup has the same `wg-vpn` key and a mirrored peer table. |

Only changes need Kanidm. As an admin breakglass, you can still add a peer on the router by hand.

## Client behaviour

- **First start** generates a key in the state directory (`/var/lib/foxden-vpn`, or `/Library/Application Support/FoxDen VPN`). The tray then offers **Register This Device…**, which opens the portal with the device's name and public key filled in. **Show Public Key…** and **Copy Public Key** are there too. Until it is registered, the daemon checks for its blob every 30s. **Refresh Configuration** checks immediately, shows "Refreshing…" while it runs, and reports the result as a notification.
- **LAN or WAN.** The laptop counts as at home only when both of these hold:
  - it has an address in a FoxDen VLAN
  - that VLAN's own resolver (for example `10.2.0.53`) answers `vpn.foxden.network` with an internal address

  The query is bound to the physical interface and bypasses `/etc/hosts`, so a hotel that also uses `10.2.x.x` can't fool it. At home the tunnel is fully down. Detection reruns on every change of network attachment (polled every 2s) and every 30s.
- **Endpoint tracking.** `vpn.foxden.network` is re-resolved every 60s and on every network change. Internal answers are dropped: the tunnel's own split DNS returns those. If only internal answers come back, public resolvers are tried, and the last good endpoint is kept. IPv4 candidates come first. If a handshake fails for 20s while traffic is waiting, the client rotates to the next candidate and re-resolves.
- **Split tunnel** is the default. It routes only the VPN subnet and the enabled VLANs, over IPv4 and IPv6 (ULA and public prefixes), and sets per-domain DNS: `foxden.network` plus the reverse zones. It is on demand: there is no keepalive, so WireGuard only handshakes when traffic needs it. After `-idle-timeout` (5m) without traffic, the session is dropped completely, and the next packet brings it back.
- **Full tunnel** routes `0.0.0.0/0` and `::/0` and sends all DNS through the tunnel, with a 25s keepalive.
  - Linux uses wg-quick-style fwmark policy routing.
  - macOS uses /1 routes plus a host route for the endpoint via the physical gateway.
- **Networks.** Each VLAN can be toggled for split mode under **Networks**. All are on by default.
- **Backends.**
  - Linux: kernel WireGuard via netlink, falling back to embedded wireguard-go if the module is missing.
  - macOS: wireguard-go on a `utun`.
- **DNS.**
  - Linux: systemd-resolved, via `resolvectl` on the tunnel link.
  - macOS: `/etc/resolver/<domain>`. In full tunnel mode it also overrides `networksetup` DNS, saving the old values to disk so a crash gets undone on the next start.

`foxden-vpnd status` dumps the daemon state. `foxden-vpnd pubkey` prints the key.

**Updates:** the daemon reports a build ID, a hash of its executable. When the tray sees it change, it checks whether its own binary on disk changed too. If so, it re-executes itself, so after an install every running tray picks up the new version. Any updater, including a future self-updater, only has to replace the binaries and then restart the daemon. The tray re-executes through the path it was started from, so on Nix it follows the profile symlink to the new store path.

## Install

Linux (systemd; members of `wheel` may control the daemon):

```sh
sudo make install-linux
```

macOS, built on a Mac because the tray links AppKit (members of `admin` may control the daemon):

```sh
sudo make install-macos
```

Nix: `pkgs.foxden-vpn` (`nix/packages/foxden-vpn`) contains all three binaries.

## One-time server setup

1. **Fastly:** `terraform apply` in `terraform/`. This creates the `vpn_peers` dictionary and the VCL that serves it. Terraform only owns the dictionary; its items belong to the portal.
2. **RouterOS user**, on both `router` and `router-backup`. The password must be the same on both. `sensitive` is needed to read the `wg-vpn` private key for sealing blobs, and `address` restricts logins to the portal host.

   ```
   /user group add name=vpn-portal policy=api,read,write,sensitive
   /user add name=vpn-portal group=vpn-portal address=10.2.11.40/32,fd2c:f4cb:63be:2::b28/128 password=...
   ```

3. **Secrets:** add a `foxden-vpn-portal` entry to `nix/secrets/islandfox.yaml`, in EnvironmentFile format:

   ```
   ROUTEROS_PASSWORD=...
   FASTLY_API_TOKEN=...   # a token with global scope on the cdn.foxden.network service
   SESSION_SECRET=...     # any long random string; if unset, sessions reset on restart
   ```

4. Deploy islandfox. The portal is `portal.foxden.network` (host `portal` in `nix/systems/x86_64-linux/islandfox/auth.nix`, Kanidm client `portal`). Login is limited to Kanidm's `login-users` (option `oAuthGroup`).

### Existing peers

Peers created by hand (`fennec`, `capefox`, …) have no owner, so no one sees them in the portal. They still get provisioning blobs. To hand one to a user, set `name=<user>-<device> comment="vpn-portal owner=<user>"` on the primary router; the portal mirrors it to the backup.

New devices get the first free address in `10.100.10.0/24`. The IPv6 address embeds the IPv4 one: `10.100.10.4` becomes `fd2c:f4cb:63be::a64:a04`. Using an existing device name replaces that device's key and keeps its addresses, which is what a reinstalled laptop wants.

## Development

```sh
make test   # unit tests, including the portal against fake routers and a fake Fastly API
```

The Linux tunnel code has been exercised end to end in unprivileged network namespaces (`unshare -rnm`), against a real WireGuard peer. That covered:

- kernel and userspace backends
- split routes and on-demand handshakes over IPv4 and IPv6
- network toggles and the idle drop
- full tunnel policy routing
- LAN detection, disable and clean shutdown

The macOS code paths compile but have not been run on a Mac yet.

Note: `mikrotik/foxden-wireguard.conf` predates this and pins an old server key. The current `wg-vpn` key is `h+EFbAdOxcqVG1+hglSUam1AaDb2ly80bxBunYGvhWU=`.
