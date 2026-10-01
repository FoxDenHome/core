from collections.abc import Callable
from contextlib import redirect_stdout
from io import StringIO
from typing import Any, TypeVar

from configure.util import MTikScript

T = TypeVar("T")


class FakeResource:
    """Simulates an ordered RouterOS resource table (e.g. /ip/firewall/filter)."""

    def __init__(self, rows: list[dict[str, str]]) -> None:
        self._next_id = 1
        self.rows: list[dict[str, str]] = []
        for row in rows:
            self.rows.append({"id": self._new_id(), **row})
        self.ops: list[tuple[str, ...]] = []

    def _new_id(self) -> str:
        rid = f"*{self._next_id:X}"
        self._next_id += 1
        return rid

    def _index(self, rid: str) -> int:
        for i, row in enumerate(self.rows):
            if row["id"] == rid:
                return i
        raise KeyError(rid)

    def get(self, **query: str) -> list[dict[str, str]]:
        # Missing attributes are treated as matching (RouterOS omits defaults)
        return [
            dict(row)
            for row in self.rows
            if all(row.get(k, v) == v for k, v in query.items())
        ]

    def add(self, **attribs: str) -> None:
        place_before = attribs.pop("place-before", None)
        row = {"id": self._new_id(), **attribs}
        if place_before is None:
            self.rows.append(row)
        else:
            self.rows.insert(self._index(place_before), row)
        self.ops.append(("add", row["id"]))

    def set(self, id: str, **attribs: str) -> None:
        self.rows[self._index(id)].update(attribs)
        self.ops.append(("set", id))

    def remove(self, id: str) -> None:
        del self.rows[self._index(id)]
        self.ops.append(("remove", id))

    def call(self, command: str, arguments: dict[str, str]) -> None:
        if command == "move":
            row = self.rows.pop(self._index(arguments["numbers"]))
            destination = arguments.get("destination")
            if destination is None:
                self.rows.append(row)
            else:
                self.rows.insert(self._index(destination), row)
            self.ops.append(("move", arguments["numbers"]))
        else:
            self.ops.append((command, *arguments.values()))

    def attribs(self) -> list[dict[str, str]]:
        return [{k: v for k, v in row.items() if k != "id"} for row in self.rows]

    def ids(self) -> list[str]:
        return [row["id"] for row in self.rows]

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
    horizon = "internal"

    def __init__(
        self,
        resources: dict[str, FakeResource] | None = None,
        host: str = "fake-router",
        scripts: set[MTikScript] | None = None,
    ) -> None:
        self.host = host
        self.scripts = scripts or set()
        self.resources = resources if resources is not None else {}
        self._connection = FakeConnection(FakeApi(self.resources))

    def connection(self) -> FakeConnection:
        return self._connection


def quiet[T](fn: Callable[..., T], *args: Any, **kwargs: Any) -> T:
    with redirect_stdout(StringIO()):
        return fn(*args, **kwargs)
