from os import makedirs
from os.path import join as path_join
from shutil import rmtree
from subprocess import check_output
import json

from configure.util import NIX_DIR, ROUTERS, mtik_path

OUT_PATH = mtik_path("out/foxmail")


def refresh_foxmail():
    result = (
        check_output(
            [
                "nix",
                "build",
                f"{NIX_DIR}#foxMail.json.router",
                "--no-link",
                "--print-out-paths",
            ]
        )
        .strip()
        .decode("utf-8")
    )
    with open(result, "r") as file:
        config = json.load(file)

    rmtree(OUT_PATH, ignore_errors=True)
    makedirs(OUT_PATH, exist_ok=True)

    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        print(f"## {router.host}")

        config["domain"] = router.host
        config["sender"]["proxy"] = "socks5://10.99.10.1:1080"
        config["sender"]["dkim"]["selector"] = router.host.split(".")[0]
        with open(path_join(OUT_PATH, "config.yml"), "w") as out_file:
            json.dump(config, out_file)

        changes = router.sync(OUT_PATH, "/foxmail")
        if changes:
            print("### Restarting foxMail container", changes)
            router.restart_container("foxmail")
