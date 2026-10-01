import json
import unittest
from os.path import join as path_join
from tempfile import TemporaryDirectory
from typing import Any
from unittest.mock import patch

from configure import dns
from tests.fakes import FakeResource, FakeRouter, quiet

STATIC = "/ip/dns/static"
FORWARDERS = "/ip/dns/forwarders"
ZONE = "foxden.network"


def raw(name: str, rectype: str, value: str, ttl: int = 3600, **extra: Any):
    return {
        "name": name,
        "zone": ZONE,
        "type": rectype,
        "value": value,
        "ttl": ttl,
        **extra,
    }


class TestDnsHelpers(unittest.TestCase):
    def tearDown(self) -> None:
        dns.INTERNAL_RECORDS = None

    def test_resolve_record_name(self) -> None:
        self.assertEqual(dns.resolve_record_name({"name": "a.b"}), "a.b")
        self.assertEqual(dns.resolve_record_name({"name": "@", "zone": ZONE}), ZONE)
        self.assertEqual(
            dns.resolve_record_name({"name": "www", "zone": ZONE}), f"www.{ZONE}"
        )

    def test_mtik_key_includes_unique_fields(self) -> None:
        self.assertEqual(
            dns.mtik_key({"type": "A", "name": "x", "address": "10.2.0.1"}),
            "A|x|address:10.2.0.1",
        )
        self.assertEqual(
            dns.mtik_key({"type": "NXDOMAIN", "name": "x", "address": "y"}),
            "NXDOMAIN|x",
        )
        self.assertNotEqual(
            dns.mtik_key(
                {"type": "SRV", "name": "x", "srv-port": "1", "srv-target": "t"}
            ),
            dns.mtik_key(
                {"type": "SRV", "name": "x", "srv-port": "2", "srv-target": "t"}
            ),
        )

    def test_remap_ipv6(self) -> None:
        self.assertEqual(
            dns.remap_ipv6("fd2c:f4cb:63be:2::101", "2001:db8:1234:5670::1"),
            "2001:db8:1234:5672::101",
        )

    def test_mtik_process_simple_types(self) -> None:
        self.assertEqual(
            dns.mtik_process(raw("host", "A", "10.2.0.1")),
            [{"type": "A", "address": "10.2.0.1", "ttl": "1h", "name": f"host.{ZONE}"}],
        )
        self.assertEqual(
            dns.mtik_process(raw("@", "mx", "mail.example.com.", priority=10)),
            [
                {
                    "type": "MX",
                    "mx-preference": "10",
                    "mx-exchange": "mail.example.com",
                    "ttl": "1h",
                    "name": ZONE,
                }
            ],
        )
        self.assertEqual(
            dns.mtik_process(
                raw(
                    "_sip._tcp",
                    "SRV",
                    "sip.example.com.",
                    port=5060,
                    weight=1,
                    priority=2,
                )
            ),
            [
                {
                    "type": "SRV",
                    "srv-port": "5060",
                    "srv-weight": "1",
                    "srv-priority": "2",
                    "srv-target": "sip.example.com",
                    "ttl": "1h",
                    "name": f"_sip._tcp.{ZONE}",
                }
            ],
        )

    def test_alias_flattens_to_target_addresses(self) -> None:
        dns.INTERNAL_RECORDS = {
            ZONE: [
                raw("target", "A", "10.2.0.1", ttl=60),
                raw("target", "AAAA", "fd2c::1", ttl=60),
            ]
        }
        self.assertEqual(
            dns.mtik_process(raw("alias", "ALIAS", f"target.{ZONE}.")),
            [
                {
                    "type": "A",
                    "address": "10.2.0.1",
                    "ttl": "1m",
                    "name": f"alias.{ZONE}",
                },
                {
                    "type": "AAAA",
                    "address": "fd2c::1",
                    "ttl": "1m",
                    "name": f"alias.{ZONE}",
                },
            ],
        )

    def test_alias_falls_back_to_cname(self) -> None:
        dns.INTERNAL_RECORDS = {ZONE: []}
        self.assertEqual(
            dns.mtik_process(raw("alias", "ALIAS", "external.example.com.")),
            [
                {
                    "type": "CNAME",
                    "cname": "external.example.com",
                    "ttl": "1h",
                    "name": f"alias.{ZONE}",
                }
            ],
        )


class TestRefreshDns(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(setattr, dns, "INTERNAL_RECORDS", None)

    def run_dns(self, records: list[dict[str, Any]], router: FakeRouter) -> None:
        path = path_join(self.tmp.name, "dns.json")
        with open(path, "w") as f:
            json.dump({"records": {"internal": {ZONE: records}}}, f)
        with (
            patch.object(dns, "check_output", return_value=path.encode()),
            patch.object(dns, "ROUTERS", [router]),
        ):
            quiet(dns.refresh_dns)

    def test_creates_records_and_is_idempotent(self) -> None:
        router = FakeRouter()
        records = [
            raw("host", "A", "10.2.0.1"),
            raw("host", "PTR", "ignored"),
            raw("txt", "TXT", "hello"),
        ]
        self.run_dns(records, router)
        static = router.resources[STATIC]
        names = {(r["type"], r["name"]) for r in static.rows}
        self.assertIn(("A", f"host.{ZONE}"), names)
        self.assertIn(("TXT", f"txt.{ZONE}"), names)
        self.assertNotIn("PTR", {t for t, _ in names})
        self.assertEqual(len(static.rows), 2 + len(dns.FIXED_RECORDS))
        self.assertEqual(
            {r["name"] for r in router.resources[FORWARDERS].rows},
            {f["name"] for f in dns.FIXED_FORWARDERS},
        )

        for res in router.resources.values():
            res.ops.clear()
        self.run_dns(records, router)
        self.assertEqual(static.ops, [])
        self.assertEqual(router.resources[FORWARDERS].ops, [])

    def test_updates_removes_stale_and_duplicates(self) -> None:
        a_record = {"type": "A", "name": f"host.{ZONE}", "address": "10.2.0.1"}
        router = FakeRouter(
            {
                STATIC: FakeResource(
                    [
                        {**a_record, "ttl": "5m"},
                        {**a_record, "ttl": "5m"},
                        {"type": "A", "name": f"gone.{ZONE}", "address": "10.2.0.9"},
                    ]
                ),
                FORWARDERS: FakeResource(
                    [
                        {"name": "getflix", "dns-servers": "1.1.1.1"},
                        {"name": "stale", "dns-servers": "1.1.1.1"},
                    ]
                ),
            }
        )
        self.run_dns([raw("host", "A", "10.2.0.1")], router)
        static = router.resources[STATIC]
        self.assertIn(("remove", "*2"), static.ops)
        self.assertIn(("remove", "*3"), static.ops)
        self.assertIn(("set", "*1"), static.ops)
        self.assertEqual(static.rows[0]["ttl"], "1h")

        forwarders = router.resources[FORWARDERS]
        self.assertIn(("set", "*1"), forwarders.ops)
        self.assertIn(("remove", "*2"), forwarders.ops)
        self.assertEqual(
            forwarders.rows[0]["dns-servers"], "54.187.61.200,169.55.51.86"
        )


if __name__ == "__main__":
    unittest.main()
