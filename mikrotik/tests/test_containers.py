import unittest
from dataclasses import replace
from unittest.mock import patch

from configure import dashboard, foxingress, foxmail
from configure.containers import parse_image_ref, refresh_containers_router
from configure.util import CONTAINER_HOST, ROUTER_HOST, MTikContainer
from tests.fakes import FakeResource, FakeRouter, quiet

CONTAINER = "/container"
VETH = "/interface/veth"
IP = "/ip/address"
IPV6 = "/ipv6/address"
MEMBER = "/interface/list/member"

CT = MTikContainer(
    name="foxmail",
    remote_image="git.foxden.network/foxden/foxmail:latest",
    subnet=1,
    mounts=("/foxmail:/config:ro", "/foxmail-data:/data:rw"),
)
TOR = MTikContainer(name="tor", remote_image="x/tor", subnet=2)


class FakeContainers(FakeResource):
    """Container table whose stop/start/repull/add take effect immediately."""

    def __init__(self, rows: list[dict[str, str]], image_id: str) -> None:
        super().__init__(rows)
        self.image_id = image_id

    def _by_name(self, name: str) -> dict[str, str]:
        return next(row for row in self.rows if row["name"] == name)

    def add(self, **attribs: str) -> None:
        super().add(**attribs, **{"image-id": self.image_id, "stopped": "true"})

    def call(self, command: str, arguments: dict[str, str]) -> None:
        super().call(command, arguments)
        row = self._by_name(arguments.get("numbers") or arguments["number"])
        if command == "stop":
            row.pop("running", None)
            row["stopped"] = "true"
        elif command == "start":
            row.pop("stopped", None)
            row["running"] = "true"
        elif command == "repull":
            row["image-id"] = self.image_id


def ct_row(container: MTikContainer, **extra: str) -> dict[str, str]:
    return {**container.attribs(), "image-id": "new", "running": "true", **extra}


def network_rows(*containers: MTikContainer) -> dict[str, list[dict[str, str]]]:
    return {
        VETH: [ct.veth_attribs() for ct in containers],
        IP: [ct.ip_address_attribs() for ct in containers],
        IPV6: [ct.ipv6_address_attribs() for ct in containers],
        MEMBER: [
            {"list": "zone-local", "interface": ct.interface} for ct in containers
        ],
    }


def run(
    wanted: list[MTikContainer],
    deployed: list[dict[str, str]],
    network: dict[str, list[dict[str, str]]] | None = None,
    restarts: set[str] | None = None,
) -> FakeRouter:
    resources = {
        CONTAINER: FakeContainers(deployed, image_id="new"),
        "/system/resource": FakeResource([{"architecture-name": "arm64"}]),
    }
    if network is None:
        network = network_rows(*wanted)
    for path, rows in network.items():
        resources[path] = FakeResource(rows)
    router = FakeRouter(resources, containers=set(wanted))
    router.container_restarts = restarts or set()
    resolved: list[tuple[str, str, str]] = []

    def resolve(ref: str, os: str, arch: str) -> str:
        resolved.append((ref, os, arch))
        return "new"

    with patch("configure.containers.sleep"):
        quiet(refresh_containers_router, router, resolve)
    for ref in resolved:
        assert ref[1:] == ("linux", "arm64"), ref
    return router


class TestMTikContainer(unittest.TestCase):
    def test_addressing(self) -> None:
        self.assertEqual(CT.interface, "veth-foxmail")
        self.assertEqual(CT.ipv4(ROUTER_HOST), "172.17.1.1")
        self.assertEqual(CT.ipv4(CONTAINER_HOST), "172.17.1.2")
        self.assertEqual(CT.ipv6(ROUTER_HOST), "fd2c:f4cb:63be::ac11:101")
        self.assertEqual(CT.ipv6(CONTAINER_HOST), "fd2c:f4cb:63be::ac11:102")
        self.assertEqual(CT.attribs()["dns"], "172.17.1.1")
        self.assertEqual(
            CT.veth_attribs(),
            {
                "name": "veth-foxmail",
                "address": "172.17.1.2/24,fd2c:f4cb:63be::ac11:102/120",
                "gateway": "172.17.1.1",
                "gateway6": "fd2c:f4cb:63be::ac11:101",
                "dhcp": "false",
            },
        )

    def test_subnet_range(self) -> None:
        with self.assertRaises(ValueError):
            MTikContainer(name="x", remote_image="x", subnet=256)

    def test_repo_containers(self) -> None:
        self.assertEqual(foxingress.CONTAINER.interface, "veth-foxingress")
        self.assertEqual(foxingress.CONTAINER.subnet, 0)
        self.assertEqual(foxmail.CONTAINER.interface, "veth-foxmail")
        self.assertEqual(foxmail.CONTAINER.subnet, 1)
        self.assertEqual(dashboard.CONTAINER.interface, "veth-dashboard")
        self.assertEqual(dashboard.CONTAINER.subnet, 2)

    def test_env_is_hidden(self) -> None:
        container = MTikContainer(
            name="x", remote_image="x", subnet=3, env=(("KEY", "secret"),)
        )
        self.assertNotIn("secret", repr(container))
        self.assertEqual(container.attribs()["envlists"], "x")
        self.assertEqual(CT.attribs()["envlists"], "")


class TestParseImageRef(unittest.TestCase):
    def test_parse(self) -> None:
        self.assertEqual(
            parse_image_ref("git.foxden.network/foxden/foxmail:latest"),
            ("git.foxden.network", "foxden/foxmail", "latest"),
        )
        self.assertEqual(
            parse_image_ref("alpine"),
            ("registry-1.docker.io", "library/alpine", "latest"),
        )
        self.assertEqual(
            parse_image_ref("docker.io/foo/bar:2"),
            ("registry-1.docker.io", "foo/bar", "2"),
        )
        self.assertEqual(
            parse_image_ref("host:5000/x/y"), ("host:5000", "x/y", "latest")
        )


class TestRefreshContainersRouter(unittest.TestCase):
    def test_noop_when_up_to_date(self) -> None:
        router = run([CT], [ct_row(CT)])
        for resource in router.resources.values():
            self.assertEqual(resource.ops, [])

    def test_creates_everything(self) -> None:
        router = run([CT], [], {})
        res = router.resources
        self.assertEqual(res[CONTAINER].ops, [("add", "*1"), ("start", "foxmail")])
        self.assertEqual(res[CONTAINER].attribs()[0]["root-dir"], "/foxmail-root")
        self.assertEqual(res[VETH].attribs(), [CT.veth_attribs()])
        self.assertEqual(res[IP].attribs(), [CT.ip_address_attribs()])
        self.assertEqual(res[IPV6].attribs(), [CT.ipv6_address_attribs()])
        self.assertEqual(
            res[MEMBER].attribs(), [{"list": "zone-local", "interface": CT.interface}]
        )

    def test_repulls_outdated_image(self) -> None:
        router = run([CT], [ct_row(CT, **{"image-id": "old"})])
        containers = router.resources[CONTAINER]
        self.assertEqual(
            containers.ops,
            [
                ("stop", "foxmail"),
                ("repull", "foxmail", CT.remote_image),
                ("start", "foxmail"),
            ],
        )
        self.assertEqual(containers.rows[0]["image-id"], "new")
        self.assertIn("running", containers.rows[0])

    def test_requested_restart(self) -> None:
        router = run([CT], [ct_row(CT)], restarts={"foxmail"})
        self.assertEqual(
            router.resources[CONTAINER].ops, [("stop", "foxmail"), ("start", "foxmail")]
        )

    def test_requested_restart_folds_into_repull(self) -> None:
        router = run([CT], [ct_row(CT, **{"image-id": "old"})], restarts={"foxmail"})
        self.assertEqual(router.resources[CONTAINER].count("start"), 1)
        self.assertEqual(router.resources[CONTAINER].count("repull"), 1)

    def test_requested_restart_of_new_container(self) -> None:
        router = run([CT], [], {}, restarts={"foxmail"})
        self.assertEqual(
            router.resources[CONTAINER].ops, [("add", "*1"), ("start", "foxmail")]
        )

    def test_updates_changed_config(self) -> None:
        router = run([CT], [ct_row(CT, dns="1.1.1.1")])
        containers = router.resources[CONTAINER]
        self.assertEqual(
            containers.ops,
            [("stop", "foxmail"), ("set", "*1"), ("start", "foxmail")],
        )
        self.assertEqual(containers.rows[0]["dns"], "172.17.1.1")

    def test_veth_change_restarts_container(self) -> None:
        network = network_rows(CT)
        network[VETH] = [{**CT.veth_attribs(), "gateway": "172.17.9.1"}]
        router = run([CT], [ct_row(CT)], network)
        self.assertEqual(router.resources[VETH].ops, [("set", "*1")])
        self.assertEqual(router.resources[VETH].attribs(), [CT.veth_attribs()])
        self.assertEqual(
            router.resources[CONTAINER].ops, [("stop", "foxmail"), ("start", "foxmail")]
        )

    def test_fixes_router_side_addresses(self) -> None:
        network = network_rows(CT)
        network[IP] = [{"address": "172.17.9.1/24", "interface": CT.interface}]
        network[IPV6] = [
            {**CT.ipv6_address_attribs(), "advertise": "true"},
            {"address": "fe80::1/64", "interface": CT.interface, "dynamic": "true"},
        ]
        network[MEMBER] = [{"list": "zone-wan", "interface": CT.interface}]
        router = run([CT], [ct_row(CT)], network)
        res = router.resources
        self.assertEqual(res[IP].attribs(), [CT.ip_address_attribs()])
        self.assertEqual(res[IPV6].ops, [("set", "*1")])
        self.assertEqual(res[IPV6].attribs()[0], CT.ipv6_address_attribs())
        self.assertEqual(len(res[IPV6].rows), 2)
        self.assertIn(
            {"list": "zone-local", "interface": CT.interface}, res[MEMBER].attribs()
        )
        self.assertIn(
            {"list": "zone-wan", "interface": CT.interface}, res[MEMBER].attribs()
        )
        self.assertEqual(res[CONTAINER].ops, [])

    def test_removes_leftovers(self) -> None:
        network = network_rows(CT, TOR)
        network[IPV6].append({"interface": "*37", "address": "fd00::1/120"})
        network[IPV6].append(
            {"interface": TOR.interface, "address": "fe80::1/64", "dynamic": "true"}
        )
        network["/container/mounts"] = [{"list": "pdns-config"}]
        network["/container/envs"] = [{"list": "pdns"}]
        router = run([CT], [ct_row(CT), ct_row(TOR)], network)
        res = router.resources
        self.assertEqual([r["name"] for r in res[CONTAINER].rows], ["foxmail"])
        self.assertEqual(res["/container/mounts"].rows, [])
        self.assertEqual(res["/container/envs"].rows, [])
        self.assertEqual(res[VETH].attribs(), [CT.veth_attribs()])
        self.assertEqual(res[IP].attribs(), [CT.ip_address_attribs()])
        self.assertEqual(
            [r["interface"] for r in res[IPV6].rows], [CT.interface, TOR.interface]
        )
        self.assertEqual([r["interface"] for r in res[MEMBER].rows], [CT.interface])

    def test_creates_env_list(self) -> None:
        ct = replace(CT, env=(("A", "1"), ("B", "2")))
        router = run([ct], [])
        envs = router.resources["/container/envs"]
        self.assertEqual(
            envs.attribs(),
            [
                {"list": "foxmail", "key": "A", "value": "1"},
                {"list": "foxmail", "key": "B", "value": "2"},
            ],
        )
        self.assertEqual(router.resources[CONTAINER].rows[0]["envlists"], "foxmail")

    def test_env_noop_when_up_to_date(self) -> None:
        ct = replace(CT, env=(("A", "1"),))
        network = network_rows(ct)
        network["/container/envs"] = [{"list": "foxmail", "key": "A", "value": "1"}]
        router = run([ct], [ct_row(ct)], network)
        self.assertEqual(router.resources[CONTAINER].ops, [])
        self.assertEqual(router.resources["/container/envs"].ops, [])

    def test_env_change_restarts_container(self) -> None:
        ct = replace(CT, env=(("A", "2"),))
        network = network_rows(ct)
        network["/container/envs"] = [
            {"list": "foxmail", "key": "A", "value": "1"},
            {"list": "pdns", "key": "X", "value": "y"},
        ]
        router = run([ct], [ct_row(ct)], network)
        self.assertEqual(
            router.resources["/container/envs"].attribs(),
            [{"list": "foxmail", "key": "A", "value": "2"}],
        )
        self.assertEqual(router.resources[CONTAINER].count("stop"), 1)
        self.assertEqual(router.resources[CONTAINER].count("start"), 1)

    def test_rejects_duplicate_subnets(self) -> None:
        clash = MTikContainer(name="other", remote_image="x", subnet=CT.subnet)
        with self.assertRaises(ValueError):
            run([CT, clash], [])


if __name__ == "__main__":
    unittest.main()
