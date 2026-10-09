# FoxDen VPN

A WireGuard client manager for macOS and Linux, plus a small self-service portal for registering devices.

- **`foxden-vpnd`** is the root daemon. It owns the device key, brings the tunnel up when away from home and down when at home, and keeps the endpoint fresh.
- **`foxden-vpnd tray`** is the menu bar / system tray applet. It is the same binary as the daemon (`foxden-vpn-tray` is a link to it), so the two never drift apart. On macOS it is a native `NSStatusItem`, and on KDE Plasma a StatusNotifierItem. Its dialogs are native too. On Linux they are Kirigami windows run with Qt 6's `qml` tool, and folders are picked through the XDG desktop portal (KDE's file dialog on Plasma). Where those are missing, `kdialog` or `zenity` stand in.
- **`foxden-vpn-portal`** runs on islandfox. Users log in with Kanidm and add, replace or remove their own devices.
- **`foxden-vpn-edge`** runs on islandfox too. It publishes local ports of registered devices, like ngrok (see **Exposing local ports**).

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
- the per-VLAN prefixes and LAN resolvers, plus static networks such as `s2s` (the sites behind the routers' `wg-s2s` tunnel, 10.99.0.0/16)

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

- **First start** generates a key in the state directory (`/var/lib/foxden-vpn`, or `/Library/Application Support/FoxDen VPN`). The tray then offers **Log In and Register…**: you log in to the portal with Kanidm, pick which of your devices this is (or name a new one), and the device configures itself right away, without waiting for the CDN. Once registered, the tray offers:
  - **Register as a Different Device…**, to fix a misclick: the key moves to the device you pick, and the entry it came from is removed.
  - **Regenerate Key…**, which makes a new key and registers it as the same device. The old key keeps working until the portal has accepted the new one.

  The portal changes nothing until the device proves it holds the key. It redirects to a one-shot listener of the tray on `127.0.0.1` with a short-lived signed token and a challenge sealed to the key. The daemon opens the challenge and only then does the portal register the key, returning the device's sealed configuration. A link carrying someone else's key therefore cannot register it: the challenge lands on your machine, which cannot open it. **Show Public Key…** and **Copy Public Key** remain for registering by hand. Until a device is registered, the daemon checks for its blob every 30s. **Refresh Configuration** checks immediately, shows "Refreshing…" while it runs, and reports the result as a notification.
- **LAN or WAN.** The laptop counts as at home only when both of these hold:
  - it has an address in a FoxDen VLAN
  - that VLAN's own resolver (for example `10.2.0.53`) answers `vpn.foxden.network` with an internal address

  The query is bound to the physical interface and bypasses `/etc/hosts`, so a hotel that also uses `10.2.x.x` can't fool it. Detection reruns on every change of network attachment (polled every 2s) and every 30s.
- **At home the tunnel stays up.** The other VLANs, such as the BMCs on mgmt, are only reachable through it, so they are limited to registered devices. The VLAN you are plugged into is reached directly and never tunneled; the tray marks it "you are here". The VPN subnet is not tunneled at home either: the router already routes it, and tunneling it would send replies to other VPN clients into the tunnel with a LAN source address, which the router drops. At home the tunnel always runs as split, even with Full Tunnel selected, and uses the internal endpoint the home resolver returned (`10.2.1.1`). That endpoint may lie in a tunneled VLAN, for example when you are on mgmt; the tunnel's own packets bypass the tunnel either way.
- **Endpoint tracking.** Away from home, `vpn.foxden.network` is re-resolved every 60s and on every network change. Internal answers are dropped: the tunnel's own split DNS returns those. If only internal answers come back, public resolvers are tried, and the last good endpoint is kept. IPv4 candidates come first. If a handshake fails for 20s while traffic is waiting, the client rotates to the next candidate and re-resolves.
- **Split tunnel** is the default. It routes only the VPN subnet and the enabled VLANs, over IPv4 and IPv6 (ULA and public prefixes), and sets per-domain DNS: `foxden.network` plus the reverse zones. It is on demand: there is no keepalive, so WireGuard only handshakes when traffic needs it. After `-idle-timeout` (5m) without traffic, the session is dropped completely, and the next packet brings it back.
- **Full tunnel** routes `0.0.0.0/0` and `::/0` and sends all DNS through the tunnel, with a 25s keepalive.
  - Linux uses wg-quick-style fwmark policy routing (split mode does too, so the tunnel never carries its own packets).
  - macOS uses /1 routes plus a host route for the endpoint via the physical gateway. Split mode adds the same host route whenever the endpoint is inside a tunneled prefix.
- **Networks.** Each VLAN, and `s2s`, can be toggled for split mode under **Networks**. All are on by default.
- **Backends.**
  - Linux: kernel WireGuard via netlink, falling back to embedded wireguard-go if the module is missing.
  - macOS: wireguard-go on a `utun`.
- **DNS.**
  - Linux: systemd-resolved, via `resolvectl` on the tunnel link.
  - macOS: `/etc/resolver/<domain>`. In full tunnel mode it also overrides `networksetup` DNS, saving the old values to disk so a crash gets undone on the next start.

`foxden-vpnd status` dumps the daemon state. `foxden-vpnd pubkey` prints the key.

**Kerberos:** once registered, the tray keeps a Kerberos ticket for the device's owner (`user@FOXDEN.NETWORK`) in the desktop session's default credential cache, so SMB works without a password: Dolphin/gvfs `smb://nas.foxden.network` or `mount.cifs -o sec=krb5` on Linux, Finder's **Connect to Server** or `mount_smbfs` on macOS.
- **How the ticket is obtained:** PKINIT. The tray has its own key in `~/.local/share/foxden-vpn/`. The daemon proves the device to the portal with its WireGuard key, using the same sealed challenge as enrollment, and the portal signs a 24h client certificate for the owner the router has on record. `kinit` then runs with that certificate.
- **Revocation:** removing or replacing a device in the portal stops new certificates, and the last one expires within a day.
- **Renewal:** tickets renew every 18h, and "Get New Ticket" in the **Kerberos (SMB)** submenu renews immediately.
- **Requirements:** `kinit` from krb5 on Linux. macOS uses its own Heimdal `/usr/bin/kinit` (never one from Homebrew or Nix, whose cache the SMB client would not read), with an RSA session key. The tray sets the per-user default `org.h5l.hx509 AllowHX509Validation`, because otherwise Apple's Heimdal checks the KDC's certificate only against the keychain's CAs and ignores the PKINIT CA it is given. The KDC is found through the `_kerberos` SRV records, so the device needs the VPN or the LAN.
- **Trust setup:** the KDC (`services/auth/kerberos.nix`) trusts the PKINIT CA in `nix/files/kerberos/pkinit-ca.pem`. The CA key lives in sops for the portal only. The KDC's own certificate is `pkinit-kdc.pem`, with its key in sops for the KDC.

**NAS shares:** the **NAS Shares** submenu has a toggle for each SMB share the device's owner may use: the public `share`, plus their own home share. The list comes from the NAS's ksmbd config, through the portal, inside the device's sealed configuration.
- **Toggling:** the first toggle asks for a folder. If the folder isn't empty, the share goes into a subfolder named after it. After that it's an on/off toggle, and **Change Folder** moves a share.
- **Re-mounting:** enabled shares are mounted again at login, every minute while missing, and after each new Kerberos ticket. The folders and toggles live in `~/.config/foxden-vpn/mounts.json` (`~/Library/Application Support/foxden-vpn/mounts.json` on macOS).
- **How it mounts on macOS:** the tray runs `mount_smbfs -N //<user>@<host>/<share>` itself, as you: macOS lets users mount onto folders they own, and the SMB client only sees your own Kerberos ticket. There is no SMB Direct; macOS uses multichannel by itself.
- **How it mounts on Linux:** the daemon mounts as root with `sec=krb5,cruid=<you>`, so the kernel's `cifs.upcall` uses your Kerberos ticket. You need `cifs-utils`.
  - It mounts only onto an empty folder you own, without symlinks, and identifies you by the control socket's peer credentials.
  - It only unmounts CIFS mounts made for your uid.
  - Mounts are always `nosuid,nodev`, and home shares get private modes.
- **Mount options on Linux, best first:** SMB 3.1.1, then
  1. SMB Direct with multichannel
  2. SMB Direct
  3. TCP with multichannel
  4. plain TCP

  SMB Direct is only tried at home, with an `ACTIVE` RDMA port, against the NAS's RDMA host. The menu shows which transport won.

**Services:** besides the VPN, the daemon can install and keep up to date extra FoxDen services, chosen per device under **Services** in the tray. The choice is device state, kept in the daemon's settings. A service starts out unmanaged and is not touched, even if it was installed by hand; ticking it installs or takes it over, and unticking it removes it. Every download is pinned by sha256 in `internal/services`, and nothing unpinned is ever installed. For now the pins are updated by hand; later they will be replaced by signed release manifests.

- **shutdownd** (Linux): lets HomeAssistant shut the machine down on request. It uses the same paths as shutdownd's own `install.sh`, so a manual install is taken over in place. Its private key (`/etc/shutdownd/cert.pem`) is kept at 0600, and removal keeps `/etc/shutdownd`, so the machine keeps its identity. The caller's certificate is pinned in `internal/services/shutdownd-server.pem`; while that file is empty, an existing `/etc/shutdownd/server.pem` is used, and installing on a machine without one is refused.

**Exposing local ports:** `foxden-vpnd expose` publishes a port of this machine until you stop it. Being residential, it offers two things:

```sh
foxden-vpnd expose http 3000             # https://<random>.tunnel.f0x.es -> localhost:3000
foxden-vpnd expose tcp 192.168.1.5:22    # tcp://tunnel.f0x.es:<random port> -> 192.168.1.5:22
foxden-vpnd expose -name demo http 8080  # ask for https://demo.tunnel.f0x.es
```

- **http:** the edge terminates TLS with a `*.tunnel.f0x.es` certificate and passes the plain bytes on, so the port normally serves HTTP/1.1. Plain HTTP is redirected to HTTPS.
- **tcp:** a random port in 30000-30199, passed through as is.
- **How it connects:** the edge's control service is not reachable from the internet, so the VPN has to be up. The device's configuration says where it is: port 4443 on the edge's LAN addresses, reached through the tunnel like the rest of lan, or directly at home. The CLI connects over QUIC and carries every public connection as a stream of that one connection, so the routers never change per tunnel. Each line it prints is one incoming connection, with the client's real address.
- **Who may:** the CLI runs as you and connects the streams itself; the daemon only vouches for the device. It proves the device to the portal with the WireGuard key, as for Kerberos, and hands the CLI a ticket that is good for 2 minutes. The edge asks the portal whose ticket it is. Up to 10 tunnels per device.
- **Lifetime:** a tunnel lasts as long as the CLI. If the connection drops, the CLI reconnects and gets the same name or port back: a closed tunnel's address stays reserved for its device for 10 minutes. Removing or disabling the device closes its tunnels within 5 minutes.
- **From the tray:** **Expose Local Port** lists the ports listening on this machine, with the owning process where it is one of yours (`/proc` on Linux, `lsof` on macOS). Ports in the kernel's ephemeral range are left out, because they belong to helpers such as an IDE's. Clicking one, or **Other Target…** for any port or `host:port`, opens a form to choose HTTPS or TCP. For HTTPS you can give a name; for TCP, a public port picked from the edge's range. Either is random if left at its default. Well-known non-HTTP ports such as 22 start out as TCP. The form is a Kirigami window on Linux and an `NSAlert` on macOS. The address is copied to the clipboard once the tunnel is up. Each published port then gets its own menu item below, showing where it forwards to, its state, its connection counts and the last client, with **Copy Address**, **Open in Browser** and **Disconnect**. The tunnels run in the tray, so quitting it closes them. When the tray restarts into a new version, it hands them over and they come back under the same addresses.

**Updates:** the tray is the daemon's own binary, and the two stay in lock step. The daemon reports its build ID (a hash of its executable) and where its executable is, resolved through symlinks. Whenever the tray's build differs from the daemon's, the tray re-executes that file as `tray`, carrying its exposed ports over. A change to tray code alone counts too, since it changes the shared binary. It waits until the file on disk hashes to the daemon's build, so it never starts a half-written binary or one the daemon has not been restarted into. Any updater, including a future self-updater, only has to replace the binary and then restart the daemon. On Nix the reported path is the new store path.

## Install

Linux (systemd; members of `wheel` may control the daemon):

```sh
sudo make install-linux
```

macOS, built on a Mac because the tray links AppKit (members of `admin` may control the daemon). The one binary lives in `/Applications/FoxDen VPN.app`, where the tray has to run to stay out of the Dock. The daemon runs from there too, and `/usr/local/bin/foxden-vpnd` links to it:

```sh
sudo make install-macos
```

Nix: `pkgs.foxden-vpn` (`nix/packages/foxden-vpn`) contains `foxden-vpnd` (daemon and tray, with `foxden-vpn-tray` linking to it), `foxden-vpn-portal` and `foxden-vpn-edge`.

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

### Expose edge

`foxden-vpn-edge` runs on islandfox as host `tunnel` (`tunnel.f0x.es`, 10.2.11.43; `nix/modules/nixos/services/auth/vpn-edge.nix`).

- **Routing:** foxIngress sends `tunnel.f0x.es` and `_.tunnel.f0x.es` (every name below it) to the edge's PROXY ports 81/444. The routers forward TCP 30000-30199 to it directly. `*.tunnel.f0x.es` is a CNAME to `tunnel.f0x.es`, whose address dyndns keeps current. On the LAN, the routers answer `tunnel.f0x.es` and every name below it with the edge's internal addresses (`match-subdomain`, `INTERNAL_SUBDOMAIN_HOSTS` in `mikrotik/configure/dns.py`), not the prefix-translated public IPv6 address.
- **Control service:** UDP port 4443 (QUIC) is neither forwarded nor behind foxIngress. VPN clients reach it like any LAN host. The portal puts its location into every device's configuration, along with the TCP port range, which the tray offers in its form.
- **Certificate:** the wildcard needs DNS-01. `_acme-challenge.tunnel.f0x.es` is a dynamic TXT record at dns.he.net, and lego's `hurricane` provider updates it with that record's DDNS key. The edge picks up renewals by itself.

To set it up:

1. `tofu apply` in `terraform/`, which creates the dynamic TXT record and its key.
2. In the dns.he.net web UI, add the CNAME `*.tunnel.f0x.es` → `tunnel.f0x.es`. Terraform skips it: its provider rejects wildcard names.
3. Add a `foxden-vpn-edge-acme` entry to `nix/secrets/islandfox.yaml` with that key, taken from `tofu output -json he_dynamic_keys`:

   ```
   HURRICANE_TOKENS=tunnel.f0x.es:<key of _acme-challenge.tunnel.f0x.es>
   ```

4. Run `mikrotik/configure.py`, which pushes the port forwards, foxIngress and dyndns. The dyndns script skips TXT records.
5. Deploy islandfox.

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
