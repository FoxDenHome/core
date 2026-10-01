import unittest
from os.path import join as path_join
from tempfile import TemporaryDirectory

from configure.scripts import (
    SCRIPT_DIR,
    load_from_file,
    load_scripts_from_dir,
    refresh_script_router,
)
from configure.util import MTikScript
from tests.fakes import FakeResource, FakeRouter, quiet

SCRIPT = "/system/script"
SCHEDULER = "/system/scheduler"


def script_row(script: MTikScript, **extra: str) -> dict[str, str]:
    return {
        "name": script.name,
        "source": script.source,
        "policy": script.policy,
        "dont-require-permissions": "true"
        if script.dont_require_permissions
        else "false",
        **extra,
    }


def schedule_row(script: MTikScript, **extra: str) -> dict[str, str]:
    return {
        "name": script.name,
        "on-event": f"/system/script/run {script.name}",
        "disabled": "false",
        "policy": script.policy,
        "start-time": "00:00:00",
        "interval": script.schedule or "",
        **extra,
    }


def run(
    scripts: set[MTikScript],
    deployed_scripts: list[dict[str, str]],
    deployed_schedules: list[dict[str, str]],
    router_scripts: set[MTikScript] | None = None,
) -> tuple[FakeResource, FakeResource]:
    router = FakeRouter(
        {
            SCRIPT: FakeResource(deployed_scripts),
            SCHEDULER: FakeResource(deployed_schedules),
        },
        scripts=router_scripts,
    )
    quiet(refresh_script_router, router, scripts)
    return router.resources[SCRIPT], router.resources[SCHEDULER]


class TestLoadScripts(unittest.TestCase):
    def test_load_from_file_parses_header(self) -> None:
        with TemporaryDirectory() as tmp:
            path = path_join(tmp, "my-script.rsc")
            with open(path, "w") as f:
                f.write(
                    "# policy = read,write\n"
                    "# Schedule=5m\n"
                    "# run-on-change=true\n"
                    "# dont-require-permissions=false\n"
                    "# just a comment\n"
                    ":log info hi\n"
                )
            script = load_from_file(path)
        self.assertEqual(script.name, "my-script")
        self.assertEqual(script.policy, "read,write")
        self.assertEqual(script.schedule, "5m")
        self.assertTrue(script.run_on_change)
        self.assertFalse(script.dont_require_permissions)
        self.assertTrue(script.source.endswith(":log info hi\n"))

    def test_load_from_file_defaults(self) -> None:
        with TemporaryDirectory() as tmp:
            path = path_join(tmp, "plain.rsc")
            with open(path, "w") as f:
                f.write(":log info hi\n")
            script = load_from_file(path)
        self.assertEqual(script, MTikScript(name="plain", source=":log info hi\n"))

    def test_load_scripts_from_dir_only_rsc(self) -> None:
        with TemporaryDirectory() as tmp:
            for name in ("a.rsc", "b.rsc", "README.md"):
                with open(path_join(tmp, name), "w") as f:
                    f.write("")
            scripts = load_scripts_from_dir(tmp)
        self.assertEqual({s.name for s in scripts}, {"a", "b"})

    def test_repo_scripts_load(self) -> None:
        for horizon in ("internal", "external", "all"):
            scripts = load_scripts_from_dir(path_join(SCRIPT_DIR, horizon))
            self.assertTrue(scripts, horizon)


class TestRefreshScriptRouter(unittest.TestCase):
    def test_creates_script_and_schedule(self) -> None:
        script = MTikScript(name="s", source="x", schedule="5m")
        scripts, schedules = run({script}, [], [])
        self.assertEqual(scripts.attribs(), [script_row(script)])
        self.assertEqual(schedules.attribs(), [schedule_row(script)])

    def test_startup_schedule(self) -> None:
        script = MTikScript(name="s", source="x", schedule="startup")
        _, schedules = run({script}, [], [])
        self.assertEqual(
            schedules.attribs(),
            [schedule_row(script, **{"start-time": "startup", "interval": "0s"})],
        )

    def test_noop_when_in_sync(self) -> None:
        script = MTikScript(name="s", source="x", schedule="5m")
        scripts, schedules = run(
            {script},
            [script_row(script, owner="admin", **{"run-count": "3"})],
            [schedule_row(script, **{"next-run": "soon"})],
        )
        self.assertEqual(scripts.ops, [])
        self.assertEqual(schedules.ops, [])

    def test_updates_changed_script(self) -> None:
        old = MTikScript(name="s", source="old")
        new = MTikScript(name="s", source="new")
        scripts, _ = run({new}, [script_row(old)], [])
        self.assertEqual(scripts.ops, [("set", "*1")])
        self.assertEqual(scripts.rows[0]["source"], "new")

    def test_updates_changed_schedule(self) -> None:
        script = MTikScript(name="s", source="x", schedule="5m")
        _, schedules = run(
            {script},
            [script_row(script)],
            [schedule_row(script, interval="1m")],
        )
        self.assertEqual(schedules.ops, [("set", "*1")])
        self.assertEqual(schedules.rows[0]["interval"], "5m")

    def test_run_on_change(self) -> None:
        script = MTikScript(name="s", source="new", run_on_change=True)
        scripts, _ = run({script}, [], [])
        self.assertIn(("run", "s"), scripts.ops)

        scripts, _ = run({script}, [script_row(script)], [])
        self.assertEqual(scripts.ops, [])

        old = MTikScript(name="s", source="old", run_on_change=True)
        scripts, _ = run({script}, [script_row(old)], [])
        self.assertEqual(scripts.ops, [("set", "*1"), ("run", "s")])

    def test_removes_strays(self) -> None:
        stray = MTikScript(name="stray", source="x", schedule="5m")
        scripts, schedules = run(set(), [script_row(stray)], [schedule_row(stray)])
        self.assertEqual(scripts.rows, [])
        self.assertEqual(schedules.rows, [])

    def test_includes_router_scripts(self) -> None:
        base = MTikScript(name="base", source="x")
        extra = MTikScript(name="extra", source="y")
        scripts, _ = run({base}, [], [], router_scripts={extra})
        self.assertEqual({r["name"] for r in scripts.rows}, {"base", "extra"})


if __name__ == "__main__":
    unittest.main()
