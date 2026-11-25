import unittest
from typing import Any

from dnssync.cloudns import sync
from dnssync.cloudns.desired import DynamicRecord, Zone
from dnssync.cloudns.records import LiveRecord, Record


def live(id: str, type: str, host: str, value: str, ttl: int = 3600, **extra: Any):
    raw = {"id": id, "type": type, "host": host, "record": value, "ttl": str(ttl)}
    raw.update({k: str(v) for k, v in extra.items()})
    return LiveRecord.from_api(raw)


def make_zone() -> Zone:
    return Zone(
        name="foxden.network",
        nameservers=["ns1.example.net"],
        records=[
            Record.make("CNAME", "www", "web.foxden.network.", 3600),
            Record.make("MX", "", "mail.foxden.network", 3600, priority=10),
            Record.make("SSHFP", "nvr", "ABCD", 3600, algorithm=4, fptype=2),
            Record.make("AAAA", "v6", "fd00:0::1", 300),
        ],
        apex_ns=[
            Record.make("NS", "", "ns1.example.net", 86400),
            Record.make("NS", "", "ns3.foxden.network", 86400),
        ],
        dynamic=[
            DynamicRecord(
                Record.make("A", "gw", "127.0.0.1", 300), "gw.foxden.network", "x"
            ),
            DynamicRecord(
                Record.make("AAAA", "gw", "::1", 300), "gw.foxden.network", "::5"
            ),
        ],
    )


def in_sync() -> list[LiveRecord]:
    return [
        live("1", "CNAME", "www", "WEB.foxden.network"),
        live("2", "MX", "", "mail.foxden.network", priority=10),
        # ClouDNS calls it fp_type, and may change the case
        live("3", "SSHFP", "nvr", "abcd", algorithm=4, fp_type=2),
        live("4", "AAAA", "v6", "fd00::1", 300),
        # TTL picked by ClouDNS
        live("5", "NS", "", "ns1.example.net", 3600),
        live("6", "NS", "", "ns3.foxden.network", 86400),
        # Value kept by the routers
        live("7", "A", "gw", "203.0.113.4", 300),
        live("8", "AAAA", "gw", "2001:db8::5", 300),
    ]


class TestPlanZone(unittest.TestCase):
    def test_in_sync(self) -> None:
        plan = sync.plan_zone(make_zone(), in_sync())
        self.assertEqual(plan.changes, [])
        self.assertEqual(plan.warnings, [])

    def test_missing_zone(self) -> None:
        plan = sync.plan_zone(make_zone(), None)
        self.assertEqual(plan.changes[0].kind, sync.CREATE_ZONE)
        self.assertEqual(plan.count(sync.ADD), 8)

    def test_unmanaged_zone(self) -> None:
        zone = Zone(name="g.acme.foxden.network", nameservers=[], managed=False)
        self.assertEqual(sync.plan_zone(zone, []).changes, [])
        self.assertEqual(
            [c.kind for c in sync.plan_zone(zone, None).changes], [sync.CREATE_ZONE]
        )

    def test_changes(self) -> None:
        records = in_sync()
        records[1] = live("2", "MX", "", "mail.foxden.network", priority=20)
        records[6] = live("7", "A", "gw", "203.0.113.4", 3600)
        del records[3]
        records += [
            live("9", "TXT", "old", "stale"),
            live("10", "NS", "", "ns9.example.net"),
        ]
        plan = sync.plan_zone(make_zone(), records)

        by_kind = {k: [c for c in plan.changes if c.kind == k] for k in sync.ORDER}
        self.assertEqual(
            [c.record for c in by_kind[sync.ADD]],
            [Record("AAAA", "v6", "fd00:0::1", 300)],
        )
        self.assertEqual(
            [(c.live.id if c.live else None, c.record) for c in by_kind[sync.MODIFY]],
            [
                ("2", Record("MX", "", "mail.foxden.network", 3600, priority=10)),
                # Modifying a dynamic record keeps the routers' value
                ("7", Record("A", "gw", "203.0.113.4", 300)),
            ],
        )
        self.assertEqual([c.live.id for c in by_kind[sync.DELETE] if c.live], ["9"])
        # Unknown apex NS records are left alone
        self.assertEqual(len(plan.warnings), 1)

    def test_duplicates_are_deleted(self) -> None:
        records = in_sync() + [live("11", "CNAME", "www", "web.foxden.network")]
        plan = sync.plan_zone(make_zone(), records)
        self.assertEqual(
            [(c.kind, c.live and c.live.id) for c in plan.changes],
            [(sync.DELETE, "11")],
        )


class FakeClient:
    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []

    def dynamic_url(self, zone: str, record_id: str) -> str:
        self.calls.append((zone, record_id))
        return f"https://ipv4.cloudns.net/api/dynamicURL/?q=key{record_id}"


class TestDynamicKeys(unittest.TestCase):
    def test_keys(self) -> None:
        zone = make_zone()
        zone.dynamic.append(
            DynamicRecord(
                Record.make("A", "new", "127.0.0.1", 300), "new.foxden.network", "x"
            )
        )
        client = FakeClient()
        keys = sync.dynamic_keys(
            client,  # type: ignore[arg-type]
            {zone.name: zone},
            {zone.name: in_sync()},
        )
        # Records that don't exist yet are left out
        self.assertEqual(
            keys,
            {
                "gw.foxden.network": {
                    "ipv4": "key7",
                    "ipv6": "key8",
                    "ipv6_suffix": "::5",
                }
            },
        )


if __name__ == "__main__":
    unittest.main()
