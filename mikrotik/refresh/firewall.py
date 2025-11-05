from subprocess import check_call
from json import load as json_load
from refresh.util import unlink_safe, NIX_DIR, ROUTERS, format_mtik_bool, is_ipv6, format_weird_mtik_ip, MTikRouter
from dataclasses import dataclass, field
from typing import Any

@dataclass(frozen=True, kw_only=True)
class FirewallRule:
    families: list[str]
    table: str
    attribs: dict[str, str]
    ignoreChanges: set[str] = field(default_factory=set)

IGNORE_CHANGES = {"id", "invalid", "packets", "bytes", "dynamic"}

DEFAULT_RULES_HEAD: list[FirewallRule] = [
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "reject",
            "chain": "forward",
            "comment": "invalid",
            "connection-state": "invalid",
            "reject-with": "icmp-admin-prohibited",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="filter",
        attribs={
            "action": "fasttrack-connection",
            "chain": "forward",
            "comment": "related, established",
            "connection-state": "established,related",
            "hw-offload": format_mtik_bool(True),
        },
    ),
    FirewallRule(
        families=["ipv6"],
        table="filter",
        attribs={
            "action": "fasttrack-connection",
            "chain": "forward",
            "comment": "related, established",
            "connection-state": "established,related",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "related, established",
            "connection-state": "established,related",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "protocol": "icmp",
        },
    ),
    FirewallRule(
        families=["ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "protocol": "icmpv6",
        },
    ),

    FirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "masquerade",
            "chain": "srcnat",
            "comment": "WAN",
            "out-interface": "wan",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "masquerade",
            "chain": "srcnat",
            "comment": "cghmn",
            "dst-address": "!100.96.41.0/24",
            "out-interface-list": "iface-cghmn",
            "src-address": "!100.96.41.0/24",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "masquerade",
            "chain": "srcnat",
            "comment": "Containers",
            "src-address": "172.17.0.0/16",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "jump",
            "chain": "dstnat",
            "comment": "Hairpin",
            "dst-address": "127.1.1.1",
            "jump-target": "port-forward",
        },
        ignoreChanges={"dst-address"},
    ),
    FirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "jump",
            "chain": "dstnat",
            "comment": "External",
            "in-interface-list": "zone-wan",
            "jump-target": "port-forward",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="nat",
        attribs={
            "action": "jump",
            "chain": "dstnat",
            "comment": "Local forward",
            "dst-address-list": "local-ip",
            "in-interface-list": "zone-local",
            "jump-target": "local-port-forward",
        },
    ),

    FirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "dst-nat",
            "chain": "local-port-forward",
            "comment": "DNS TCP (Priv)",
            "dst-port": "53,530",
            "protocol": "tcp",
            "to-addresses": "172.17.2.2",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "dst-nat",
            "chain": "local-port-forward",
            "comment": "DNS UDP (Priv)",
            "dst-port": "53,530",
            "protocol": "udp",
            "to-addresses": "172.17.2.2",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "dst-nat",
            "chain": "local-port-forward",
            "comment": "HAProxy TCP (Priv)",
            "dst-port": "9001",
            "protocol": "tcp",
            "to-addresses": "172.17.0.2",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "dst-nat",
            "chain": "local-port-forward",
            "comment": "HAProxy TCP (Pub)",
            "dst-port": "80,443",
            "protocol": "tcp",
            "to-addresses": "172.17.0.2",
        },
    ),
    FirewallRule(
        families=["ipv6"],
        table="nat",
        attribs={
            "action": "src-nat",
            "chain": "srcnat",
            "comment": "VPN Masq",
            "dst-address": "!fd2c:f4cb:63be::/60",
            "in-interface": "wg-vpn",
            "to-address": "fd2d::ffff/128",
        },
        ignoreChanges={"to-address"},
    ),
    FirewallRule(
        families=["ipv6"],
        table="nat",
        attribs={
            "action": "netmap",
            "chain": "dstnat",
            "comment": "Ingress PT",
            "dst-address": "fd2d::/60",
            "to-address": "fd2c:f4cb:63be::/60",
        },
        ignoreChanges={"dst-address"},
    ),
    FirewallRule(
        families=["ipv6"],
        table="nat",
        attribs={
            "action": "netmap",
            "chain": "srcnat",
            "comment": "Egress PT",
            "dst-address": "!fd2c:f4cb:63be::/60",
            "in-interface-list": "zone-local",
            "src-address": "fd2c:f4cb:63be::/60",
            "to-address": "fd2d::/60",
        },
        ignoreChanges={"to-address"},
    ),
    FirewallRule(
        families=["ipv6"],
        table="nat",
        attribs={
            "action": "dst-nat",
            "chain": "local-port-forward",
            "comment": "DNS TCP (Priv)",
            "dst-port": "53,530",
            "protocol": "tcp",
            "to-address": "fd2c:f4cb:63be::ac11:202/128",
        },
    ),
    FirewallRule(
        families=["ipv6"],
        table="nat",
        attribs={
            "action": "dst-nat",
            "chain": "local-port-forward",
            "comment": "DNS UDP (Priv)",
            "dst-port": "53,530",
            "protocol": "udp",
            "to-address": "fd2c:f4cb:63be::ac11:202/128",
        },
    ),
    FirewallRule(
        families=["ipv6"],
        table="nat",
        attribs={
            "action": "dst-nat",
            "chain": "local-port-forward",
            "comment": "HAProxy TCP (Priv)",
            "dst-port": "9001",
            "protocol": "tcp",
            "to-address": "fd2c:f4cb:63be::ac11:2/128",
        },
    ),
]
DEFAULT_RULES_TAIL: list[FirewallRule] = [
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "in-interface-list": "zone-local",
            "out-interface-list": "zone-wan",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "in-interface": "oob",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "in-interface": "wg-vpn",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "DNS TCP (Priv)",
            "dst-port": "53,530",
            "in-interface-list": "zone-local",
            "out-interface": "veth-dns",
            "protocol": "tcp",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "DNS UDP (Priv)",
            "dst-port": "53,530",
            "in-interface-list": "zone-local",
            "out-interface": "veth-dns",
            "protocol": "udp",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "HAProxy TCP (Pub)",
            "dst-port": "80,443",
            "out-interface": "veth-haproxy",
            "protocol": "tcp",
        },
    ),
    # FirewallRule(
    #     families=["ip", "ipv6"],
    #     table="filter",
    #     attribs={
    #         "action": "accept",
    #         "chain": "forward",
    #         "comment": "HAProxy UDP (Pub)",
    #         "dst-port": "443",
    #         "out-interface": "veth-haproxy",
    #         "protocol": "udp",
    #     },
    # ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "HAProxy TCP (Priv)",
            "dst-port": "9001",
            "in-interface-list": "zone-local",
            "out-interface": "veth-haproxy",
            "protocol": "tcp",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "reject",
            "chain": "forward",
            "reject-with": "icmp-admin-prohibited",
        },
    ),

    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "input",
            "connection-state": "established,related",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "input",
            "protocol": "ipv6-encap",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "input",
            "protocol": "icmp",
        },
    ),
    FirewallRule(
        families=["ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "input",
            "protocol": "icmpv6",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "input",
            "comment": "HTTP(S)",
            "dst-port": "80,443",
            "protocol": "tcp",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "input",
            "comment": "BGP",
            "dst-port": "179",
            "protocol": "tcp",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "input",
            "comment": "WireGuard",
            "dst-port": "13231-13232",
            "protocol": "udp",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "input",
            "in-interface": "lo",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "input",
            "in-interface": "oob",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "input",
            "in-interface-list": "zone-local",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "reject",
            "chain": "input",
            "reject-with": "icmp-admin-prohibited",
        },
    ),
]


def refresh_firewall_router(firewall_rules: list[FirewallRule], router: MTikRouter) -> None:
    print(f"## {router.host}")
    connection = router.connection()
    api = connection.get_api()
    resources: dict[str, Any] = {}
    sent_rule_counts: dict[str, int] = {}
    deployed_rules: dict[str, int] = {}

    for rule in firewall_rules:
        for family in rule.families:
            key = f"/{family}/firewall/{rule.table}"
            if key not in resources:
                resources[key] = api.get_resource(f"/{family}/firewall/{rule.table}")
                deployed_rules[key] = resources[key].get(dynamic=format_mtik_bool(False))
                sent_rule_counts[key] = 0

            api_rule = resources[key]
            if sent_rule_counts[key] < len(deployed_rules[key]):
                current_rule = deployed_rules[key][sent_rule_counts[key]]

                all_keys = set(current_rule.keys()).union(set(rule.attribs.keys()))

                for match_key in all_keys:
                    if match_key in rule.ignoreChanges or match_key in IGNORE_CHANGES or match_key[0] == ".":
                        continue

                    if current_rule.get(match_key, "") == rule.attribs.get(match_key, ""):
                        continue

                    attribs = {
                        **rule.attribs,
                        "place-before": current_rule['id'],
                    }
                    print("Updating firewall rule", rule.attribs)
                    api_rule.add(**attribs)
                    api_rule.remove(id=current_rule['id'])
                    break
            else:
                print("Adding new firewall rule", rule.attribs)
                api_rule.add(**rule.attribs)
            sent_rule_counts[key] += 1

    for key, count in sent_rule_counts.items():
        api_rule = resources[key]
        delete_rules = deployed_rules[key][count:]
        for dr in delete_rules:
            print("Removing extra firewall rule", dr)
            api_rule.remove(id=dr['id'])

def refresh_firewall() -> None:
    unlink_safe("result")
    check_call(["nix", "build", f"{NIX_DIR}#firewall.json.router"])
    with open("result", "r") as file:
        raw_firewall_rules = json_load(file)
    unlink_safe("result")

    firewall_rules = []

    for rule in raw_firewall_rules:
        addr = rule.get("source", rule.get("destination", rule.get("toAddresses", None)))
        if addr is not None:
            families = ["ipv6" if is_ipv6(addr) else "ip"]
        else:
            families = ["ip", "ipv6"]

        chain = rule["chain"]
        if chain == "postrouting":
            chain = "srcnat"
        elif chain == "prerouting":
            chain = "dstnat"
        action = rule["action"]
        if action == "dnat":
            action = "dst-nat"
        elif action == "snat":
            action = "src-nat"

        attribs = {
            "chain": chain,
            "comment": rule.get("comment", ""),
            "dst-address": rule.get("destination", ""),
            "dst-port": str(rule.get("dstport", "")),
            "protocol": rule.get("protocol", ""),
            "src-address": rule.get("source", ""),
            "src-port": str(rule.get("srcport", "")),
            "jump-target": rule.get("jumpTarget", ""),
            "to-addresses": rule.get("toAddresses", ""),
            "to-ports": str(rule.get("toPorts", "")),
            "reject-with": rule.get("rejectWith", ""),
            "action": action,
        }
        delete_attribs = [name for name, value in attribs.items() if value == ""]
        for name in delete_attribs:
            del attribs[name]

        if len(families) == 1:
            for field in {"src-address", "dst-address"}:
                if field not in attribs:
                    continue
                attribs[field] = format_weird_mtik_ip(attribs[field])

        firewall_rules.append(FirewallRule(
            families=families,
            table=rule["table"],
            attribs=attribs,
        ))
        # /{family}/firewall/{rule["table"]}/add

    firewall_rules = DEFAULT_RULES_HEAD + firewall_rules + DEFAULT_RULES_TAIL
    for rule in firewall_rules:
        rule.attribs["disabled"] = format_mtik_bool(False)

    for router in ROUTERS:
        refresh_firewall_router(firewall_rules, router)
