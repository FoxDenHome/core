# foxden-dashboard

A small rack dashboard: a wireframe view of the rack on the left, and details for the selected device on the right. Each device shows its live front panel: drive bays with SMART state, switch ports, PDU outlets with power, and UPS meters. It's a single static Go binary with the UI embedded, meant to run as a container on the routers.

It polls devices directly and has no Prometheus dependency, so it keeps working when the monitoring host is down:

| Source | Used by |
|---|---|
| SNMP v2c | UPS, ATS, switches, routers, tape library status, NVR sensors and disk I/O |
| node_exporter (`:9100`) | servers: load, memory, ZFS pools, disk inventory; time servers: chrony, gpsd and ptp4l via the textfile collector |
| smartctl_exporter (`:9633`) | disk health, on by default wherever node-exporter is |
| UniFi Network API (local console) | PDU per-outlet power and switch PoE (their own SNMP has neither) |
| UniFi Protect API (on the NVR) | NVR disks, RAID, recording and cameras |
| Telnet (`:23`, FLMON monitor) | tape library drives, magazines, robotics counters and error log |

## Running

```sh
make                    # bin/foxden-dashboard
make test
SNMP_COMMUNITY=... UNIFI_API_KEY=... ./bin/foxden-dashboard -config config.json
./bin/foxden-dashboard -modules                 # list modules
./bin/foxden-dashboard -config config.json -check   # validate layout
```

`${VAR}` in the config is expanded from the environment, so secrets stay out of the file.

UniFi access never goes through the cloud. The module uses `$UNIFI_API_KEY` if it is set. Otherwise it logs in to the local console with `$UNIFI_USERNAME`/`$UNIFI_PASSWORD`, which works on any UniFi OS version. A local-only admin with the Network "View Only" role is enough.

## Config

The config places **module instances** in the rack. A module is a kind of hardware. Its preset knows the faceplate and how to poll it. An instance says where the device sits and how to reach it. To move a device, change its `u`. To add a second unit of the same model, add another entry with the same `module`.

```jsonc
{
  "title": "FoxDen Rack",
  "units": 23,                   // rack height
  "interval": "15s",
  "snmp": { "community": "${SNMP_COMMUNITY}" },
  "devices": [
    {
      "id": "bengalfox",
      "module": "supermicro-cse826",
      "u": 16,                   // lowest U occupied, counted from the bottom
      "address": "bengalfox.foxden.network"
      // "height": 2,            // defaults to the module's height
      // "options": { ... }      // module-specific, overrides the preset
    },
    {
      "id": "shelf", "module": "shelf", "u": 12, "height": 2,
      "children": [              // devices sitting side by side on the shelf
        { "id": "islandfox", "module": "mini-pc", "address": "...", "width": 2 },
        { "id": "ntpi", "module": "raspberry-pi", "address": "..." }
      ]
    }
  ]
}
```

The loader rejects overlapping devices, devices outside the rack, duplicate ids and unknown option keys.

### Drive bays

`server`-based modules take `bays.slots`. It lists one entry per bay, row by row from the top left as seen from the front. Each entry says which disk belongs in that bay:

- `phy:N`: the disk on SAS expander phy N, read from the kernel's by-path name. This is the CSE-826 default (`phy:0` … `phy:11`).
- `serial:XYZ` or `wwn:0x…`: a specific disk.
- `""`: a bay that is never populated.

If a bay lights up in the wrong place when you check with the identify LED, reorder the list:

```json
"options": { "bays": { "slots": ["phy:3","phy:2","phy:1","phy:0", "..."] } }
```

Disks that don't sit behind a front bay, like NVMe drives, boot disks and every disk of a server without `bays`, are listed as **Internal disks** in the details panel. They count toward the device's status but aren't drawn on the rack.

Most SMART error counters flag at any non-zero value. CRC errors, reallocated sectors, SAS grown defects and NVMe media errors are lifetime counts where an old value is normal, so these only warn when they **increase** while the dashboard is running. The baseline is kept in memory, so after a restart the dashboard takes the current values as the new baseline.

### Remote sites

Machines outside the rack go under `remote`. They're drawn below the rack, grouped by site, and use the same modules:

```json
"remote": [
  { "name": "OVH", "devices": [ { "id": "icefox", "module": "server", "address": "icefox.foxden.network" } ] }
]
```

### Ports

Switch modules take `groups`, and `ports` lists interface names (`ifName`) with brace ranges. RouterOS ports renamed to their role are mapped like this:

```json
"groups": [
  { "label": "SFP+",  "ports": "sfp{1..11},wan",  "labels": "{1..12}", "rows": 2 },
  { "label": "SFP28", "ports": "vlan-mgmt,sfpx2", "labels": "1,2",     "rows": 2 }
]
```

`#N` matches by ifIndex instead.

### PoE

The UniFi switches' SNMP agents don't report per-port PoE, so a switch module reads it from the controller when given a `unifi` block (same fields and credentials as the PDU). The controller's port N is the Nth port across all `groups`:

```json
"options": { "unifi": { "controller": "https://unifi.foxden.network", "mac": "74:fa:29:8a:c2:c3" } }
```

### Power feeds

A device that can't meter itself can borrow readings from whatever feeds it. `power` lists PDU outlets or PoE ports by device id and slot id (outlet number, or the port's `ifName`):

```json
{ "id": "bengalfox", "power": [
  { "device": "pdu-rack", "slot": "3", "label": "PSU 1" },
  { "device": "pdu-rack", "slot": "4", "label": "PSU 2" }
] }
{ "id": "ntpi", "power": [ { "device": "switch-rack", "slot": "0/12", "label": "PoE" } ] }
```

The device gets a **Power** section with each feed and the total, and its draw is added to its summary. If one of several feeds is off, the device turns yellow, since it's running without its spare. The feeding outlet or port in turn shows what it powers. Readings are merged when the UI fetches the rack, so they're always the feeding device's latest.

### Transfer switch

The ATS is mounted at the back and all it adds is which feed is live, so it doesn't get a slot. Attach it to the UPS it feeds instead, and it shows up as A/B indicators on the UPS:

```json
"options": { "ats": { "model": "cyberpower", "address": "ats-rack.foxden.network" } }
```

### Time servers

A `server` whose node_exporter has `chrony_*` metrics gets **Time sync** and **Time sources** sections, and with `gpsd_*` metrics a **GNSS** section plus per-satellite signal meters. The faceplate shows GPS, sync and PPS LEDs. ntpi writes these with `chrony-stats.py` and `gpsd-stats.py` ([FoxDen/ntpi](https://git.foxden.network/FoxDen/ntpi)). Refclocks are judged by reach rather than chrony's state, since a `noselect` refclock always shows as unreachable.

### Tape library

`ibm-ts3100` reads the global status over SNMP and everything else from the library's FLMON telnet monitor (`stat`, `inv`, `fst`, `rets`, `adir`, `dra`, `edp`), which needs no login. The faceplate shows the magazines on the left (the left one above the mail slot, the right one at full height), the LEDs centered and the drives on the right. Magazines show how full they are and list their cartridges in the details. `magazines` sets the slots per magazine (default `[11, 12]`).

The monitor serves one session at a time, and both routers poll it. A poll that finds it busy retries once, then shows the last data for up to 5 minutes. Retry counters and new error log entries only warn when they appear while the dashboard is running.

### NVR

`unifi-unvr` reads disks (health, temperature, power-on hours, bad sectors), RAID, recording and cameras from the Protect API on the NVR itself, at `https://<address>`. It logs in with `$UNIFI_USERNAME`/`$UNIFI_PASSWORD`, so the same local view-only user has to exist on the NVR, or it uses an API key from `$NVR_API_KEY`. SNMP adds load, memory, temperatures, fans, voltages and per-disk I/O rates.

## Adding a module

Modules live in `internal/modules/`, and each calls `register(Spec{...})` from `init()`.

- **New model of existing hardware.** Register a preset that calls an existing constructor with different defaults. For example, a new switch is `newSwitch(switchOptions{Groups: ...})`, and a new chassis is `newServer(serverOptions{Bays: ...})`.
- **New kind of hardware.** Implement `Driver`:
  - `Skeleton()` returns the faceplate with every slot `unknown`.
  - `Poll(ctx)` returns a `rack.State` that fills the faceplate groups (`bay`, `port`, `outlet`, `meter`, `led`) and the detail sections.

The UI is generic over those group kinds, so a new module needs no frontend work.

## Container

`Dockerfile` builds a `FROM scratch` image (about 8 MB) that reads `/config/config.json`, like foxIngress. `.forgejo/workflows/dashboard.yml` tests it and, on `main`, pushes `git.foxden.network/foxden/dashboard:latest` for amd64 and arm64.

`mikrotik/configure.py` runs it on `router` and `router-backup` at `172.17.2.2:8080`. It copies `config.json` to `/dashboard` on each router and passes the environment from `mikrotik/secrets/dashboard.yaml`, a sops file holding a flat map of variables:

```sh
sops mikrotik/secrets/dashboard.yaml   # from the repo root
```

```yaml
SNMP_COMMUNITY: ...
UNIFI_USERNAME: ...
UNIFI_PASSWORD: ...
```

The values end up in a `/container/envs` list named `dashboard`. Changing them restarts the container on the next `configure.py` run.

### HTTPS

With a `tls` block the dashboard also serves HTTPS, plus a redirect from plain HTTP:

```json
"tls": {
  "domain": "status.foxden.network", "email": "ssl@foxden.network",
  "cache_dir": "/data", "dns_key": "${ACME_DNS_KEY}",
  "listen": ":443", "http_listen": ":80"
}
```

The certificate comes from Let's Encrypt over DNS-01. The dashboard writes the challenge to `_acme-challenge.<domain>`, a dns.he.net dynamic TXT record, using that record's DDNS key. So every router gets its own certificate, whether or not it is the VRRP master. `configure.py` reads the key from the tofu output `he_dynamic_keys`, like dyndns does, and passes it as `ACME_DNS_KEY`. While `dns_key` is empty, HTTPS stays off, so the same config runs locally. The account key and certificate live in `/data` (`/dashboard-data` on the router) and are renewed 30 days before expiry.

`status.foxden.network` is set up in `nix/systems/x86_64-linux/landevices/status.nix`. From outside, it is a dyndns record that `router` keeps up to date. IPv4 goes through `router`'s foxIngress. For IPv6, the dyndns script adds the container's /120 to the Ingress PT ranges, so it maps straight to the container's ULA. Inside, the name resolves to the container addresses (`172.17.2.2`, `fd2c:f4cb:63be::ac11:202`), which the client's gateway routes to its own dashboard.
