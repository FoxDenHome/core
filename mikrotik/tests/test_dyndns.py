import unittest
from ipaddress import IPv6Address
from os.path import join as path_join
from tempfile import TemporaryDirectory
from unittest.mock import patch

from configure import dashboard, dyndns
from configure.util import CONTAINER_IPV6_BASE, MTikRouter

ROUTER_HOST = "router.foxden.network"


def make_router() -> MTikRouter:
    return MTikRouter(
        host=ROUTER_HOST,
        horizon="internal",
        vrrp_priority_online=50,
        vrrp_priority_offline=10,
        dyndns_suffix_ipv6="::1",
    )


OUTPUTS = {
    "cloudns_dynamic_keys": {
        ROUTER_HOST: {"ipv4": "c4", "ipv6": "c6", "ipv6_suffix": "::99"},
        f"v4-{ROUTER_HOST}": {"ipv4": "cv4", "ipv6": None, "ipv6_suffix": None},
        "alpha.foxden.network": {"ipv4": "a4", "ipv6": "a6", "ipv6_suffix": "::a"},
        "beta.foxden.network": {"ipv4": "b4", "ipv6": None, "ipv6_suffix": None},
        "router-backup.foxden.network": {
            "ipv4": "other4",
            "ipv6": None,
            "ipv6_suffix": None,
        },
        "zeta.foxden.network": {"ipv4": "z4", "ipv6": "z6", "ipv6_suffix": "::5"},
    },
}


class TestDyndns(unittest.TestCase):
    def setUp(self) -> None:
        patcher = patch.object(dyndns, "_tofu_outputs_value", OUTPUTS)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_write_all_hosts_skips_special_and_sorts(self) -> None:
        self.assertEqual(
            dyndns.write_all_hosts("  "),
            [
                '  $dyndnsUpdate host="alpha.foxden.network" key4="a4" key6="a6" priv6addr="::a" ip6addr=$ip6addr ipaddr=$ipaddr\n',
                '  $dyndnsUpdate host="beta.foxden.network" key4="b4" ipaddr=$ipaddr\n',
                '  $dyndnsUpdate host="zeta.foxden.network" key4="z4" key6="z6" priv6addr="::5" ip6addr=$ip6addr ipaddr=$ipaddr\n',
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
        # The router's own suffix wins over the one from terraform
        self.assertIn(
            f'$dyndnsUpdate host="{ROUTER_HOST}" key4="c4" key6="c6" priv6addr="::1" ip6addr=$ip6addr ipaddr=$ipaddr\n',
            script.source,
        )
        self.assertIn(
            f'$dyndnsUpdate host="v4-{ROUTER_HOST}" key4="cv4" ipaddr=$ipaddr\n',
            script.source,
        )
        self.assertIn('host="zeta.foxden.network"', script.source)
        self.assertNotIn("other4", script.source)

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
        self.assertTrue(lines[2].startswith('    $dyndnsUpdate host="beta'))
        self.assertTrue(lines[3].startswith('    $dyndnsUpdate host="zeta'))
        self.assertTrue(lines[4].startswith(f'\t$dyndnsUpdate host="{ROUTER_HOST}"'))
        self.assertTrue(lines[5].startswith(f'\t$dyndnsUpdate host="v4-{ROUTER_HOST}"'))
        self.assertEqual(lines[6], "b")

    def test_template_errors(self) -> None:
        with self.assertRaises(RuntimeError):
            self.make_with_template("nothing here\n")
        with self.assertRaises(RuntimeError):
            self.make_with_template("# HOSTS #\n# HOSTS #\n")

    def test_duplicate_special_hosts_errors(self) -> None:
        with self.assertRaises(RuntimeError):
            self.make_with_template("# HOSTS #\n# SPECIAL HOSTS #\n# SPECIAL HOSTS #\n")


class TestDashboardPT(unittest.TestCase):
    def test_template_matches_dashboard_subnet(self) -> None:
        # The script ORs this suffix onto the router's /60 for Ingress PT
        offset = int(CONTAINER_IPV6_BASE) & 0xFFFFFFFF
        suffix = IPv6Address(offset + dashboard.CONTAINER.subnet * 256)
        with open(dyndns.TEMPLATE) as f:
            self.assertIn(f"($ip6addr | {suffix})", f.read())


if __name__ == "__main__":
    unittest.main()
