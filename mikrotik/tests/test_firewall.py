import unittest
from contextlib import redirect_stdout
from io import StringIO

from configure.firewall import FirewallRule, refresh_firewall_router


class FakeResource:
    """Simulates an ordered RouterOS firewall table."""

    def __init__(self, rules: list[dict[str, str]]) -> None:
        self._next_id = 1
        self.rules: list[dict[str, str]] = []
        for rule in rules:
            self.rules.append({"id": self._new_id(), **rule})
        self.ops: list[tuple[str, ...]] = []

    def _new_id(self) -> str:
        rid = f"*{self._next_id:X}"
        self._next_id += 1
        return rid

    def _index(self, rid: str) -> int:
        for i, rule in enumerate(self.rules):
            if rule["id"] == rid:
                return i
        raise KeyError(rid)

    def get(self, **query: str) -> list[dict[str, str]]:
        assert query == {"dynamic": "false"}
        return [dict(rule) for rule in self.rules]

    def add(self, **attribs: str) -> None:
        place_before = attribs.pop("place-before", None)
        rule = {"id": self._new_id(), **attribs}
        if place_before is None:
            self.rules.append(rule)
        else:
            self.rules.insert(self._index(place_before), rule)
        self.ops.append(("add", rule["id"]))

    def remove(self, id: str) -> None:
        del self.rules[self._index(id)]
        self.ops.append(("remove", id))

    def call(self, command: str, arguments: dict[str, str]) -> None:
        assert command == "move", command
        rule = self.rules.pop(self._index(arguments["numbers"]))
        destination = arguments.get("destination")
        if destination is None:
            self.rules.append(rule)
        else:
            self.rules.insert(self._index(destination), rule)
        self.ops.append(("move", arguments["numbers"]))

    def attribs(self) -> list[dict[str, str]]:
        return [{k: v for k, v in rule.items() if k != "id"} for rule in self.rules]

    def ids(self) -> list[str]:
        return [rule["id"] for rule in self.rules]

    def count(self, op: str) -> int:
        return sum(1 for o in self.ops if o[0] == op)


class FakeApi:
    def __init__(self, resources: dict[str, FakeResource]) -> None:
        self.resources = resources

    def get_resource(self, path: str) -> FakeResource:
        if path not in self.resources:
            self.resources[path] = FakeResource([])
        return self.resources[path]


class FakeConnection:
    def __init__(self, api: FakeApi) -> None:
        self.api = api

    def get_api(self) -> FakeApi:
        return self.api


class FakeRouter:
    host = "fake-router"

    def __init__(self, resources: dict[str, FakeResource]) -> None:
        self._connection = FakeConnection(FakeApi(resources))

    def connection(self) -> FakeConnection:
        return self._connection


FILTER = "/ip/firewall/filter"


def r(name: str, **extra: str) -> dict[str, str]:
    return {"chain": "forward", "action": "accept", "comment": name, **extra}


def rule(
    name: str,
    families: list[str] | None = None,
    **extra: str,
) -> FirewallRule:
    return FirewallRule(
        families=families or ["ip"],
        table="filter",
        attribs=r(name, **extra),
    )


def run(desired: list[FirewallRule], deployed: dict[str, list[dict[str, str]]]):
    resources = {key: FakeResource(rules) for key, rules in deployed.items()}
    with redirect_stdout(StringIO()):
        refresh_firewall_router(desired, FakeRouter(resources))  # type: ignore[arg-type]
    return resources


class TestRefreshFirewallRouter(unittest.TestCase):
    def test_noop_when_in_sync(self) -> None:
        desired = [rule("a"), rule("b"), rule("c")]
        res = run(desired, {FILTER: [r("a"), r("b"), r("c")]})[FILTER]
        self.assertEqual(res.ops, [])

    def test_ignores_volatile_attributes(self) -> None:
        desired = [rule("a"), rule("b")]
        deployed = [
            {**r("a"), "packets": "5", "bytes": "100", ".about": "x"},
            {**r("b"), "invalid": "false", "dynamic": "false"},
        ]
        res = run(desired, {FILTER: deployed})[FILTER]
        self.assertEqual(res.ops, [])

    def test_respects_rule_ignore_changes(self) -> None:
        desired = [
            FirewallRule(
                families=["ip"],
                table="filter",
                attribs=r("a", **{"dst-address": "1.1.1.1"}),
                ignoreChanges={"dst-address"},
            )
        ]
        deployed = [r("a", **{"dst-address": "2.2.2.2"})]
        res = run(desired, {FILTER: deployed})[FILTER]
        self.assertEqual(res.ops, [])

    def test_adds_into_empty_table(self) -> None:
        desired = [rule("a"), rule("b")]
        res = run(desired, {})[FILTER]
        self.assertEqual(res.attribs(), [r("a"), r("b")])

    def test_insert_in_middle_keeps_existing_rules(self) -> None:
        desired = [rule("a"), rule("new"), rule("b"), rule("c")]
        res = run(desired, {FILTER: [r("a"), r("b"), r("c")]})[FILTER]
        before_ids = ["*1", "*2", "*3"]
        self.assertEqual(res.attribs(), [r("a"), r("new"), r("b"), r("c")])
        self.assertEqual(res.count("add"), 1)
        self.assertEqual(res.count("remove"), 0)
        self.assertEqual(res.count("move"), 0)
        self.assertEqual([i for i in res.ids() if i in before_ids], before_ids)

    def test_remove_from_middle_keeps_other_rules(self) -> None:
        desired = [rule("a"), rule("c")]
        res = run(desired, {FILTER: [r("a"), r("b"), r("c")]})[FILTER]
        self.assertEqual(res.attribs(), [r("a"), r("c")])
        self.assertEqual(res.ids(), ["*1", "*3"])
        self.assertEqual(res.ops, [("remove", "*2")])

    def test_reorder_uses_move(self) -> None:
        desired = [rule("c"), rule("a"), rule("b")]
        res = run(desired, {FILTER: [r("a"), r("b"), r("c")]})[FILTER]
        self.assertEqual(res.attribs(), [r("c"), r("a"), r("b")])
        self.assertEqual(sorted(res.ids()), ["*1", "*2", "*3"])
        self.assertEqual(res.ops, [("move", "*3")])

    def test_reorder_moves_to_end(self) -> None:
        desired = [rule("b"), rule("c"), rule("a")]
        res = run(desired, {FILTER: [r("a"), r("b"), r("c")]})[FILTER]
        self.assertEqual(res.attribs(), [r("b"), r("c"), r("a")])
        self.assertEqual(res.ops, [("move", "*1")])

    def test_reverse_uses_minimal_moves(self) -> None:
        names = ["a", "b", "c", "d"]
        desired = [rule(n) for n in reversed(names)]
        res = run(desired, {FILTER: [r(n) for n in names]})[FILTER]
        self.assertEqual(res.attribs(), [r(n) for n in reversed(names)])
        self.assertEqual(res.count("move"), 3)
        self.assertEqual(res.count("add"), 0)
        self.assertEqual(res.count("remove"), 0)

    def test_changed_rule_is_replaced_in_place(self) -> None:
        desired = [rule("a"), rule("b", protocol="tcp"), rule("c")]
        res = run(desired, {FILTER: [r("a"), r("b", protocol="udp"), r("c")]})[FILTER]
        self.assertEqual(res.attribs(), [r("a"), r("b", protocol="tcp"), r("c")])
        self.assertEqual(res.count("add"), 1)
        self.assertEqual(res.count("remove"), 1)
        self.assertEqual(res.count("move"), 0)
        self.assertEqual(res.ids()[0], "*1")
        self.assertEqual(res.ids()[2], "*3")

    def test_changed_rule_is_added_before_old_one_is_removed(self) -> None:
        desired = [rule("a", protocol="tcp")]
        res = run(desired, {FILTER: [r("a", protocol="udp")]})[FILTER]
        self.assertEqual([op for op, _ in res.ops], ["add", "remove"])

    def test_duplicate_rules(self) -> None:
        desired = [rule("a"), rule("b"), rule("a")]
        res = run(desired, {FILTER: [r("a"), r("a"), r("b")]})[FILTER]
        self.assertEqual(res.attribs(), [r("a"), r("b"), r("a")])
        self.assertEqual(res.count("add"), 0)
        self.assertEqual(res.count("remove"), 0)
        self.assertEqual(res.count("move"), 1)

    def test_mixed_add_remove_move(self) -> None:
        desired = [rule("x"), rule("d"), rule("a"), rule("new"), rule("c")]
        deployed = [r("a"), r("b"), r("c"), r("d")]
        res = run(desired, {FILTER: deployed})[FILTER]
        self.assertEqual(res.attribs(), [r("x"), r("d"), r("a"), r("new"), r("c")])
        self.assertEqual(res.count("add"), 2)
        self.assertEqual(res.count("remove"), 1)
        self.assertEqual(res.count("move"), 1)

    def test_families_and_tables_are_independent(self) -> None:
        desired = [
            rule("both", families=["ip", "ipv6"]),
            rule("v4"),
            rule("v6", families=["ipv6"]),
            FirewallRule(
                families=["ip"], table="nat", attribs=r("nat", chain="srcnat")
            ),
        ]
        res = run(
            desired,
            {
                FILTER: [r("v4"), r("both")],
                "/ipv6/firewall/filter": [r("both"), r("stale")],
            },
        )
        self.assertEqual(res[FILTER].attribs(), [r("both"), r("v4")])
        self.assertEqual(res[FILTER].ops, [("move", res[FILTER].ops[0][1])])
        self.assertEqual(res["/ipv6/firewall/filter"].attribs(), [r("both"), r("v6")])
        self.assertEqual(res["/ip/firewall/nat"].attribs(), [r("nat", chain="srcnat")])


if __name__ == "__main__":
    unittest.main()
