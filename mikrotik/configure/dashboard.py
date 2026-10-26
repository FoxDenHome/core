import json
from dataclasses import replace
from os import makedirs
from os.path import exists
from os.path import join as path_join
from shutil import copyfile, rmtree
from subprocess import check_output

from configure.util import ROUTERS, MTikContainer, mtik_path

OUT_PATH = mtik_path("out/dashboard")
CONFIG_PATH = mtik_path("../dashboard/config.json")
# Flat map of environment variables (SNMP_COMMUNITY, UNIFI_USERNAME, ...)
SECRETS_PATH = mtik_path("secrets/dashboard.yaml")

CONTAINER = MTikContainer(
    name="dashboard",
    remote_image="git.foxden.network/foxden/dashboard:latest",
    subnet=2,
    mounts=("/dashboard:/config:ro",),
)


def load_secrets() -> tuple[tuple[str, str], ...]:
    if not exists(SECRETS_PATH):
        raise FileNotFoundError(
            f"{SECRETS_PATH} is missing, create it with: sops {SECRETS_PATH}"
        )
    secrets = json.loads(
        check_output(["sops", "decrypt", "--output-type", "json", SECRETS_PATH])
    )
    for key, value in secrets.items():
        if not isinstance(value, str):
            raise TypeError(f"Dashboard secret {key} must be a string")
    return tuple(sorted(secrets.items()))


def refresh_dashboard():
    container = replace(CONTAINER, env=load_secrets())

    rmtree(OUT_PATH, ignore_errors=True)
    makedirs(OUT_PATH, exist_ok=True)
    copyfile(CONFIG_PATH, path_join(OUT_PATH, "config.json"))

    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        print(f"## {router.host}")
        router.containers.add(container)
        changes = router.sync(OUT_PATH, "/dashboard")
        if changes:
            print("### Queueing dashboard container restart", changes)
            router.container_restarts.add(container.name)
