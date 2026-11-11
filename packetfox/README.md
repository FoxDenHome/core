# PacketFox

PacketFox (`pfox`) captures packets on the routers, the UniFi APs and the NixOS hosts at once. It finds each packet at every point it passed, and shows the result in a Wireshark-like web UI at <https://pfox.foxden.network>. Only the Kanidm `superadmins` group can log in.

It answers questions like:

- **Where do these packets get dropped?** Was it the router's firewall, or somewhere between the router and the host?
- **What path does traffic take?** Which router and chain does it pass, where is it NATed, and which host netns does it reach?
- **How long does a hop take?** The router's own transit time is exact. Hops between devices are shown, but they include clock skew.

## How it fits together

```
                    pfox.foxden.network (islandfox, netns host-packetfox)
                  ┌───────────────────────────────────────────────────────┐
 browser ─OAuth──▶│ nginx + oauth2-proxy ─▶ pfox ─▶ sharkd (dissection)    │
                  │                        │  ▲                            │
                  └────────────────────────┼──┼────────────────────────────┘
          RouterOS API: mangle sniff-tzsp  │  │ TZSP/UDP 37008+ (one port per router and chain)
          ┌──────────────────────────────▶ router, router-backup
          │ SSH (pfox user, forced command pfox-agent → tcpdump in any netns)
          ├──────────────────────────────▶ bengalfox, islandfox, icefox
          │ SSH (UniFi device credentials → tcpdump)
          └──────────────────────────────▶ ap-backyard, ap-corridor-upper, ap-living-room
```

- **Routers.** The capture filter becomes mangle rules with `action=sniff-tzsp` in `prerouting` ("in") and `postrouting` ("out"). Each router and chain streams to its own UDP port, so pfox knows where every packet was seen. While a capture runs, pfox also adds:
  - an address list `pfox` with the filter's hosts;
  - `accept` rules for established matching connections, placed before the fasttrack rule, because fasttracked packets skip mangle. Connections that were already fasttracked before the capture started stay invisible until they end;
  - a `postrouting` `accept` rule that keeps the TZSP stream itself out of the capture.

  Every row pfox creates has the comment `pfox`. pfox removes them when a capture ends, when it stops, and when it starts (in case it crashed). `mikrotik/configure` leaves them alone. A router capture needs a host or port filter: pfox refuses to mirror all of a router's traffic.
- **NixOS hosts** (`foxDen.packetfox.agent`, on by default wherever push deploys are). The `pfox` user can only run `pfox-agent`, through a security wrapper with `CAP_NET_RAW`, `CAP_NET_ADMIN`, `CAP_SYS_ADMIN` and `CAP_SYS_PTRACE`. `pfox-agent` finds every network namespace on the host and runs tcpdump inside one of them, the way `nsenter` would:
  - the root netns: uplinks, bridges, macvtaps of VMs;
  - `/run/netns/*`: every foxDen host (`host-<name>`), so every service and OCI container, and the SR-IOV VFs moved into them;
  - any other netns a process is in, such as units with `PrivateNetwork=true` or containers a runtime set up itself. These are listed as `ns-<inode>`, labelled with the unit or container that holds them, and entered through `/proc/<pid>/ns/net`.

  Each interface is tagged with its kind (physical, `sriov-vf`, `sriov-pf`, macvlan, macvtap, veth, …). On SR-IOV hosts, VF traffic is switched inside the NIC and never reaches the PF, so capture the VF in the service's netns. The UI warns when you pick a PF, and "Suggest for targets" picks a service's own netns. Only tcpdump gets `CAP_NET_RAW` and `CAP_NET_ADMIN`; `CAP_SYS_ADMIN` (`setns`) and `CAP_SYS_PTRACE` (opening other processes' namespaces) stay with `pfox-agent`. Every argument is validated, and the BPF expression can't contain quotes or start with a dash.
- **UniFi APs** (hosts named `ap-*`). tcpdump runs over SSH with the controller's device credentials. The bridge (`br0`) sees all wireless clients.
- **Host keys** are checked against the SSHFP records in `nix/systems/x86_64-linux/landevices/sshfp/records`. There is no trust on first use.
- **Switches** are not captured. They forward in hardware, so tcpdump on a switch only sees its CPU's traffic. Port mirroring to a capture NIC could be added later.

Every capture point becomes one interface of a single pcapng file (`router|prerouting`, `bengalfox|host-immich|eth0`, …). The file opens as-is in Wireshark ("Download pcapng"). The UI's packet list, detail tree, hex view, display filters and colouring come from Wireshark's own `sharkd` working on that file.

## Journeys

pfox fingerprints every IP packet by what routers and NAT leave alone:

- the IP ID (IPv4) or flow label (IPv6);
- TCP sequence, ack, flags and window, UDP length, or ICMP type/code/sequence;
- the first 64 bytes of payload.

Addresses, ports, TTL and checksums are left out. Copies with the same fingerprint within 2s form a **journey**. Hops are ordered by TTL first, which works no matter how the clocks line up. Then the sender's own capture point goes first and the receiver's last. Ties after that go by timestamp.

| Verdict | Meaning |
|---|---|
| delivered | Seen at the capture point its (post-NAT) destination lives behind |
| consumed | Addressed to a router, which got it |
| dropped | A router saw it come in (`prerouting`) but never go out (`postrouting`): firewall, no route, or TTL |
| lost | Last seen somewhere, but never reached the capture point of its destination |
| in flight | Seen less than 2s ago during a live capture |
| seen | No capture point that could tell either way |

The **Insights** panel groups drops and losses by where they happen. Clicking a group filters the packet list to those journeys. The panel also shows per-hop latency (p50/p95).

Timestamps on hosts and APs come from their own (NTP-synced) clocks. Router packets are stamped when they arrive at pfox. So a router's in→out time is exact, and so is a host's NIC→netns time. Hops between devices include the skew between their clocks; the UI shows those in italics.

Linux hosts see TCP after GRO (receive) and before TSO (send), so one large packet there stands for several on the wire. pfox leaves the IP length out of TCP fingerprints, so the aggregate still matches its first segment. A later segment counts as delivered when the destination point saw a larger packet of the same flow covering its bytes. Retransmissions never get that credit.

## Setup

1. `nix/secrets/islandfox.yaml`:
   - `packetfox-ssh-key` is the private key whose public half is `nix/files/packetfox/pfox_ed25519.pub`.
   - `packetfox` is an env file to fill in with `sops nix/secrets/islandfox.yaml`:
     ```
     ROUTEROS_PASSWORD=...     # RouterOS user pfox
     UNIFI_SSH_USERNAME=...    # UniFi Network → Settings → System → Device Authentication
     UNIFI_SSH_PASSWORD=...
     ```
2. On both routers (users are set by hand):
   ```
   /user group add name=pfox policy=api,read,write,sniff
   /user add name=pfox group=pfox address=10.2.11.45/32,fd2c:f4cb:63be:2::b2d/128 password=...
   ```
3. Run `mikrotik/configure.py` once with this change, so later runs leave pfox's rows alone, and so the firewall lets pfox reach the hosts' and APs' SSH.

## Development

```sh
make            # bin/pfox, bin/pfox-agent
make test       # go vet + go test; SHARKD=/path/to/sharkd adds the end-to-end session test
./bin/pfox -config config.json
```

Nix runs the same tests in CI (`.forgejo/workflows/packetfox.yml`). The Go vendor hash lives in `vendor-hash.txt`. After changing dependencies, run `../maid/tools/auto-nix-hash packetfox/vendor-hash.txt './nix#nixosConfigurations.islandfox.pkgs.packetfox.goModules'` from the repo root. Renovate does this on its own bumps.

The device inventory comes from the flake (`nix build ./nix#packetfox.json`):

- the routers, from `routers.nix`;
- the agents, from every system with `foxDen.packetfox.agent.enable`;
- the APs;
- every `foxDen.hosts` host, for the host picker.
