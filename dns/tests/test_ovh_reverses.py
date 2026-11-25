import unittest

from dnssync.ovh import reverses
from dnssync.ovh.api import ApiError, path
from dnssync.ovh.reverses import DELETE, SET, Change


class DesiredTest(unittest.TestCase):
    def test_drops_private_and_normalizes(self) -> None:
        got = reverses.desired_from(
            {
                "10.99.10.2": "icefox.foxden.network",
                "fd2c:f4cb:63be::a63:a01": "redfox.foxden.network",
                "51.79.107.29": "Icefox.FoxDen.network",
                "2607:5300:0060:7065:0000::1": "web.foxden.network.",
            }
        )
        self.assertEqual(
            got,
            {
                "51.79.107.29": "icefox.foxden.network.",
                "2607:5300:60:7065::1": "web.foxden.network.",
            },
        )


class BlocksTest(unittest.TestCase):
    def test_smallest_block_wins(self) -> None:
        assigned, warnings = reverses.assign_blocks(
            {
                "2607:5300:60:7065::1": "a.",
                "51.79.107.29": "b.",
                "1.2.3.4": "c.",
            },
            ["2607:5300:60::/48", "2607:5300:60:7065::/64", "51.79.107.29/32"],
        )
        self.assertEqual(
            assigned,
            {
                "2607:5300:60:7065::1": "2607:5300:60:7065::/64",
                "51.79.107.29": "51.79.107.29/32",
            },
        )
        self.assertEqual(len(warnings), 1)
        self.assertIn("1.2.3.4", warnings[0])

    def test_path_encodes_slash(self) -> None:
        self.assertEqual(
            path("ip", "2607:5300:60:7065::/64", "reverse"),
            "/ip/2607%3A5300%3A60%3A7065%3A%3A%2F64/reverse",
        )


class PlanTest(unittest.TestCase):
    def test_plan(self) -> None:
        block = "2607:5300:60:7065::/64"
        desired = {
            "2607:5300:60:7065::1": "same.foxden.network.",
            "2607:5300:60:7065::2": "new.foxden.network.",
            "2607:5300:60:7065::3": "changed.foxden.network.",
        }
        assigned = {ip: block for ip in desired}
        live = {
            block: {
                "2607:5300:60:7065:0::1": "Same.foxden.network.",
                "2607:5300:60:7065::3": "old.foxden.network.",
                "2607:5300:60:7065::4": "stale.foxden.network.",
            },
            # Not assigned any IP: left alone
            "51.161.78.141/32": {"51.161.78.141": "other.example."},
        }
        plan = reverses.plan(desired, assigned, live)
        self.assertEqual(
            plan.changes,
            [
                Change(SET, block, "2607:5300:60:7065::2", "new.foxden.network."),
                Change(
                    SET,
                    block,
                    "2607:5300:60:7065::3",
                    "changed.foxden.network.",
                    "old.foxden.network.",
                ),
                Change(
                    DELETE, block, "2607:5300:60:7065::4", live="stale.foxden.network."
                ),
            ],
        )


class FakeClient:
    def __init__(self, failures: int, status: int = 400) -> None:
        self.failures = failures
        self.status = status
        self.calls = 0

    def set_reverse(self, block: str, ip: str, reverse: str) -> None:
        self.calls += 1
        if self.calls <= self.failures:
            raise ApiError("not resolvable", self.status)


class ApplyTest(unittest.TestCase):
    change = Change(SET, "51.79.107.29/32", "51.79.107.29", "icefox.foxden.network.")

    def test_retries_until_resolvable(self) -> None:
        client = FakeClient(failures=2)
        reverses.apply_change(client, self.change, sleep=lambda _: None)  # type: ignore[arg-type]
        self.assertEqual(client.calls, 3)

    def test_other_errors_raise(self) -> None:
        client = FakeClient(failures=1, status=403)
        with self.assertRaises(ApiError):
            reverses.apply_change(client, self.change, sleep=lambda _: None)  # type: ignore[arg-type]
        self.assertEqual(client.calls, 1)


if __name__ == "__main__":
    unittest.main()
