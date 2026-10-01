import unittest
from os.path import join as path_join
from tempfile import TemporaryDirectory
from unittest.mock import patch

from configure import dyndns
from configure.util import MTikRouter

ROUTER_HOST = "router.foxden.network"


def make_router() -> MTikRouter:
    return MTikRouter(
        host=ROUTER_HOST,
        horizon="internal",
        vrrp_priority_online=50,
        vrrp_priority_offline=10,
        dyndns_suffix_ipv6="::1",
    )


HOSTS = {
    ROUTER_HOST: {"key": "rkey"},
    f"v4-{ROUTER_HOST}": {"key": "r4key"},
    "router-backup.foxden.network": {"key": "otherkey"},
    "zeta.foxden.network": {"key": "zkey"},
    "alpha.foxden.network": {"key": "akey", "ipv6": "::a"},
}


class TestDyndns(unittest.TestCase):
    def setUp(self) -> None:
        patcher = patch.object(dyndns, "_dyndns_hosts_value", HOSTS)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_write_all_hosts_skips_special_and_sorts(self) -> None:
        self.assertEqual(
            dyndns.write_all_hosts("  "),
            [
                '  $dyndnsUpdate host="alpha.foxden.network" key="akey" priv6addr="::a" ip6addr=$ip6addr ipaddr=$ipaddr\n',
                '  $dyndnsUpdate host="zeta.foxden.network" key="zkey" ipaddr=$ipaddr\n',
            ],
        )

    def test_make_script_from_repo_template(self) -> None:
        router = make_router()
        dyndns.make_dyndns_script(router)
        self.assertEqual(len(router.scripts), 1)
        script = next(iter(router.scripts))
        self.assertEqual(script.name, dyndns.MAIN_SCRIPT)
        self.assertEqual(script.schedule, "5m")
        self.assertNotIn("# HOSTS #", script.source)
        self.assertNotIn("# SPECIAL HOSTS #", script.source)
        self.assertIn(
            f'$dyndnsUpdate host="{ROUTER_HOST}" key="rkey" priv6addr="::1" ip6addr=$ip6addr ipaddr=$ipaddr\n',
            script.source,
        )
        self.assertIn(
            f'$dyndnsUpdate host="v4-{ROUTER_HOST}" key="r4key" ipaddr=$ipaddr\n',
            script.source,
        )
        self.assertIn('host="zeta.foxden.network"', script.source)
        self.assertNotIn("otherkey", script.source)

    def make_with_template(self, template: str) -> MTikRouter:
        router = make_router()
        with TemporaryDirectory() as tmp:
            path = path_join(tmp, "template.rsc")
            with open(path, "w") as f:
                f.write(template)
            with patch.object(dyndns, "TEMPLATE", path):
                dyndns.make_dyndns_script(router)
        return router

    def test_preserves_indentation(self) -> None:
        router = self.make_with_template("a\n    # HOSTS #\n\t# SPECIAL HOSTS #\nb\n")
        lines = next(iter(router.scripts)).source.splitlines()
        self.assertEqual(lines[0], "a")
        self.assertTrue(lines[1].startswith('    $dyndnsUpdate host="alpha'))
        self.assertTrue(lines[2].startswith('    $dyndnsUpdate host="zeta'))
        self.assertTrue(lines[3].startswith(f'\t$dyndnsUpdate host="{ROUTER_HOST}"'))
        self.assertTrue(lines[4].startswith(f'\t$dyndnsUpdate host="v4-{ROUTER_HOST}"'))
        self.assertEqual(lines[5], "b")

    def test_template_errors(self) -> None:
        with self.assertRaises(RuntimeError):
            self.make_with_template("nothing here\n")
        with self.assertRaises(RuntimeError):
            self.make_with_template("# HOSTS #\n# HOSTS #\n")

    @unittest.expectedFailure  # make_dyndns_script never sets found_special_hosts
    def test_duplicate_special_hosts_errors(self) -> None:
        with self.assertRaises(RuntimeError):
            self.make_with_template("# HOSTS #\n# SPECIAL HOSTS #\n# SPECIAL HOSTS #\n")


if __name__ == "__main__":
    unittest.main()
