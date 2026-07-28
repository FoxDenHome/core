from os import makedirs
from os.path import join as path_join
from shutil import rmtree
from subprocess import check_output

from configure.util import NIX_DIR, ROUTERS, mtik_path

OUT_PATH = mtik_path("out/foxingress")


def refresh_foxingress():
    result = (
        check_output(
            [
                "nix",
                "build",
                f"{NIX_DIR}#foxIngress.json.router",
                "--no-link",
                "--print-out-paths",
            ]
        )
        .strip()
        .decode("utf-8")
    )
    with open(result, "r") as file:
        config = file.read()

    rmtree(OUT_PATH, ignore_errors=True)
    makedirs(OUT_PATH, exist_ok=True)

    with open(path_join(OUT_PATH, "config.yml"), "w") as out_file:
        out_file.write(config)

    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        print(f"## {router.host}")
        changes = router.sync(OUT_PATH, "/foxingress")
        if changes:
            print("### Restarting foxIngress container", changes)
            router.restart_container("foxingress")
