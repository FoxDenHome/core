import json
import unittest
from os.path import join as path_join
from tempfile import TemporaryDirectory
from unittest.mock import patch

from configure import dashboard
from tests.fakes import FakeRouter, quiet


class SyncRouter(FakeRouter):
    def __init__(self, host: str, changes: list[str]) -> None:
        super().__init__(host=host)
        self.changes = changes
        self.synced: list[tuple[str, str]] = []

    def sync(self, src: str, dest: str) -> list[str]:
        with open(path_join(src, "config.json")) as f:
            self.synced.append((dest, f.read()))
        return self.changes


class TestDashboard(unittest.TestCase):
    def run_refresh(
        self, routers: list[SyncRouter], secrets: dict[str, object]
    ) -> None:
        with TemporaryDirectory() as tmp:
            config = path_join(tmp, "config.json")
            with open(config, "w") as f:
                f.write('{"title": "rack"}')
            secrets_path = path_join(tmp, "dashboard.yaml")
            open(secrets_path, "w").close()
            with (
                patch.object(
                    dashboard, "check_output", return_value=json.dumps(secrets)
                ),
                patch.object(dashboard, "CONFIG_PATH", config),
                patch.object(dashboard, "SECRETS_PATH", secrets_path),
                patch.object(dashboard, "OUT_PATH", path_join(tmp, "out")),
                patch.object(dashboard, "ROUTERS", routers),
            ):
                quiet(dashboard.refresh_dashboard)

    def test_config_secrets_and_restart(self) -> None:
        routers = [
            SyncRouter("router.foxden.network", ["config.json"]),
            SyncRouter("router-backup.foxden.network", []),
        ]
        self.run_refresh(routers, {"UNIFI_PASSWORD": "pw", "SNMP_COMMUNITY": "c"})

        for router in routers:
            self.assertEqual(router.synced, [("/dashboard", '{"title": "rack"}')])
            (container,) = router.containers
            self.assertEqual(container.name, "dashboard")
            self.assertEqual(
                container.env, (("SNMP_COMMUNITY", "c"), ("UNIFI_PASSWORD", "pw"))
            )
        self.assertEqual(routers[0].container_restarts, {"dashboard"})
        self.assertEqual(routers[1].container_restarts, set())

    def test_rejects_non_string_secret(self) -> None:
        with self.assertRaises(TypeError):
            self.run_refresh([], {"SNMP_COMMUNITY": 123})

    def test_missing_secrets_file(self) -> None:
        with (
            patch.object(dashboard, "SECRETS_PATH", "/nonexistent/dashboard.yaml"),
            self.assertRaises(FileNotFoundError),
        ):
            dashboard.load_secrets()


if __name__ == "__main__":
    unittest.main()
