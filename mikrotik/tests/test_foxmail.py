import json
import unittest
from os.path import join as path_join
from tempfile import TemporaryDirectory
from typing import Any
from unittest.mock import patch

from configure import foxmail
from tests.fakes import FakeRouter, quiet


class SyncRouter(FakeRouter):
    def __init__(self, host: str, changes: list[str]) -> None:
        super().__init__(host=host)
        self.changes = changes
        self.synced: list[tuple[str, dict[str, Any]]] = []
        self.restarted: list[str] = []

    def sync(self, src: str, dest: str) -> list[str]:
        with open(path_join(src, "config.yml")) as f:
            self.synced.append((dest, json.load(f)))
        return self.changes

    def restart_container(self, name: str) -> None:
        self.restarted.append(name)


BASE_CONFIG = {
    "sender": {"dkim": {"selector": "x"}},
    "receiver": {"smtp": {"domain": "x"}, "auth": {"subnets": {"a@b": ["1.2.3.4/32"]}}},
}


class TestFoxmail(unittest.TestCase):
    def test_per_router_config_and_restart(self) -> None:
        routers = [
            SyncRouter("router.foxden.network", ["config.yml"]),
            SyncRouter("router-backup.foxden.network", []),
        ]
        with TemporaryDirectory() as tmp:
            src = path_join(tmp, "src.json")
            with open(src, "w") as f:
                json.dump(BASE_CONFIG, f)
            with (
                patch.object(foxmail, "check_output", return_value=src.encode()),
                patch.object(foxmail, "OUT_PATH", path_join(tmp, "out")),
                patch.object(foxmail, "ROUTERS", routers),
            ):
                quiet(foxmail.refresh_foxmail)

        for router in routers:
            self.assertEqual(len(router.synced), 1)
            dest, config = router.synced[0]
            self.assertEqual(dest, "/foxmail")
            self.assertEqual(config["sender"]["proxy"], "socks5://10.99.10.1:1080")
            self.assertEqual(config["sender"]["domain"], "redfox.doridian.net")
            self.assertEqual(
                config["sender"]["dkim"]["selector"], router.host.split(".")[0]
            )
            self.assertEqual(config["receiver"]["smtp"]["domain"], router.host)
            self.assertEqual(
                config["receiver"]["auth"]["subnets"],
                {
                    "a@b": ["1.2.3.4/32"],
                    "router@foxden.network": ["172.17.1.1/32"],
                    "router-backup@foxden.network": ["172.17.1.1/32"],
                },
            )

        self.assertEqual(routers[0].restarted, ["foxmail"])
        self.assertEqual(routers[1].restarted, [])


if __name__ == "__main__":
    unittest.main()
