import unittest
from typing import Any

from configure.basics import (
    MTikBasics,
    MTikTable,
    make_internal_basics,
    make_redfox_basics,
    refresh_basics_router,
)
from configure.util import MTikRouter
from tests.fakes import FakeResource, FakeRouter, quiet

ADDRESSES = "/ip/address"


def run(basics: MTikBasics, resources: dict[str, FakeResource]) -> None:
    quiet(refresh_basics_router, basics, FakeRouter(resources))


def mtik_router(name: str) -> MTikRouter:
    return MTikRouter(
        host=f"{name}.foxden.network",
        horizon="internal",
        vrrp_priority_online=50,
        vrrp_priority_offline=10,
        dyndns_suffix_ipv6="",
    )


def plan_router(index: int) -> dict[str, Any]:
    return {
        "index": index,
        "publicIpv6": f"2001:db8:{index}00::/56",
        "tunnelIpv6": f"2001:db8:f{index}00",
        "addresses": [
            {"interface": "wg-s2s", "address": f"10.99.1.{index}/16", "local": True},
            {"interface": "wg-s2s", "address": "10.99.0.1/32", "local": True},
            {"interface": "vlan-lan", "address": f"10.2.6.{index}/24", "local": False},
        ],
    }


def plan_vlan_routers(vlan: int, redundant: bool) -> dict[str, Any]:
    return {
        name: {
            "ipv4": f"10.{vlan}.1.{index}/16",
            "ipv6": f"fd2c:f4cb:63be:{vlan}::10{index}/64" if redundant else None,
            "pool": f"10.{vlan}.{50 + 50 * index}.0-10.{vlan}.{99 + 50 * index}.255"
            if redundant or index == 1
            else None,
        }
        for name, index in (("router", 1), ("router-backup", 2))
    }


PLAN: dict[str, Any] = {
    "routers": {"router": plan_router(1), "router-backup": plan_router(2)},
    "vlans": [
        {
            "name": "mgmt",
            "vlanId": 1,
            "mtu": 9000,
            "native": True,
            "leaseTime": "1h",
            "interfaceList": "iface-mgmt",
            "ipv4": {
                "network": "10.1.0.0/16",
                "gateway": "10.1.0.1",
                "dns": "10.1.0.53",
                "ntp": None,
                "domain": "foxden.network",
            },
            "ipv6": {"network": "fd2c:f4cb:63be:1::/64", "dns": "fd2c:f4cb:63be:1::35"},
            "vips": [
                {
                    "name": "dns",
                    "vrid": 53,
                    "ipv4": "10.1.0.53",
                    "vrid6": 54,
                    "ipv6": "fd2c:f4cb:63be:1::35",
                }
            ],
            "routers": plan_vlan_routers(1, True),
        },
        {
            "name": "retro",
            "vlanId": 7,
            "mtu": 1500,
            "native": False,
            "leaseTime": "1h",
            "interfaceList": "zone-local",
            "ipv4": {
                "network": "10.7.0.0/16",
                "gateway": "10.7.1.1",
                "dns": "10.7.1.1",
                "ntp": None,
                "domain": "foxden.network",
            },
            "ipv6": None,
            "vips": [],
            "routers": plan_vlan_routers(7, False),
        },
    ],
}


def rows(basics: MTikBasics, path: str) -> list[dict[str, str]]:
    return [
        row
        for item in basics.config
        if isinstance(item, MTikTable) and item.path == path
        for row in item.rows
    ]


class TestRefreshBasicsRouter(unittest.TestCase):
    def test_adds_updates_and_prunes(self) -> None:
        basics = MTikBasics()
        basics.table(
            ADDRESSES,
            ("address", "interface"),
            [
                {"address": "10.1.1.1/16", "interface": "vlan-mgmt", "comment": "new"},
                {"address": "10.2.1.1/16", "interface": "vlan-lan"},
            ],
            prune=lambda row: not row["interface"].startswith("veth-"),
        )
        res = FakeResource(
            [
                {"address": "10.1.1.1/16", "interface": "vlan-mgmt", "comment": "old"},
                {"address": "10.9.1.1/16", "interface": "vlan-gone"},
                {"address": "172.17.0.1/24", "interface": "veth-foxingress"},
                {"address": "10.5.5.5/16", "interface": "wan", "dynamic": "true"},
            ]
        )
        run(basics, {ADDRESSES: res})
        self.assertEqual(
            res.attribs(),
            [
                {"address": "10.1.1.1/16", "interface": "vlan-mgmt", "comment": "new"},
                {"address": "172.17.0.1/24", "interface": "veth-foxingress"},
                {"address": "10.5.5.5/16", "interface": "wan", "dynamic": "true"},
                {"address": "10.2.1.1/16", "interface": "vlan-lan"},
            ],
        )

    def test_noop_when_in_sync(self) -> None:
        basics = MTikBasics()
        basics.table(
            "/interface/list",
            ("name",),
            [{"name": "zone-local", "include": "iface-lan,iface-mgmt"}],
            prune=lambda _: True,
        )
        basics.settings("/system/identity", name="router")
        lists = FakeResource(
            [
                {"name": "all", "builtin": "true"},
                {"name": "zone-local", "include": "iface-mgmt,iface-lan"},
            ]
        )
        identity = FakeResource([{"name": "router"}])
        run(basics, {"/interface/list": lists, "/system/identity": identity})
        self.assertEqual(lists.ops, [])
        self.assertEqual(identity.ops, [])

    def test_create_only_and_can_add(self) -> None:
        basics = MTikBasics()
        basics.table(
            "/interface/vrrp",
            ("name",),
            [{"name": "vrrp-mgmt-dns", "priority": "50", "vrid": "53"}],
            create_only=frozenset({"priority"}),
        )
        basics.table(
            "/interface/ethernet",
            ("default-name",),
            [{"default-name": "ether9", "name": "oob"}],
            can_add=False,
        )
        vrrp = FakeResource([{"name": "vrrp-mgmt-dns", "priority": "10", "vrid": "1"}])
        ethernet = FakeResource([])
        run(basics, {"/interface/vrrp": vrrp, "/interface/ethernet": ethernet})
        self.assertEqual(vrrp.attribs()[0]["priority"], "10")
        self.assertEqual(vrrp.attribs()[0]["vrid"], "53")
        self.assertEqual(ethernet.ops, [])

    def test_split_path_keeps_rows_of_other_tables(self) -> None:
        basics = MTikBasics()
        basics.table(
            "/ipv6/address",
            ("address", "interface"),
            [{"address": "fd2c:f4cb:63be:1::101/64", "interface": "vlan-mgmt"}],
            prune=lambda row: row.get("from-pool", "") == "",
        )
        basics.table(
            "/ipv6/address",
            ("from-pool", "interface"),
            [{"from-pool": "pool-wan", "interface": "vlan-mgmt", "address": "::1"}],
            create_only=frozenset({"address"}),
            prune=lambda row: row.get("from-pool", "") != "",
        )
        res = FakeResource(
            [
                {"address": "fd2c:f4cb:63be:1::101/64", "interface": "vlan-mgmt"},
                {
                    "address": "2001:db8:1::1/64",
                    "from-pool": "pool-wan",
                    "interface": "vlan-mgmt",
                },
                {
                    "address": "2001:db8:2::1/64",
                    "from-pool": "pool-wan",
                    "interface": "lo",
                },
            ]
        )
        run(basics, {"/ipv6/address": res})
        self.assertEqual(res.ops, [("remove", "*3")])


class TestMakeInternalBasics(unittest.TestCase):
    def test_vrrp_group_authority(self) -> None:
        basics = make_internal_basics(PLAN, mtik_router("router"), "community")
        vrrp = {row["name"]: row for row in rows(basics, "/interface/vrrp")}
        self.assertEqual(vrrp["vrrp-mgmt-dns"]["group-authority"], "self")
        self.assertEqual(vrrp["vrrp-mgmt-dns"]["version"], "2")
        self.assertEqual(vrrp["vrrp-mgmt-dns6"]["v3-protocol"], "ipv6")
        self.assertEqual(vrrp["vrrp-mgmt-dns6"]["vrid"], "54")

    def test_backup_serves_redundant_vlans_only(self) -> None:
        basics = make_internal_basics(PLAN, mtik_router("router-backup"), "community")
        servers = {row["name"]: row for row in rows(basics, "/ip/dhcp-server")}
        self.assertEqual(servers["dhcp-mgmt"]["address-pool"], "pool-mgmt")
        self.assertEqual(servers["dhcp-retro"]["address-pool"], "static-only")
        self.assertEqual(servers["dhcp-mgmt"]["authoritative"], "after-10sec-delay")
        pools = [row["name"] for row in rows(basics, "/ip/pool")]
        self.assertEqual(pools, ["pool-mgmt", "pool-oob"])

    def test_public_ipv6_on_primary_only(self) -> None:
        primary = make_internal_basics(PLAN, mtik_router("router"), "community")
        backup = make_internal_basics(PLAN, mtik_router("router-backup"), "community")
        self.assertIn(
            {
                "from-pool": "pool-wan",
                "interface": "vlan-mgmt",
                "address": "::1:0:0:0:1",
                "from-pool-policy": "strict",
                "advertise": "true",
            },
            rows(primary, "/ipv6/address"),
        )
        self.assertFalse(
            any("from-pool" in row for row in rows(backup, "/ipv6/address"))
        )
        self.assertIn(
            {
                "address": "2001:db8:200::1/128",
                "interface": "wan",
                "advertise": "false",
            },
            rows(backup, "/ipv6/address"),
        )

    def test_local_ip_list(self) -> None:
        basics = make_internal_basics(PLAN, mtik_router("router"), "community")
        local = {row["address"] for row in rows(basics, "/ip/firewall/address-list")}
        self.assertEqual(
            local,
            {"10.1.1.1", "10.1.0.53", "10.7.1.1", "10.99.1.1", "10.99.0.1"},
        )

    def test_bgp_uses_own_s2s_address(self) -> None:
        basics = make_internal_basics(PLAN, mtik_router("router-backup"), "community")
        [instance] = rows(basics, "/routing/bgp/instance")
        [connection] = rows(basics, "/routing/bgp/connection")
        self.assertEqual(instance["router-id"], "10.99.1.2")
        self.assertEqual(connection["local.address"], "10.99.1.2")


class TestMakeRedfoxBasics(unittest.TestCase):
    def test_prefers_primary_router(self) -> None:
        basics = make_redfox_basics(PLAN)
        filters = {
            row["chain"]: row["rule"] for row in rows(basics, "/routing/filter/rule")
        }
        self.assertIn("set distance 50;", filters["router-in"])
        self.assertIn("set gw 2001:db8:f100::2;", filters["router-in"])
        self.assertIn("set distance 60;", filters["router-backup-in"])
        connections = {
            row["name"]: row for row in rows(basics, "/routing/bgp/connection")
        }
        self.assertEqual(
            connections["bgp-router-backup"]["remote.address"], "10.99.1.2/32"
        )


if __name__ == "__main__":
    unittest.main()
