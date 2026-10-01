import unittest

from configure.util import MTikRouter
from configure.vrrp import MAIN_SCRIPT, make_vrrp_script


class TestVrrp(unittest.TestCase):
    def test_make_vrrp_script(self) -> None:
        router = MTikRouter(
            host="router.foxden.network",
            horizon="internal",
            vrrp_priority_online=123,
            vrrp_priority_offline=45,
            dyndns_suffix_ipv6="::1",
        )
        make_vrrp_script(router)
        self.assertEqual(len(router.scripts), 1)
        script = next(iter(router.scripts))
        self.assertEqual(script.name, MAIN_SCRIPT)
        self.assertEqual(script.schedule, "1m")
        self.assertNotIn("# VRRP PRIORITY", script.source)
        self.assertIn(":local VRRPPriorityCurrent 45", script.source)
        self.assertIn(":set VRRPPriorityCurrent 123", script.source)


if __name__ == "__main__":
    unittest.main()
