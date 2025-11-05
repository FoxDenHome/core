from refresh.util import mtik_path, MTikRouter, MTikScript, format_mtik_bool, ROUTERS, parse_mtik_bool
from os.path import basename
from os import listdir

SCRIPT_DIR = mtik_path("scripts")

IGNORE_CHANGES_SCRIPT = {"id", "owner", "invalid", "last-started", "run-count"}
IGNORE_CHANGES_SCHEDULE = {"id", "owner", "run-count", "next-run", "start-date"}

DEFAULT_SCRIPT = MTikScript(name="default", source="")

def load_from_file(file_path: str) -> MTikScript:
    with open(file_path, "r") as f:
        source = f.read()

    script_name = basename(file_path).rsplit(".", 1)[0]

    policy = DEFAULT_SCRIPT.policy
    dontRequirePermissions = DEFAULT_SCRIPT.dontRequirePermissions
    runOnChange = DEFAULT_SCRIPT.runOnChange
    schedule = DEFAULT_SCRIPT.schedule

    for line in source.splitlines():
        line = line.strip()
        if not line.startswith("#"):
            continue

        line = line[1:].strip()
        spl = line.split("=", 1)
        if len(spl) != 2:
            continue

        key = spl[0].lower().strip()
        value = spl[1].strip()

        if key == "dont-require-permissions":
            dontRequirePermissions = parse_mtik_bool(value)
        elif key == "policy":
            policy = value
        elif key == "run-on-change":
            runOnChange = parse_mtik_bool(value)
        elif key == "schedule":
            schedule = value

    return MTikScript(
        name=script_name,
        source=source,
        policy=policy,
        dontRequirePermissions=dontRequirePermissions,
        runOnChange=runOnChange,
        schedule=schedule,
    )


def load_scripts_from_dir(dir_path: str) -> set[MTikScript]:
    scripts: set[MTikScript] = set()
    for filename in listdir(dir_path):
        if not filename.endswith(".rsc"):
            continue

        file_path = f"{dir_path}/{filename}"
        script = load_from_file(file_path)
        scripts.add(script)
    return scripts


def refresh_script_router(router: MTikRouter, base_scripts: set[MTikScript]) -> None:
    print(f"## {router.host}")

    connection = router.connection()
    api = connection.get_api()
    api_script = api.get_resource("/system/script")
    api_scheduler = api.get_resource("/system/scheduler")

    existing_scripts = api_script.get()
    existing_scripts_map = {script["name"]: script for script in existing_scripts}
    stray_scripts = set([script["name"] for script in existing_scripts])

    existing_schedules = api_scheduler.get()
    existing_schedules_map = {scheduler["name"]: scheduler for scheduler in existing_schedules}
    stray_schedules = set([scheduler["name"] for scheduler in existing_schedules])

    scripts_to_run: list[str] = []
    for script in (base_scripts | router.scripts):
        attribs = {
            "name": script.name,
            "source": script.source,
            "policy": script.policy,
            "dont-require-permissions": format_mtik_bool(script.dontRequirePermissions),
        }
        needs_run = False

        existing_script = existing_scripts_map.get(script.name)
        if existing_script is None:
            print("Creating script", script.name)
            api_script.add(**attribs)
            needs_run = script.runOnChange
        else:
            current_script = existing_script
            all_keys = set(current_script.keys()).union(set(attribs.keys()))

            for match_key in all_keys:
                if match_key in IGNORE_CHANGES_SCRIPT or match_key[0] == ".":
                    continue

                if current_script.get(match_key, "") == attribs.get(match_key, ""):
                    continue

                print("Updating script", script.name)
                api_script.set(id=current_script["id"], **attribs)
                needs_run = script.runOnChange
                break

        stray_scripts.discard(script.name)

        if needs_run:
            scripts_to_run.append(script.name)

        if script.schedule is not None:
            attribs = {
                "name": script.name,
                "on-event": f"/system/script/run {script.name}",
                "disabled": format_mtik_bool(False),
                "policy": script.policy,
            }
            if script.schedule == "startup":
                attribs["start-time"] = "startup"
                attribs["interval"] = "0s"
            else:
                attribs["start-time"] = "00:00:00"
                attribs["interval"] = script.schedule

            existing_schedule = existing_schedules_map.get(script.name)
            if existing_schedule is None:
                print("Creating schedule", script.name)
                api_scheduler.add(**attribs)
            else:
                current_schedule = existing_schedule
                all_keys = set(current_schedule.keys()).union(set(attribs.keys()))

                for match_key in all_keys:
                    if match_key in IGNORE_CHANGES_SCHEDULE or match_key[0] == ".":
                        continue

                    if current_schedule.get(match_key, "") == attribs.get(match_key, ""):
                        continue

                    print("Updating schedule", script.name)
                    api_scheduler.set(id=current_schedule["id"], **attribs)
                    break

            stray_schedules.discard(script.name)

    for script_name in scripts_to_run:
        print(f"Running script (runOnChange) {script_name}")
        api_script.call("run", {"number": script_name})

    for stray_script_name in stray_scripts:
        print(f"Removing stray script {stray_script_name}")
        stray_script = existing_scripts_map[stray_script_name]
        api_script.remove(id=stray_script["id"])

    for stray_schedule_name in stray_schedules:
        print(f"Removing stray schedule {stray_schedule_name}")
        stray_schedule = existing_schedules_map[stray_schedule_name]
        api_scheduler.remove(id=stray_schedule["id"])

def refresh_scripts() -> None:
    base_scripts = load_scripts_from_dir(SCRIPT_DIR)

    for router in ROUTERS:
        refresh_script_router(router, base_scripts)
