import unittest

from configure.util import (
    MTikRouter,
    format_mtik_bool,
    format_mtik_duration,
    format_weird_mtik_ip,
    get_ipv4_netname,
    is_ipv6,
    parse_mtik_bool,
)


class TestUtil(unittest.TestCase):
    def test_format_mtik_bool(self) -> None:
        self.assertEqual(format_mtik_bool(True), "true")
        self.assertEqual(format_mtik_bool(False), "false")

    def test_parse_mtik_bool(self) -> None:
        self.assertTrue(parse_mtik_bool("true"))
        self.assertTrue(parse_mtik_bool(True))
        self.assertFalse(parse_mtik_bool("false"))
        self.assertFalse(parse_mtik_bool(False))
        with self.assertRaises(ValueError):
            parse_mtik_bool("yes")

    def test_is_ipv6(self) -> None:
        self.assertTrue(is_ipv6("fd2c::1"))
        self.assertTrue(is_ipv6("fd2c::/60"))
        self.assertFalse(is_ipv6("10.2.1.1"))
        self.assertFalse(is_ipv6("10.2.0.0/16"))

    def test_format_weird_mtik_ip(self) -> None:
        self.assertEqual(format_weird_mtik_ip("10.2.1.1/32"), "10.2.1.1")
        self.assertEqual(format_weird_mtik_ip("10.2.1.1"), "10.2.1.1")
        self.assertEqual(format_weird_mtik_ip("10.2.0.0/16"), "10.2.0.0/16")
        self.assertEqual(format_weird_mtik_ip("fd2c::1"), "fd2c::1/128")
        self.assertEqual(format_weird_mtik_ip("fd2c::/60"), "fd2c::/60")

    def test_format_mtik_duration(self) -> None:
        self.assertEqual(format_mtik_duration(0), "0s")
        self.assertEqual(format_mtik_duration(59), "59s")
        self.assertEqual(format_mtik_duration(60), "1m")
        self.assertEqual(format_mtik_duration(3600), "1h")
        self.assertEqual(format_mtik_duration(3661), "1h1m1s")
        self.assertEqual(format_mtik_duration(86400), "1d")
        self.assertEqual(format_mtik_duration(90061), "1d1h1m1s")
        self.assertEqual(format_mtik_duration(86405), "1d5s")

    def test_get_ipv4_netname(self) -> None:
        vlans = [
            {"name": "mgmt", "ipv4": {"network": "10.1.0.0/16"}},
            {"name": "lan", "ipv4": {"network": "10.2.0.0/16"}},
            {"name": "retro", "ipv4": {"network": "10.7.0.0/16"}},
            {"name": "cghmn", "ipv4": {"network": "100.68.41.0/24"}},
            {"name": "wolnet", "ipv4": None},
        ]
        self.assertEqual(get_ipv4_netname("10.1.0.5", vlans), "mgmt")
        self.assertEqual(get_ipv4_netname("10.2.10.5/32", vlans), "lan")
        self.assertEqual(get_ipv4_netname("10.7.0.1", vlans), "retro")
        self.assertEqual(get_ipv4_netname("100.68.41.9", vlans), "cghmn")
        for ip in ("192.168.1.1", "100.68.42.1", "10.3.0.1"):
            with self.assertRaises(ValueError):
                get_ipv4_netname(ip, vlans)

    def test_connection_requires_ensure_user(self) -> None:
        router = MTikRouter(
            host="router.example",
            horizon="internal",
            vrrp_priority_online=1,
            vrrp_priority_offline=0,
            dyndns_suffix_ipv6="::1",
        )
        with self.assertRaises(RuntimeError):
            router.connection()


if __name__ == "__main__":
    unittest.main()
