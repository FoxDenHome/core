import unittest

from configure.dhcp import refresh_dhcp_router
from tests.fakes import FakeResource, FakeRouter, quiet

LEASES = "/ip/dhcp-server/lease"


def lease(name: str, ipv4: str, mac: str) -> dict[str, str]:
    return {"name": name, "ipv4": ipv4, "mac": mac}


def mtik(comment: str, address: str, mac: str, **extra: str) -> dict[str, str]:
    return {
        "address": address,
        "mac-address": mac,
        "comment": comment,
        "lease-time": "1d",
        "server": "dhcp-lan",
        "disabled": "false",
        **extra,
    }


def run(desired: list[dict[str, str]], deployed: list[dict[str, str]]) -> FakeResource:
    res = FakeResource(deployed)
    quiet(refresh_dhcp_router, desired, FakeRouter({LEASES: res}))
    return res


class TestRefreshDhcpRouter(unittest.TestCase):
    def test_adds_new_lease(self) -> None:
        res = run([lease("host", "10.2.10.5/32", "aa:bb:cc:dd:ee:ff")], [])
        self.assertEqual(
            res.attribs(),
            [
                {
                    **mtik("host", "10.2.10.5", "AA:BB:CC:DD:EE:FF"),
                    "dhcp-option": "",
                    "address-lists": "",
                }
            ],
        )

    def test_noop_when_in_sync(self) -> None:
        deployed = [
            mtik("host", "10.2.10.5", "AA:BB:CC:DD:EE:FF", status="bound"),
        ]
        res = run([lease("host", "10.2.10.5", "aa:bb:cc:dd:ee:ff")], deployed)
        self.assertEqual(res.ops, [])

    def test_updates_changed_lease(self) -> None:
        deployed = [mtik("host", "10.2.10.5", "11:11:11:11:11:11")]
        res = run([lease("host", "10.2.10.5", "aa:bb:cc:dd:ee:ff")], deployed)
        self.assertEqual(res.ops, [("set", "*1")])
        self.assertEqual(res.rows[0]["mac-address"], "AA:BB:CC:DD:EE:FF")

    def test_matches_by_mac_or_comment(self) -> None:
        for deployed in (
            mtik("other", "10.2.10.99", "AA:BB:CC:DD:EE:FF"),
            mtik("host", "10.2.10.99", "11:11:11:11:11:11"),
        ):
            res = run([lease("host", "10.2.10.5", "aa:bb:cc:dd:ee:ff")], [deployed])
            self.assertEqual(res.ops, [("set", "*1")])

    def test_removes_duplicate_matches(self) -> None:
        deployed = [
            mtik("host", "10.2.10.5", "11:11:11:11:11:11"),
            mtik("old", "10.2.10.6", "AA:BB:CC:DD:EE:FF"),
        ]
        res = run([lease("host", "10.2.10.5", "aa:bb:cc:dd:ee:ff")], deployed)
        self.assertEqual(res.ids(), ["*1"])
        self.assertEqual(res.rows[0]["mac-address"], "AA:BB:CC:DD:EE:FF")

    def test_recreates_over_dynamic_lease(self) -> None:
        deployed = [mtik("", "10.2.10.5", "AA:BB:CC:DD:EE:FF", dynamic="true")]
        res = run([lease("host", "10.2.10.5", "aa:bb:cc:dd:ee:ff")], deployed)
        self.assertEqual([op for op, _ in res.ops], ["remove", "add"])
        self.assertNotIn("dynamic", res.rows[0])

    def test_ignores_leases_on_other_servers(self) -> None:
        deployed = [
            mtik("host", "10.2.10.5", "AA:BB:CC:DD:EE:FF", server="dhcp-dmz"),
        ]
        res = run([lease("host", "10.2.10.5", "aa:bb:cc:dd:ee:ff")], deployed)
        self.assertEqual(len(res.rows), 1)
        self.assertEqual(res.rows[0]["server"], "dhcp-lan")
        self.assertIn(("remove", "*1"), res.ops)

    def test_removes_stray_static_keeps_dynamic(self) -> None:
        deployed = [
            mtik("stray", "10.2.10.7", "22:22:22:22:22:22"),
            mtik("", "10.2.10.8", "33:33:33:33:33:33", dynamic="true"),
        ]
        res = run([], deployed)
        self.assertEqual(res.ids(), ["*2"])

    def test_lease_without_ipv4_raises(self) -> None:
        with self.assertRaises(ValueError):
            run([{"name": "host", "mac": "aa:bb:cc:dd:ee:ff"}], [])


if __name__ == "__main__":
    unittest.main()
