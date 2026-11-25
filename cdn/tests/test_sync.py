import unittest
from typing import Any

from cdnsync import sync
from cdnsync.desired import Service, static_items
from cdnsync.sync import CREATE, DELETE, UPDATE


def svc(**kw: Any) -> Service:
    base: dict[str, Any] = {
        "name": "CDN",
        "entities": {
            "backend": {"dummy": {"address": "127.0.0.1", "port": 1}},
            "vcl": {"main": {"content": "sub vcl_recv {}", "main": True}},
            "dictionary": {"static_root": {}},
        },
        "settings": {"general.default_ttl": 3600, "general.stale_if_error": False},
        "dictionary_items": {"static_root": {"/a": "YQ=="}},
        "domains": ["a.example", "b.example"],
        "domain_description": "CDN domain",
        "certificate_authority": "certainly",
    }
    base.update(kw)
    return Service(**base)


LIVE: dict[str, list[dict[str, Any]]] = {
    "backend": [{"name": "dummy", "address": "127.0.0.1", "port": 1, "weight": 100}],
    "vcl": [{"name": "main", "content": "sub vcl_recv {}", "main": True}],
    "dictionary": [{"name": "static_root", "id": "d1"}],
}


def actions(changes: list[sync.Change]) -> list[tuple[str, str, str]]:
    return [(c.action, c.what, c.name) for c in changes]


class EntitiesTest(unittest.TestCase):
    def test_in_sync(self) -> None:
        self.assertEqual(sync.diff_entities(svc().entities, LIVE), [])

    def test_create_update_delete(self) -> None:
        live = {
            **LIVE,
            "backend": [{"name": "dummy", "address": "127.0.0.1", "port": "2"}],
            "snippet": [{"name": "stray"}],
            "dictionary": [],
        }
        changes = sync.diff_entities(svc().entities, live)
        self.assertEqual(
            actions(changes),
            [
                (UPDATE, "backend", "dummy"),
                (CREATE, "dictionary", "static_root"),
                (DELETE, "snippet", "stray"),
            ],
        )
        self.assertEqual(changes[0].differs, ["port"])
        self.assertEqual(changes[1].fields, {"name": "static_root"})

    def test_settings_normalized(self) -> None:
        want = {"general.default_ttl": 3600, "general.stale_if_error": False}
        have = {"general.default_ttl": "3600", "general.stale_if_error": False}
        self.assertEqual(sync.diff_settings(want, have), [])
        changes = sync.diff_settings(want, {**have, "general.default_ttl": 60})
        self.assertEqual(changes[0].differs, ["general.default_ttl"])


class ItemsTest(unittest.TestCase):
    def test_diff(self) -> None:
        changes = sync.diff_items(
            "d", {"/a": "1", "/b": "2", "/c": "3"}, {"/a": "1", "/b": "x", "/z": "9"}
        )
        self.assertEqual(
            actions(changes),
            [
                (UPDATE, "item d", "/b"),
                (CREATE, "item d", "/c"),
                (DELETE, "item d", "/z"),
            ],
        )

    def test_static_items(self) -> None:
        from pathlib import Path
        from tempfile import TemporaryDirectory

        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".well-known").mkdir()
            (root / ".well-known" / "x").write_bytes(b"hi")
            (root / "y.meta").write_text("content-type=text/plain")
            self.assertEqual(
                static_items(root),
                {
                    "/.well-known/x": "aGk=",
                    "/y.meta": "Y29udGVudC10eXBlPXRleHQvcGxhaW4=",
                },
            )


class DomainsTest(unittest.TestCase):
    def test_diff(self) -> None:
        have = [
            {"id": "1", "fqdn": "a.example", "description": "CDN domain"},
            {"id": "2", "fqdn": "c.example", "description": "CDN domain"},
        ]
        changes = sync.diff_domains(svc(), have)
        self.assertEqual(
            actions(changes),
            [(CREATE, "domain", "b.example"), (DELETE, "domain", "c.example")],
        )
        self.assertEqual(changes[1].ref, "2")

    def test_description(self) -> None:
        have = [
            {"id": "1", "fqdn": "a.example", "description": "old"},
            {"id": "2", "fqdn": "b.example", "description": "CDN domain"},
        ]
        changes = sync.diff_domains(svc(), have)
        self.assertEqual(actions(changes), [(UPDATE, "domain", "a.example")])


def sub(sid: str, domains: list[str], ca: str = "certainly", auths=()) -> dict:
    return {
        "id": sid,
        "attributes": {"certificate_authority": ca, "state": "issued"},
        "relationships": {
            "tls_domains": {"data": [{"id": d} for d in domains]},
            "tls_authorizations": {"data": [{"id": a} for a in auths]},
        },
    }


class TlsTest(unittest.TestCase):
    def test_missing(self) -> None:
        found, changes, _ = sync.find_subscription(svc(), [sub("o", ["other"])])
        self.assertIsNone(found)
        self.assertEqual(
            actions(changes), [(CREATE, "tls subscription", "a.example,b.example")]
        )

    def test_in_sync(self) -> None:
        found, changes, warnings = sync.find_subscription(
            svc(), [sub("s", ["b.example", "a.example"])]
        )
        self.assertEqual((found or {})["id"], "s")
        self.assertEqual((changes, warnings), ([], []))

    def test_domains_and_ca(self) -> None:
        _, changes, warnings = sync.find_subscription(
            svc(), [sub("s", ["a.example"], ca="lets-encrypt")]
        )
        self.assertEqual(changes[0].action, UPDATE)
        self.assertEqual(changes[0].ref, "s")
        self.assertEqual(len(warnings), 1)

    def test_several(self) -> None:
        found, changes, warnings = sync.find_subscription(
            svc(), [sub("s", ["a.example"]), sub("t", ["b.example"])]
        )
        self.assertIsNone(found)
        self.assertEqual(changes, [])
        self.assertEqual(len(warnings), 1)

    def test_dns_check(self) -> None:
        s = sub("s", ["a.example", "b.example"], auths=["x"])
        included = [
            {
                "type": "tls_authorization",
                "id": "x",
                "attributes": {
                    "challenges": [
                        {
                            "type": "managed-dns",
                            "record_name": "_acme-challenge.a.example",
                            "values": ["v"],
                        },
                        {
                            "type": "managed-http-cname",
                            "record_name": "a.example",
                            "values": ["t.fastly.net"],
                        },
                        {
                            "type": "managed-http-cname",
                            "record_name": "b.example",
                            "values": ["t.fastly.net"],
                        },
                    ]
                },
            },
            {
                "type": "tls_authorization",
                "id": "other",
                "attributes": {"challenges": []},
            },
        ]
        targets = sync.fastly_targets(s, included)
        self.assertEqual(
            targets, {"a.example": {"t.fastly.net"}, "b.example": {"t.fastly.net"}}
        )
        nix = {"a.example": {"t.fastly.net"}, "b.example": set()}
        warnings = sync.check_dns(targets, nix)
        self.assertEqual(len(warnings), 1)
        self.assertIn("b.example", warnings[0])


class FakeClient:
    def __init__(self) -> None:
        self.calls: list[tuple] = []

    def __getattr__(self, name: str):
        def call(*args: Any) -> Any:
            self.calls.append((name, *args))
            if name == "clone_version":
                return 66
            if name == "validate_version":
                return {"status": "ok"}
            if name == "list_entities":
                return [{"name": "static_root", "id": "d1"}]
            return None

        return call


class ApplyTest(unittest.TestCase):
    def test_clones_validates_activates(self) -> None:
        plan = sync.Plan(service_id="sid", base_version=65, base_editable=False)
        plan.version = [
            sync.Change(UPDATE, "vcl", "main", {"content": "x"}),
            sync.Change(UPDATE, "settings", "", {"general.default_ttl": 1}),
            sync.Change(DELETE, "snippet", "stray"),
        ]
        plan.items = {"static_root": [sync.Change(DELETE, "item static_root", "/z")]}
        client = FakeClient()
        sync.apply(client, svc(), plan)  # type: ignore[arg-type]
        self.assertEqual(
            client.calls,
            [
                ("clone_version", "sid", 65),
                ("update_entity", "sid", 66, "vcl", "main", {"content": "x"}),
                ("update_settings", "sid", 66, {"general.default_ttl": 1}),
                ("delete_entity", "sid", 66, "snippet", "stray"),
                ("validate_version", "sid", 66),
                ("activate_version", "sid", 66),
                ("list_entities", "sid", 66, "dictionary"),
                (
                    "batch_dictionary_items",
                    "sid",
                    "d1",
                    [{"op": "delete", "item_key": "/z"}],
                ),
            ],
        )

    def test_nothing_versioned(self) -> None:
        plan = sync.Plan(service_id="sid", base_version=65)
        plan.domains = [sync.Change(DELETE, "domain", "c.example", ref="2")]
        client = FakeClient()
        sync.apply(client, svc(), plan)  # type: ignore[arg-type]
        self.assertEqual(client.calls, [("delete_domain", "2")])


if __name__ == "__main__":
    unittest.main()
