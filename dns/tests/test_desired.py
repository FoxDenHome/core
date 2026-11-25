import unittest
from typing import Any

from dnssync.cloudns import desired
from dnssync.cloudns.records import Record


def rec(name: str, type: str, value: str, ttl: int = 3600, **extra: Any):
    return {"name": name, "type": type, "value": value, "ttl": ttl, **extra}


def make_dns() -> dict[str, Any]:
    ns = ["ns1.example.net.", "ns3.foxden.network."]
    return {
        "zones": {
            "foxden.network": {"registrar": "porkbun", "nameserverList": ns},
            "example.com": {"registrar": "inwx", "nameserverList": ns},
            "10.in-addr.arpa": {"registrar": "local", "nameserverList": ns},
        },
        "authorities": {
            "upstream": {"nameservers": ["pns41.cloudns.net.", "pns42.cloudns.net."]}
        },
        "records": {
            "external": {
                "foxden.network": [
                    rec("@", "NS", "ns1.example.net.", 86400),
                    rec("www", "CNAME", "web.foxden.network."),
                    rec("@", "mx", "mail.foxden.network.", priority=10),
                    rec("nvr", "SSHFP", "ABCD", algorithm=4, fptype=2),
                    rec("gw", "A", "0.0.0.1", 300, dynDns=True),
                    rec("gw", "AAAA", "::1:2", 300, dynDns=True),
                    rec("_acme-challenge.status", "TXT", "x", 300, dynDns=True),
                ],
                "example.com": [
                    rec("_acme-challenge", "TXT", "x", 300, dynDns=True, acmeGroup="g"),
                ],
                "10.in-addr.arpa": [rec("1", "PTR", "a.foxden.network.")],
            }
        },
    }


class TestBuild(unittest.TestCase):
    def setUp(self) -> None:
        self.zones = desired.build(
            make_dns(), {"sel._domainkey.example.com": "v=DKIM1; p=abc"}
        )

    def test_zones(self) -> None:
        self.assertEqual(
            sorted(self.zones),
            [
                "example.com",
                "foxden.network",
                "g.acme.foxden.network",
                "status-foxden-network.acme.foxden.network",
            ],
        )
        acme = self.zones["g.acme.foxden.network"]
        self.assertFalse(acme.managed)
        self.assertEqual(acme.nameservers, ["pns41.cloudns.net", "pns42.cloudns.net"])

    def test_in_zone_nameservers_are_not_given_at_creation(self) -> None:
        zone = self.zones["foxden.network"]
        self.assertEqual(zone.nameservers, ["ns1.example.net"])
        self.assertEqual(
            [r.value for r in zone.apex_ns], ["ns1.example.net", "ns3.foxden.network"]
        )
        self.assertEqual(
            self.zones["example.com"].nameservers,
            ["ns1.example.net", "ns3.foxden.network"],
        )

    def test_records(self) -> None:
        records = set(self.zones["foxden.network"].records)
        self.assertIn(Record("CNAME", "www", "web.foxden.network", 3600), records)
        self.assertIn(
            Record("MX", "", "mail.foxden.network", 3600, priority=10), records
        )
        self.assertIn(
            Record("SSHFP", "nvr", "ABCD", 3600, algorithm=4, fptype=2), records
        )
        # The ACME challenge becomes a CNAME into its zone, which is delegated
        self.assertIn(
            Record(
                "CNAME",
                "_acme-challenge.status",
                "_acme-challenge.status.foxden.network."
                "status-foxden-network.acme.foxden.network",
                300,
            ),
            records,
        )
        self.assertIn(
            Record("NS", "g.acme", "pns42.cloudns.net", 3600),
            records,
        )
        # Apex NS records aren't plain records
        self.assertFalse(any(r.type == "NS" and r.host == "" for r in records))

    def test_dynamic(self) -> None:
        dyn = self.zones["foxden.network"].dynamic
        self.assertEqual(
            [(d.record.type, d.record.value, d.fqdn, d.suffix) for d in dyn],
            [
                ("A", "127.0.0.1", "gw.foxden.network", "0.0.0.1"),
                ("AAAA", "::1", "gw.foxden.network", "::1:2"),
            ],
        )

    def test_dkim(self) -> None:
        self.assertIn(
            Record("TXT", "sel._domainkey", "v=DKIM1; p=abc", 3600),
            self.zones["example.com"].records,
        )

    def test_dkim_outside_public_zones(self) -> None:
        with self.assertRaises(ValueError):
            desired.build(make_dns(), {"sel._domainkey.nowhere.org": "v=DKIM1"})

    def test_invalid_ttl(self) -> None:
        dns = make_dns()
        dns["records"]["external"]["example.com"].append(rec("a", "A", "1.2.3.4", 5))
        with self.assertRaises(ValueError):
            desired.build(dns, {})

    def test_conflicting_records(self) -> None:
        dns = make_dns()
        dns["records"]["external"]["example.com"] += [
            rec("a", "A", "1.2.3.4", 300),
            rec("a", "A", "1.2.3.4", 3600),
        ]
        with self.assertRaises(ValueError):
            desired.build(dns, {})

    def test_acme_challenges(self) -> None:
        self.assertEqual(
            desired.acme_challenges(make_dns()),
            {
                "_acme-challenge.status.foxden.network": "status-foxden-network.acme.foxden.network",
                "_acme-challenge.example.com": "g.acme.foxden.network",
            },
        )


if __name__ == "__main__":
    unittest.main()
