from bisect import bisect_left
from dataclasses import dataclass, field
from json import load as json_load
from subprocess import check_output
from typing import Any

from configure.util import (
    NIX_DIR,
    ROUTERS,
    MTikRouter,
    format_mtik_bool,
    format_weird_mtik_ip,
    is_ipv6,
)


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
            "action": "drop",
            "chain": "forward",
            "in-interface-list": "no-internet",
            "out-interface-list": "zone-wan",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "drop",
            "chain": "forward",
            "in-interface-list": "zone-wan",
            "out-interface-list": "no-internet",
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
            "comment": "MASQ router",
            "dst-address": "10.2.1.1",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "masquerade",
            "chain": "srcnat",
            "comment": "MASQ router-backup",
            "dst-address": "10.2.1.2",
        },
    ),
    FirewallRule(
        families=["ipv6"],
        table="nat",
        attribs={
            "action": "masquerade",
            "chain": "srcnat",
            "comment": "MASQ router",
            "dst-address": "fd2c:f4cb:63be:2::101/128",
        },
    ),
    FirewallRule(
        families=["ipv6"],
        table="nat",
        attribs={
            "action": "masquerade",
            "chain": "srcnat",
            "comment": "MASQ router-backup",
            "dst-address": "fd2c:f4cb:63be:2::102/128",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="nat",
        attribs={
            "action": "masquerade",
            "chain": "srcnat",
            "comment": "cghmn",
            "dst-address": "!100.68.41.0/24",
            "out-interface-list": "iface-cghmn",
            "src-address": "!100.68.41.0/24",
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
            "comment": "Local faux external ingress",
            "dst-address": "10.2.6.0/24",
            "jump-target": "port-forward",
        },
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
            "comment": "foxIngress TCP (Priv)",
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
            "chain": "port-forward",
            "comment": "foxIngress TCP (Pub)",
            "dst-port": "80,443",
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
            "comment": "foxMail TCP (Priv)",
            "dst-port": "2525,9002",
            "protocol": "tcp",
            "to-addresses": "172.17.1.2",
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
            "comment": "Ingress PT DHCP static ULA",
            "dst-address-list": "ipv6-dhcp-ranges",
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
            "comment": "foxIngress TCP (Priv)",
            "dst-port": "9001",
            "protocol": "tcp",
            "to-address": "fd2c:f4cb:63be::ac11:2/128",
        },
    ),
    FirewallRule(
        families=["ipv6"],
        table="nat",
        attribs={
            "action": "dst-nat",
            "chain": "local-port-forward",
            "comment": "foxMail TCP (Priv)",
            "dst-port": "2525,9002",
            "protocol": "tcp",
            "to-address": "fd2c:f4cb:63be::ac11:102/128",
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
            "in-interface": "veth-foxmail",
            "out-interface": "wg-s2s",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "in-interface-list": "zone-local",
            "out-interface-list": "iface-cghmn",
        },
    ),
    FirewallRule(
        families=["ip"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "in-interface-list": "iface-cghmn",
            "out-interface-list": "iface-cghmn",
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
            "comment": "foxIngress TCP (Pub)",
            "dst-port": "80,443",
            "out-interface": "veth-foxingress",
            "protocol": "tcp",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "foxIngress TCP (Priv)",
            "dst-port": "9001",
            "in-interface-list": "zone-local",
            "out-interface": "veth-foxingress",
            "protocol": "tcp",
        },
    ),
    FirewallRule(
        families=["ip", "ipv6"],
        table="filter",
        attribs={
            "action": "accept",
            "chain": "forward",
            "comment": "foxMail TCP (Priv)",
            "dst-port": "2525,9002",
            "in-interface-list": "zone-local",
            "out-interface": "veth-foxmail",
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


def _rule_matches(current_rule: dict[str, Any], rule: FirewallRule) -> bool:
    all_keys = set(current_rule.keys()).union(set(rule.attribs.keys()))
    for match_key in all_keys:
        if (
            match_key in rule.ignoreChanges
            or match_key in IGNORE_CHANGES
            or match_key[0] == "."
        ):
            continue

        if current_rule.get(match_key, "") != rule.attribs.get(match_key, ""):
            return False
    return True


def _longest_increasing_subsequence(values: list[int]) -> set[int]:
    # Returns the indices (into values) of one longest strictly increasing subsequence
    tails: list[int] = []
    prev: list[int] = [-1] * len(values)
    for i, value in enumerate(values):
        pos = bisect_left(tails, value, key=lambda t: values[t])
        if pos > 0:
            prev[i] = tails[pos - 1]
        if pos == len(tails):
            tails.append(i)
        else:
            tails[pos] = i

    result: set[int] = set()
    i = tails[-1] if tails else -1
    while i >= 0:
        result.add(i)
        i = prev[i]
    return result


def _sync_firewall_table(
    api_rule: Any, deployed: list[dict[str, Any]], rules: list[FirewallRule]
) -> None:
    # Pair each wanted rule with an identical deployed rule (if any)
    unmatched = list(range(len(deployed)))
    matches: list[int | None] = []
    for rule in rules:
        match = next((i for i in unmatched if _rule_matches(deployed[i], rule)), None)
        if match is not None:
            unmatched.remove(match)
        matches.append(match)

    # Matched rules already in correct relative order stay where they are
    matched = [(pos, match) for pos, match in enumerate(matches) if match is not None]
    stable = {
        matched[i][0]
        for i in _longest_increasing_subsequence([match for _, match in matched])
    }

    # Every other rule is placed right before the next stable rule (or at the end)
    anchors: list[str | None] = [None] * len(rules)
    anchor: str | None = None
    for pos in reversed(range(len(rules))):
        anchors[pos] = anchor
        match = matches[pos]
        if pos in stable and match is not None:
            anchor = deployed[match]["id"]

    for pos, rule in enumerate(rules):
        if pos in stable:
            continue
        anchor = anchors[pos]
        match = matches[pos]
        if match is None:
            print("Adding firewall rule", rule.attribs)
            if anchor is None:
                api_rule.add(**rule.attribs)
            else:
                api_rule.add(**rule.attribs, **{"place-before": anchor})
        else:
            print("Moving firewall rule", rule.attribs)
            move_args = {"numbers": deployed[match]["id"]}
            if anchor is not None:
                move_args["destination"] = anchor
            api_rule.call("move", move_args)

    for i in unmatched:
        print("Removing extra firewall rule", deployed[i])
        api_rule.remove(id=deployed[i]["id"])


def refresh_firewall_router(
    firewall_rules: list[FirewallRule], router: MTikRouter
) -> None:
    print(f"## {router.host}")
    connection = router.connection()
    api = connection.get_api()
    table_rules: dict[str, list[FirewallRule]] = {}

    for rule in firewall_rules:
        for family in rule.families:
            key = f"/{family}/firewall/{rule.table}"
            table_rules.setdefault(key, []).append(rule)

    for key, rules in table_rules.items():
        api_rule = api.get_resource(key)
        deployed = api_rule.get(dynamic=format_mtik_bool(False))
        _sync_firewall_table(api_rule, deployed, rules)


def refresh_firewall() -> None:
    result = (
        check_output(
            [
                "nix",
                "build",
                f"{NIX_DIR}#firewall.json.router",
                "--no-link",
                "--print-out-paths",
            ]
        )
        .strip()
        .decode("utf-8")
    )
    with open(result, "r") as file:
        raw_firewall_rules = json_load(file)

    firewall_rules = []

    for rule in raw_firewall_rules:
        addr = rule.get(
            "source", rule.get("destination", rule.get("toAddresses", None))
        )
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
            for field in ("src-address", "dst-address"):
                if field not in attribs:
                    continue
                attribs[field] = format_weird_mtik_ip(attribs[field])

        firewall_rules.append(
            FirewallRule(
                families=families,
                table=rule["table"],
                attribs=attribs,
            )
        )

    firewall_rules = DEFAULT_RULES_HEAD + firewall_rules + DEFAULT_RULES_TAIL
    for rule in firewall_rules:
        rule.attribs["disabled"] = format_mtik_bool(False)

    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        refresh_firewall_router(firewall_rules, router)
