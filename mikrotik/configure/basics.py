from collections.abc import Callable
from dataclasses import dataclass, field
from ipaddress import ip_interface, ip_network
from json import load as json_load
from json import loads as json_loads
from subprocess import check_output
from typing import Any

from configure.firewall import _sync_firewall_table
from configure.foxmail import CONTAINER as FOXMAIL_CONTAINER
from configure.util import (
    CONTAINER_HOST,
    NIX_DIR,
    ROUTERS,
    MTikFirewallRule,
    MTikRouter,
    format_mtik_bool,
    format_weird_mtik_ip,
    mtik_path,
    parse_mtik_bool,
)

# Everything a router needs besides users, passwords, WireGuard keys/peers
# and certificates, so a reset router can be brought back with configure.py.
# The addressing plan (VLANs, VIPs, router addresses) comes from nix.

SECRETS_PATH = mtik_path("secrets/dashboard.yaml")

TRUE = format_mtik_bool(True)
FALSE = format_mtik_bool(False)

AS_NUMBER = "207618"
ULA_RANGE = "fd2c:f4cb:63be::/60"
TIME_ZONE = "America/Los_Angeles"
WAN_ONLINE_SCRIPT = "/system/script/run wan-online-adjust\r\n"

REDFOX_WAN = "45.76.246.55/23"
REDFOX_WAN_GATEWAY = "45.76.246.1"
REDFOX_WAN6 = "2001:19f0:8000:1897:5400:5ff:feec:cf59/64"
REDFOX_S2S = "10.99.10.1/16"
REDFOX_S2S6 = "fd2c:f4cb:63be::a63:a01/112"
REDFOX_CUSTOMER6 = "2a0e:7d44:f069:800::/53"
VULTR_AS = "64515"
VULTR_PREFIXES6 = ["2a0e:7d44:f069::/48", "2a0e:7d44:f000::/40"]
NTP_POOL = [{"address": f"{i}.pool.ntp.org"} for i in range(4)]
# Valueless flag, the API doesn't read it back as "true"
ROUTE_CREATE_ONLY = frozenset({"blackhole"})


@dataclass(frozen=True, kw_only=True)
class MTikTable:
    path: str
    # Attributes identifying a row, only sent when adding it
    key: tuple[str, ...]
    rows: list[dict[str, str]]
    # Only sent when adding, as scripts change them at runtime or they read back differently
    create_only: frozenset[str] = frozenset()
    # Which unlisted rows get removed, None leaves them all alone
    prune: Callable[[dict[str, str]], bool] | None = None
    # Ports and default entries always exist, those can only be updated
    can_add: bool = True


@dataclass(frozen=True, kw_only=True)
class MTikSettings:
    path: str
    attribs: dict[str, str]


@dataclass(kw_only=True)
class MTikBasics:
    config: list[MTikTable | MTikSettings] = field(default_factory=list)
    # Keyed by /ip(v6)/firewall/<table>
    firewall: dict[str, list[MTikFirewallRule]] = field(default_factory=dict)

    def table(
        self, path: str, key: tuple[str, ...], rows: list[dict[str, str]], **kwargs: Any
    ) -> None:
        self.config.append(MTikTable(path=path, key=key, rows=rows, **kwargs))

    def settings(self, path: str, **attribs: str) -> None:
        self.config.append(MTikSettings(path=path, attribs=attribs))


def _prune_all(_: dict[str, str]) -> bool:
    return True


def _not_veth(row: dict[str, str]) -> bool:
    # containers.py owns everything on the container veths
    return not row.get("interface", "").startswith("veth-")


def _in_lists(*lists: str) -> Callable[[dict[str, str]], bool]:
    return lambda row: row.get("list") in lists


def _is_system_row(row: dict[str, str]) -> bool:
    return any(
        parse_mtik_bool(row.get(flag, FALSE))
        for flag in ("dynamic", "builtin", "default")
    )


def _same(current: str, wanted: str) -> bool:
    # RouterOS may reorder list values
    return current == wanted or sorted(current.split(",")) == sorted(wanted.split(","))


def _ip(address: str) -> str:
    return str(ip_interface(address).ip)


def _host(address: str) -> str:
    return format_weird_mtik_ip(_ip(address))


def _is_ipv4(address: str) -> bool:
    return ip_interface(address).version == 4


def _router_s2s(cfg: dict[str, Any]) -> str:
    # Its own s2s address, not the /32 the primary also holds
    return next(
        a["address"]
        for a in cfg["addresses"]
        if a["interface"] == "wg-s2s"
        and _is_ipv4(a["address"])
        and ip_interface(a["address"]).network.prefixlen < 32
    )


def _sync_table(
    api: Any, table: MTikTable, matched: set[str], seen: dict[str, set[str]]
) -> None:
    resource = api.get_resource(table.path)
    rows = resource.get()
    # Only the rows from before syncing, not those added by an earlier table of the path
    seen.setdefault(table.path, {row["id"] for row in rows})
    deployed = [
        row
        for row in rows
        if not parse_mtik_bool(row.get("dynamic", FALSE)) and row["id"] not in matched
    ]
    for wanted in table.rows:
        match = next(
            (
                row
                for row in deployed
                if all(_same(row.get(k, ""), wanted[k]) for k in table.key)
            ),
            None,
        )
        if match is None:
            if not table.can_add:
                print(
                    f"### WARNING: No {table.path} entry",
                    {k: wanted[k] for k in table.key},
                )
                continue
            print(f"### Adding {table.path} entry", wanted)
            resource.add(**wanted)
            continue
        deployed.remove(match)
        matched.add(match["id"])
        changes = {
            k: v
            for k, v in wanted.items()
            if k not in table.key
            and k not in table.create_only
            # Flags like ntp-none only read back when set
            and not _same(match.get(k, FALSE if v == FALSE else ""), v)
        }
        if changes:
            print(
                f"### Updating {table.path} entry",
                {k: wanted[k] for k in table.key},
                {k: (match.get(k, ""), v) for k, v in changes.items()},
            )
            resource.set(id=match["id"], **changes)


def _prune_table(api: Any, table: MTikTable, matched: set[str], seen: set[str]) -> None:
    if table.prune is None:
        return
    resource = api.get_resource(table.path)
    for row in resource.get():
        # Rows not seen before syncing were just added
        if row["id"] in matched or row["id"] not in seen:
            continue
        if _is_system_row(row) or not table.prune(row):
            continue
        print(f"### Removing stray {table.path} entry", row)
        resource.remove(id=row["id"])


def _sync_settings(api: Any, settings: MTikSettings) -> None:
    resource = api.get_resource(settings.path)
    current = resource.get()[0]
    changes = {
        k: v for k, v in settings.attribs.items() if not _same(current.get(k, ""), v)
    }
    if changes:
        print(f"### Updating {settings.path}", changes)
        resource.set(**changes)


def refresh_basics_router(basics: MTikBasics, router: MTikRouter) -> None:
    print(f"## {router.host}")
    api = router.connection().get_api()

    # Paths can be split over several tables, rows matched by any of them stay
    matched: dict[str, set[str]] = {}
    seen: dict[str, set[str]] = {}
    for item in basics.config:
        if isinstance(item, MTikSettings):
            _sync_settings(api, item)
        else:
            _sync_table(api, item, matched.setdefault(item.path, set()), seen)
    # Backwards, so references (list members, addresses, ...) go before what they reference
    for item in reversed(basics.config):
        if isinstance(item, MTikTable):
            _prune_table(api, item, matched[item.path], seen[item.path])

    for path, rules in basics.firewall.items():
        resource = api.get_resource(path)
        _sync_firewall_table(resource, resource.get(dynamic=FALSE), rules)


def _ethernet(default_name: str, name: str, **attribs: str) -> dict[str, str]:
    return {"default-name": default_name, "name": name, **attribs}


# Physical ports per board, renamed so the rest of the config is board independent
FLOW_CONTROL = {"rx-flow-control": "on", "tx-flow-control": "on"}
ETHERNET: dict[str, list[dict[str, str]]] = {
    # CCR2004-1G-12S+2XS
    "router": [
        _ethernet("ether1", "oob", comment="eth1", l2mtu="1514", **FLOW_CONTROL),
        _ethernet(
            "sfp28-1",
            "vlan-mgmt",
            mtu="9000",
            l2mtu="9092",
            **{"auto-negotiation": FALSE, "fec-mode": "fec91"},
            **FLOW_CONTROL,
        ),
        _ethernet(
            "sfp28-2",
            "sfpx2",
            disabled=TRUE,
            **{"auto-negotiation": FALSE, "fec-mode": "fec74"},
            **FLOW_CONTROL,
        ),
        *(
            _ethernet(f"sfp-sfpplus{i}", f"sfp{i}", disabled=TRUE, **FLOW_CONTROL)
            for i in range(1, 12)
        ),
        _ethernet("sfp-sfpplus12", "wan", comment="sfp1", **FLOW_CONTROL),
    ],
    # RB5009UG+S+
    "router-backup": [
        _ethernet(
            "ether1",
            "wan",
            comment="eth1",
            advertise="1G-baseT-full,2.5G-baseT",
            l2mtu="1514",
            **FLOW_CONTROL,
        ),
        *(
            _ethernet(
                f"ether{i}", f"eth{i}", disabled=TRUE, l2mtu="1514", **FLOW_CONTROL
            )
            for i in range(2, 8)
        ),
        _ethernet("ether8", "oob", comment="eth8", l2mtu="1514", **FLOW_CONTROL),
        _ethernet(
            "sfp-sfpplus1",
            "vlan-mgmt",
            comment="sfp1",
            mtu="9000",
            l2mtu="9092",
            **FLOW_CONTROL,
        ),
    ],
    # CHR on Vultr
    "redfox": [_ethernet("ether1", "wan")],
}

# The out-of-band port, for a laptop plugged in when everything else is broken
OOB_NETWORK = "192.168.88.0/24"
OOB_POOL = "192.168.88.100-192.168.88.200"
OOB_ADDRESS = {"router": "192.168.88.1/24", "router-backup": "192.168.88.100/24"}
TMPFS_SIZE = {"router": "256000000", "router-backup": "128000000", "redfox": "16000000"}


def _wireguard(name: str, port: int) -> dict[str, str]:
    # Keys and peers are set by hand (and by the VPN portal for wg-vpn)
    return {"name": name, "listen-port": str(port), "mtu": "1280"}


def _bgp_connection(name: str, **attribs: str) -> dict[str, str]:
    return {
        "name": name,
        "instance": "bgp-instance-1",
        "connect": TRUE,
        "listen": TRUE,
        "multihop": TRUE,
        "output.default-originate": "never",
        "routing-table": "main",
        **attribs,
    }


def _add_common(basics: MTikBasics, name: str) -> None:
    basics.table(
        "/interface/ethernet", ("default-name",), ETHERNET[name], can_add=False
    )
    basics.table(
        "/disk",
        ("slot",),
        [
            {
                "slot": "tmpfs-scratch",
                "type": "tmpfs",
                "tmpfs-max-size": TMPFS_SIZE[name],
            }
        ],
        create_only=frozenset({"type", "tmpfs-max-size"}),
    )
    basics.settings("/system/identity", name=name)
    basics.settings(
        "/system/clock", **{"time-zone-autodetect": FALSE, "time-zone-name": TIME_ZONE}
    )
    basics.settings("/system/ntp/client", enabled=TRUE)
    basics.settings("/ip/firewall/connection/tracking", **{"loose-tcp-tracking": FALSE})
    basics.table(
        "/ip/service",
        ("name",),
        [
            {"name": "ftp", "disabled": TRUE},
            {"name": "telnet", "disabled": TRUE},
            {"name": "winbox", "available-from": "10.0.0.0/8"},
            {"name": "api-ssl", "disabled": TRUE},
        ],
        can_add=False,
    )


def make_internal_basics(
    plan: dict[str, Any], router: MTikRouter, snmp_community: str
) -> MTikBasics:
    name = router.name
    cfg = plan["routers"][name]
    index = cfg["index"]
    primary = index == 1
    vlans = plan["vlans"]
    basics = MTikBasics()
    _add_common(basics, name)

    native = next(vlan for vlan in vlans if vlan["native"])
    trunk = f"vlan-{native['name']}"
    public6 = ip_network(cfg["publicIpv6"])
    s2s = _router_s2s(cfg)

    if name == "router":
        basics.table(
            "/interface/ethernet/switch",
            ("name",),
            [{"name": "switch1", "cpu-flow-control": TRUE}],
            can_add=False,
        )

    # Interfaces
    basics.table(
        "/interface/vlan",
        ("name",),
        [
            {
                "name": f"vlan-{vlan['name']}",
                "interface": trunk,
                "vlan-id": str(vlan["vlanId"]),
                "mtu": str(vlan["mtu"]),
            }
            for vlan in vlans
            if not vlan["native"]
        ],
        prune=_prune_all,
    )
    basics.table(
        "/interface/wireguard",
        ("name",),
        [
            _wireguard("wg-vpn", 13231),
            _wireguard("wg-s2s", 13232),
            _wireguard("wg-cghmn", 22351),
        ],
    )
    basics.table(
        "/interface/6to4",
        ("name",),
        [{"name": "6to4-redfox", "remote-address": _ip(REDFOX_WAN), "mtu": "1480"}],
    )

    # VRRP, the native VLAN's instances are the group authority for the others
    vrrp: list[dict[str, str]] = []
    vrrp_lists: list[tuple[str, str]] = []
    for vlan in sorted(vlans, key=lambda vlan: not vlan["native"]):
        iface = f"vlan-{vlan['name']}"
        for vip in vlan["vips"]:
            for suffix, vrid, family in (("", "vrid", "ipv4"), ("6", "vrid6", "ipv6")):
                if vrid not in vip:
                    continue
                vrrp_name = f"vrrp-{vlan['name']}-{vip['name']}{suffix}"
                authority = (
                    "self"
                    if vlan["native"]
                    else f"vrrp-{native['name']}-{vip['name']}{suffix}"
                )
                row = {
                    "name": vrrp_name,
                    "interface": iface,
                    "vrid": str(vip[vrid]),
                    "group-authority": authority,
                    # wan-online-adjust moves it between online and offline
                    "priority": str(router.vrrp_priority_online),
                }
                if family == "ipv4":
                    row["version"] = "2"
                else:
                    row["v3-protocol"] = "ipv6"
                vrrp.append(row)
                vrrp_lists.append((vrrp_name, vlan["interfaceList"]))
    basics.table(
        "/interface/vrrp",
        ("name",),
        vrrp,
        create_only=frozenset({"priority"}),
        prune=_prune_all,
    )

    # Interface lists
    vlan_lists = sorted(
        {
            vlan["interfaceList"]
            for vlan in vlans
            if vlan["interfaceList"] not in (None, "zone-local")
        }
    )
    basics.table(
        "/interface/list",
        ("name",),
        [{"name": list_name} for list_name in vlan_lists]
        + [
            {"name": "zone-wan"},
            {"name": "no-internet"},
            {"name": "zone-local", "include": ",".join(vlan_lists)},
        ],
        prune=_prune_all,
    )
    members = [
        (f"vlan-{vlan['name']}", vlan["interfaceList"])
        for vlan in vlans
        if vlan["interfaceList"] is not None
    ]
    members += vrrp_lists
    members += [
        ("wan", "zone-wan"),
        ("6to4-redfox", "zone-wan"),
        ("wg-cghmn", "iface-cghmn"),
        ("wg-cghmn", "no-internet"),
        ("wg-s2s", "zone-local"),
        ("wg-vpn", "zone-local"),
    ]
    basics.table(
        "/interface/list/member",
        ("interface", "list"),
        [{"interface": iface, "list": list_name} for iface, list_name in members],
        prune=_not_veth,
    )

    # Pools
    pools = []
    pools6 = []
    for vlan in vlans:
        mine = vlan["routers"][name]
        if mine["pool"] is not None:
            pools.append({"name": f"pool-{vlan['name']}", "ranges": mine["pool"]})
    # Only the primary hands out public IPv6 on the VLANs
    if primary:
        pools6.append(
            {
                "name": "pool-wan",
                "prefix": str(next(public6.subnets(new_prefix=60))),
                "prefix-length": "64",
            }
        )
    pools.append({"name": "pool-oob", "ranges": OOB_POOL})
    basics.table("/ip/pool", ("name",), pools, prune=_prune_all)
    basics.table("/ipv6/pool", ("name",), pools6, prune=_prune_all)

    # Addresses
    addresses: list[dict[str, str]] = []
    addresses6: list[dict[str, str]] = []
    addresses6_pool: list[dict[str, str]] = []
    local_ips: list[str] = []
    for vlan in vlans:
        mine = vlan["routers"][name]
        iface = f"vlan-{vlan['name']}"
        if mine["ipv4"] is not None:
            addresses.append({"address": mine["ipv4"], "interface": iface})
            local_ips.append(_host(mine["ipv4"]))
        if mine["ipv6"] is not None:
            addresses6.append(
                {"address": mine["ipv6"], "interface": iface, "advertise": TRUE}
            )
            local_ips.append(_host(mine["ipv6"]))
        if primary and vlan["ipv6"] is not None:
            addresses6_pool.append(
                {
                    "from-pool": "pool-wan",
                    "interface": iface,
                    "address": f"::{vlan['vlanId']:x}:0:0:0:1",
                    "from-pool-policy": "strict",
                    "advertise": TRUE,
                }
            )
        for vip in vlan["vips"]:
            addresses.append(
                {
                    "address": f"{vip['ipv4']}/32",
                    "interface": f"vrrp-{vlan['name']}-{vip['name']}",
                }
            )
            local_ips.append(vip["ipv4"])
            if "ipv6" in vip:
                addresses6.append(
                    {
                        "address": f"{vip['ipv6']}/128",
                        "interface": f"vrrp-{vlan['name']}-{vip['name']}6",
                        "advertise": FALSE,
                    }
                )
                local_ips.append(_host(vip["ipv6"]))
    for extra in cfg["addresses"]:
        if _is_ipv4(extra["address"]):
            addresses.append(
                {"address": extra["address"], "interface": extra["interface"]}
            )
        else:
            addresses6.append(
                {
                    "address": extra["address"],
                    "interface": extra["interface"],
                    "advertise": FALSE,
                }
            )
        if extra["local"]:
            local_ips.append(_host(extra["address"]))
    addresses.append({"address": OOB_ADDRESS[name], "interface": "oob"})
    if primary:
        addresses6_pool.append(
            {
                "from-pool": "pool-wan",
                "interface": "wan",
                "address": "::1",
                "from-pool-policy": "without-acquire",
                "advertise": FALSE,
            }
        )
    else:
        addresses6.append(
            {
                "address": f"{public6.network_address + 1}/128",
                "interface": "wan",
                "advertise": FALSE,
            }
        )
    basics.table("/ip/address", ("address", "interface"), addresses, prune=_not_veth)
    basics.table(
        "/ipv6/address",
        ("address", "interface"),
        addresses6,
        prune=lambda row: _not_veth(row) and row.get("from-pool", "") == "",
    )
    # These read back with the address taken from the pool filled in
    basics.table(
        "/ipv6/address",
        ("from-pool", "interface"),
        addresses6_pool,
        create_only=frozenset({"address", "from-pool-policy"}),
        prune=lambda row: row.get("from-pool", "") != "",
    )

    # DHCP and router advertisements
    servers = []
    networks = []
    nds = []
    for vlan in vlans:
        mine = vlan["routers"][name]
        iface = f"vlan-{vlan['name']}"
        ipv4 = vlan["ipv4"]
        if ipv4 is None:
            continue
        server = {
            "name": f"dhcp-{vlan['name']}",
            "interface": iface,
            "address-pool": f"pool-{vlan['name']}"
            if mine["pool"] is not None
            else "static-only",
            "lease-time": vlan["leaseTime"],
            "allow-dual-stack-queue": FALSE,
        }
        if not primary:
            # Leave the primary time to answer first
            server["authoritative"] = "after-10sec-delay"
        servers.append(server)
        network = ip_network(ipv4["network"])
        networks.append(
            {
                "address": str(network),
                "gateway": ipv4["gateway"],
                "dns-server": ",".join(ipv4["dns"]),
                "netmask": str(network.prefixlen),
                "domain": ipv4["domain"] or "",
                # Has to be cleared for ntp-server to take
                "ntp-none": format_mtik_bool(ipv4["ntp"] is None),
                "ntp-server": ",".join(ipv4["ntp"] or []),
            }
        )
        if vlan["ipv6"] is not None:
            nds.append(
                {
                    "interface": iface,
                    "advertise-dns": "yes",
                    "dns": ",".join(vlan["ipv6"]["dns"]),
                    "ra-interval": "1m-3m",
                    "ra-preference": "high" if primary else "medium",
                }
            )
    servers.append(
        {
            "name": "dhcp-oob",
            "interface": "oob",
            "address-pool": "pool-oob",
            "lease-time": "1h",
            "allow-dual-stack-queue": FALSE,
            "bootp-support": "none",
        }
    )
    networks.append(
        {
            "address": OOB_NETWORK,
            "dns-none": TRUE,
            "ntp-none": TRUE,
            "gateway": "",
            "boot-file-name": "",
        }
    )
    basics.table("/ip/dhcp-server", ("name",), servers, prune=_prune_all)
    basics.table("/ip/dhcp-server/network", ("address",), networks)
    basics.settings("/ip/dhcp-server/config", **{"store-leases-disk": "never"})
    basics.table("/ipv6/nd", ("interface",), nds, prune=_prune_all)
    basics.table(
        "/ipv6/nd", ("default",), [{"default": TRUE, "disabled": TRUE}], can_add=False
    )

    # Uplinks
    basics.table(
        "/ip/dhcp-client",
        ("interface",),
        [
            {
                "interface": "wan",
                "default-route-distance": "5",
                "use-peer-ntp": FALSE,
                "script": WAN_ONLINE_SCRIPT,
            }
        ],
    )
    basics.table(
        "/ipv6/dhcp-client",
        ("interface",),
        [
            {
                "interface": "wan",
                "request": "prefix",
                "pool-name": "pool-wanx",
                "pool-prefix-length": "64",
                "use-peer-dns": FALSE,
            }
        ],
    )
    basics.table(
        "/tool/netwatch",
        ("comment",),
        [
            {
                "comment": "monitor-default",
                "type": "icmp",
                "host": "8.8.8.8",
                "interval": "30s",
                "timeout": "1s",
                "startup-delay": "1m",
                "up-script": WAN_ONLINE_SCRIPT,
                "down-script": WAN_ONLINE_SCRIPT,
            }
        ],
    )

    # Address lists, before the routing config referencing them
    basics.table(
        "/ip/firewall/address-list",
        ("list", "address"),
        [{"list": "local-ip", "address": ip} for ip in local_ips if "." in ip],
        prune=_in_lists("local-ip"),
    )
    basics.table(
        "/ipv6/firewall/address-list",
        ("list", "address"),
        [{"list": "local-ip", "address": ip} for ip in local_ips if "." not in ip]
        + [{"list": "bgp6-redfox", "address": str(public6), "comment": "primary"}],
        prune=_in_lists("local-ip", "bgp6-redfox"),
    )

    # Routing
    routes = [
        {"dst-address": net, "blackhole": TRUE}
        for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
    ]
    # Over the other router while the WAN is down
    routes.append(
        {
            "dst-address": "0.0.0.0/0",
            "gateway": native["ipv4"]["gateway"],
            "distance": "10",
        }
    )
    if primary:
        routes.append({"dst-address": "100.64.0.0/10", "gateway": "wg-cghmn"})
    basics.table(
        "/ip/route",
        ("dst-address",),
        routes,
        create_only=ROUTE_CREATE_ONLY,
        prune=_prune_all,
    )
    tunnel_gateway = f"{cfg['tunnelIpv6']}::1"
    basics.table(
        "/ipv6/route",
        ("dst-address",),
        [
            {"dst-address": "::/0", "gateway": tunnel_gateway},
            {"dst-address": ULA_RANGE, "blackhole": TRUE},
            {"dst-address": str(public6), "blackhole": TRUE, "distance": "100"},
        ],
        create_only=ROUTE_CREATE_ONLY,
        prune=_prune_all,
    )
    basics.table(
        "/routing/filter/rule",
        ("chain", "rule"),
        [
            {"chain": "reject-all", "rule": "reject;"},
            {"chain": "accept-all", "rule": "accept;"},
            {"chain": "redfox-out", "rule": "if (dst in bgp6-redfox) { accept; }"},
        ],
        prune=_prune_all,
    )
    basics.table(
        "/routing/bgp/instance",
        ("name",),
        [{"name": "bgp-instance-1", "as": AS_NUMBER, "router-id": _ip(s2s)}],
        prune=_prune_all,
    )
    basics.table(
        "/routing/bgp/connection",
        ("name",),
        [
            _bgp_connection(
                "bgp-redfox",
                afi="ipv6",
                **{
                    "nexthop-choice": "force-self",
                    "local.address": _ip(s2s),
                    "local.role": "ibgp",
                    "remote.address": f"{_ip(REDFOX_S2S)}/32",
                    "remote.as": AS_NUMBER,
                    "input.filter": "reject-all",
                    "output.filter-chain": "redfox-out",
                    "output.network": "bgp6-redfox",
                },
            )
        ],
        prune=_prune_all,
    )

    # Services
    basics.settings("/ip/settings", **{"rp-filter": "loose", "tcp-syncookies": TRUE})
    basics.settings(
        "/ipv6/settings",
        **{"accept-redirects": "no", "accept-router-advertisements": "no"},
    )
    basics.settings(
        "/ip/neighbor/discovery-settings",
        **{"lldp-mac-phy-config": TRUE, "lldp-vlan-info": TRUE},
    )
    basics.settings("/ip/cloud", **{"update-time": FALSE})
    basics.settings(
        "/ip/dns",
        **{
            "allow-remote-requests": TRUE,
            "cache-max-ttl": "1d",
            "cache-size": "65536",
            "verify-doh-cert": TRUE,
        },
    )
    basics.table(
        "/ip/dns/forwarders",
        ("name",),
        [
            {"name": "getflix", "dns-servers": "54.187.61.200,169.55.51.86"},
            {"name": "cghmn", "dns-servers": "100.64.12.1"},
        ],
    )
    basics.settings(
        "/ip/ssh",
        **{
            "forwarding-enabled": "local",
            "known-hosts-validation": FALSE,
            "strong-crypto": TRUE,
        },
    )
    basics.table(
        "/ip/service",
        ("name",),
        [{"name": "www-ssl", "tls-version": "only-1.2"}],
        can_add=False,
    )
    basics.settings("/system/ntp/server", enabled=TRUE)
    basics.table(
        "/system/ntp/client/servers",
        ("address",),
        # ntpi
        [{"address": "10.2.1.123"}] + NTP_POOL,
        prune=_prune_all,
    )
    basics.settings("/system/routerboard/settings", **{"auto-upgrade": TRUE})
    # Leftovers of RADIUS logins, an SMB share for IPMI, IPFIX export, a CAKE
    # queue and DHCP options/DHCPv6 servers. Option sets go before their options.
    basics.table("/queue/type", ("name",), [], prune=_prune_all)
    basics.table("/queue/simple", ("name",), [], prune=_prune_all)
    basics.table("/ip/dhcp-server/option", ("name",), [], prune=_prune_all)
    basics.table("/ip/dhcp-server/option/sets", ("name",), [], prune=_prune_all)
    basics.table("/ipv6/dhcp-server/option", ("name",), [], prune=_prune_all)
    basics.table("/ipv6/dhcp-server/option/sets", ("name",), [], prune=_prune_all)
    basics.table("/ipv6/dhcp-server", ("name",), [], prune=_prune_all)
    basics.settings("/user/aaa", **{"use-radius": FALSE})
    basics.table("/radius", ("address",), [], prune=_prune_all)
    basics.settings("/ip/smb", enabled="no")
    basics.table("/ip/smb/users", ("name",), [], prune=_prune_all)
    basics.settings("/ip/traffic-flow", enabled=FALSE)
    basics.table("/ip/traffic-flow/target", ("dst-address",), [], prune=_prune_all)
    basics.settings(
        "/snmp",
        contact="admin@foxden.network",
        enabled=TRUE,
        location="Server room",
        **{"trap-generators": ""},
    )
    basics.table(
        "/snmp/community",
        ("default",),
        [{"default": TRUE, "disabled": TRUE}],
        can_add=False,
    )
    basics.table(
        "/snmp/community",
        ("name",),
        [{"name": snmp_community, "addresses": "::/0"}],
        prune=_prune_all,
    )
    basics.settings(
        "/tool/e-mail",
        **{
            "from": f"{name}@foxden.network",
            "server": FOXMAIL_CONTAINER.ipv4(CONTAINER_HOST),
            "port": "2525",
        },
    )
    basics.table(
        "/user/group",
        ("name",),
        [
            {
                "name": "monitoring",
                "policy": "read,api,!local,!telnet,!ssh,!ftp,!reboot,!write,!policy,!test,!winbox,!password,!web,!sniff,!sensitive,!romon,!rest-api",
            },
            {
                "name": "vpn-portal",
                "comment": "foxden-vpn-portal",
                "policy": "read,write,sensitive,api,!local,!telnet,!ssh,!ftp,!reboot,!policy,!test,!winbox,!password,!web,!sniff,!romon,!rest-api",
            },
        ],
    )
    return basics


def _redfox_firewall() -> dict[str, list[MTikFirewallRule]]:
    def rules(
        family: str, table: str, *attribs: dict[str, str]
    ) -> list[MTikFirewallRule]:
        return [
            MTikFirewallRule(
                families=[family], table=table, attribs={**rule, "disabled": FALSE}
            )
            for rule in attribs
        ]

    return {
        "/ip/firewall/filter": rules(
            "ip",
            "filter",
            {
                "chain": "forward",
                "action": "drop",
                "log": TRUE,
                "log-prefix": "FWD-DROP",
            },
            {
                "chain": "input",
                "action": "fasttrack-connection",
                "comment": "established, related",
                "connection-state": "established,related",
            },
            {
                "chain": "input",
                "action": "accept",
                "comment": "established, related",
                "connection-state": "established,related",
            },
            {
                "chain": "input",
                "action": "accept",
                "comment": "loopback",
                "in-interface": "lo",
            },
            {
                "chain": "input",
                "action": "accept",
                "comment": "BGP",
                "dst-port": "179",
                "protocol": "tcp",
            },
            {
                "chain": "input",
                "action": "accept",
                "comment": "ICMP",
                "protocol": "icmp",
            },
            {
                "chain": "input",
                "action": "accept",
                "comment": "WireGuard",
                "dst-port": "13232",
                "protocol": "udp",
            },
            {
                "chain": "input",
                "action": "accept",
                "comment": "6to4",
                "protocol": "ipv6-encap",
            },
            {"chain": "input", "action": "accept", "in-interface": "wg-s2s"},
            {"chain": "input", "action": "drop"},
        ),
        "/ipv6/firewall/filter": rules(
            "ipv6",
            "filter",
            {
                "chain": "input",
                "action": "accept",
                "comment": "related, established",
                "connection-state": "established,related",
            },
            {
                "chain": "input",
                "action": "accept",
                "comment": "loopback",
                "in-interface": "lo",
            },
            {
                "chain": "input",
                "action": "accept",
                "comment": "ICMPv6",
                "protocol": "icmpv6",
            },
            {
                "chain": "input",
                "action": "accept",
                "comment": "WireGuard",
                "dst-port": "13232",
                "protocol": "udp",
            },
            {"chain": "input", "action": "accept", "in-interface": "wg-s2s"},
            {"chain": "input", "action": "drop"},
            {"chain": "forward", "action": "fasttrack-connection"},
            {"chain": "forward", "action": "accept"},
        ),
        "/ipv6/firewall/raw": rules(
            "ipv6",
            "raw",
            {
                "chain": "prerouting",
                "action": "notrack",
                "dst-address-list": "ipv6-customer",
            },
            {
                "chain": "prerouting",
                "action": "notrack",
                "src-address-list": "ipv6-customer",
            },
        ),
    }


def make_redfox_basics(plan: dict[str, Any]) -> MTikBasics:
    basics = MTikBasics()
    _add_common(basics, "redfox")
    wan = _ip(REDFOX_WAN)
    wan6 = _ip(REDFOX_WAN6)
    s2s = _ip(REDFOX_S2S)
    routers = sorted(plan["routers"].items(), key=lambda item: item[1]["index"])

    basics.table("/interface/wireguard", ("name",), [_wireguard("wg-s2s", 13232)])
    # ip-update keeps remote-address pointed at each router's WAN address
    basics.table(
        "/interface/6to4",
        ("name",),
        [
            {"name": f"6to4-{name}", "comment": name, "local-address": wan}
            for name, _ in routers
        ],
        prune=_prune_all,
    )
    basics.table("/interface/list", ("name",), [{"name": "customer"}], prune=_prune_all)
    basics.table(
        "/interface/list/member",
        ("interface", "list"),
        [{"interface": f"6to4-{name}", "list": "customer"} for name, _ in routers],
        prune=_not_veth,
    )
    basics.table(
        "/ipv6/pool",
        ("name",),
        [{"name": "pool-customer", "prefix": REDFOX_CUSTOMER6, "prefix-length": "56"}],
        prune=_prune_all,
    )

    basics.table(
        "/ip/address",
        ("address", "interface"),
        [
            {"address": REDFOX_WAN, "interface": "wan"},
            {"address": REDFOX_S2S, "interface": "wg-s2s"},
        ],
        prune=_not_veth,
    )
    basics.table(
        "/ipv6/address",
        ("address", "interface"),
        [{"address": REDFOX_WAN6, "interface": "wan", "advertise": FALSE}]
        + [
            {
                "address": f"{cfg['tunnelIpv6']}::1/56",
                "interface": f"6to4-{name}",
                "advertise": FALSE,
            }
            for name, cfg in routers
        ]
        + [{"address": REDFOX_S2S6, "interface": "wg-s2s", "advertise": FALSE}],
        prune=_not_veth,
    )

    basics.table(
        "/ip/route",
        ("dst-address",),
        [
            {"dst-address": "0.0.0.0/0", "gateway": REDFOX_WAN_GATEWAY},
            {"dst-address": "10.0.0.0/8", "gateway": "wg-s2s"},
            {"dst-address": "192.168.0.0/16", "blackhole": TRUE},
        ],
        create_only=ROUTE_CREATE_ONLY,
        prune=_prune_all,
    )
    basics.table(
        "/ipv6/route",
        ("dst-address",),
        [{"dst-address": ULA_RANGE, "gateway": "wg-s2s"}]
        + [
            {"dst-address": net, "blackhole": TRUE, "distance": "100"}
            for net in VULTR_PREFIXES6
        ],
        create_only=ROUTE_CREATE_ONLY,
        prune=_prune_all,
    )

    basics.table(
        "/ip/firewall/address-list",
        ("list", "address"),
        [{"list": "local-ips", "address": s2s}, {"list": "local-ips", "address": wan}],
        prune=_prune_all,
    )
    basics.table(
        "/ipv6/firewall/address-list",
        ("list", "address"),
        [
            {"list": f"bgp6-{name}", "address": cfg["publicIpv6"]}
            for name, cfg in routers
        ]
        + [{"list": "bgp6-vultr-direct", "address": net} for net in VULTR_PREFIXES6]
        + [{"list": "ipv6-customer", "address": REDFOX_CUSTOMER6}],
        prune=_prune_all,
    )

    # Each router's prefix goes over its 6to4 tunnel, the primary's preferred
    basics.table(
        "/routing/filter/rule",
        ("chain", "rule"),
        [
            {
                "chain": f"{name}-in",
                "rule": f"if (dst in bgp6-{name}) {{ set gw {cfg['tunnelIpv6']}::2; set distance {40 + 10 * cfg['index']}; accept; }}",
            }
            for name, cfg in routers
        ]
        + [
            {"chain": "reject-all", "rule": "reject;"},
            {
                "chain": "vultr-out-ipv6",
                "rule": "if (dst in bgp6-vultr-direct && dst-len <= 48) { accept; }",
            },
        ],
        prune=_prune_all,
    )
    basics.table(
        "/routing/bgp/instance",
        ("name",),
        [{"name": "bgp-instance-1", "as": AS_NUMBER, "router-id": s2s}],
        prune=_prune_all,
    )
    vultr = {
        "as": AS_NUMBER,
        "local.role": "ebgp",
        "nexthop-choice": "force-self",
        "input.filter": "reject-all",
        "output.remove-private-as": TRUE,
        "remote.as": VULTR_AS,
    }
    basics.table(
        "/routing/bgp/connection",
        ("name",),
        [
            _bgp_connection(
                "bgp-vultr-v4",
                afi="ip",
                **{
                    **vultr,
                    "local.address": wan,
                    "remote.address": "169.254.169.254/32",
                    "output.filter-chain": "vultr-out-ipv4",
                },
            ),
            _bgp_connection(
                "bgp-vultr-v6",
                afi="ipv6",
                **{
                    **vultr,
                    "local.address": wan6,
                    "remote.address": "2001:19f0:ffff::1/128",
                    "output.filter-chain": "vultr-out-ipv6",
                    "output.network": "bgp6-vultr-direct",
                },
            ),
        ]
        + [
            _bgp_connection(
                f"bgp-{name}",
                afi="ipv6",
                **{
                    "as": AS_NUMBER,
                    "local.address": s2s,
                    "local.role": "ibgp",
                    "remote.address": f"{_ip(_router_s2s(cfg))}/32",
                    "remote.as": AS_NUMBER,
                    "input.filter": f"{name}-in",
                    "output.filter-chain": "reject-all",
                },
            )
            for name, cfg in routers
        ],
        prune=_prune_all,
    )

    # Lets the internal mail servers send out over redfox
    basics.settings("/ip/socks", enabled=TRUE, version="5")
    basics.table(
        "/ip/socks/access",
        ("src-address", "dst-port"),
        [
            {"src-address": "10.2.10.0/24", "dst-port": "25"},
            {"src-address": "10.99.1.0/24", "dst-port": "25"},
        ],
        prune=_prune_all,
    )

    basics.table("/system/ntp/client/servers", ("address",), NTP_POOL, prune=_prune_all)
    basics.settings("/ip/settings", **{"tcp-syncookies": TRUE})
    basics.settings(
        "/ipv6/settings",
        **{"accept-redirects": "no", "accept-router-advertisements": "yes"},
    )
    basics.settings("/ip/dns", servers="108.61.10.10", **{"cache-size": "65536"})
    basics.settings(
        "/ip/ssh",
        **{
            "forwarding-enabled": "both",
            "known-hosts-validation": FALSE,
            "strong-crypto": TRUE,
        },
    )

    basics.firewall = _redfox_firewall()
    return basics


def load_plan() -> dict[str, Any]:
    result = (
        check_output(
            [
                "nix",
                "build",
                f"{NIX_DIR}#routers.json",
                "--no-link",
                "--print-out-paths",
            ]
        )
        .strip()
        .decode("utf-8")
    )
    with open(result, "r") as file:
        return json_load(file)


def load_snmp_community() -> str:
    secrets = json_loads(
        check_output(["sops", "decrypt", "--output-type", "json", SECRETS_PATH])
    )
    return secrets["SNMP_COMMUNITY"]


def refresh_basics() -> None:
    plan = load_plan()
    snmp_community = load_snmp_community()
    for router in ROUTERS:
        if router.horizon == "internal":
            basics = make_internal_basics(plan, router, snmp_community)
        else:
            basics = make_redfox_basics(plan)
        refresh_basics_router(basics, router)
