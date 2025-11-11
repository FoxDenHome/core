from subprocess import check_call
from configure.util import unlink_safe, NIX_DIR, mtik_path, ROUTERS
from os.path import join as path_join
from os import makedirs
from shutil import rmtree

OUT_PATH = mtik_path("out/haproxy")


def refresh_haproxy():
    unlink_safe("result")
    check_call(["nix", "build", f"{NIX_DIR}#haproxy.text.router"])
    with open("result", "r") as file:
        config = file.read()

    config = config.replace("#uid#", "uid").replace("#gid#", "gid")

    rmtree(OUT_PATH, ignore_errors=True)
    makedirs(OUT_PATH, exist_ok=True)

    with open(path_join(OUT_PATH, "haproxy.cfg"), "w") as out_file:
        out_file.write(config)

    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        print(f"## {router.host}")
        changes = router.sync(OUT_PATH, "/haproxy")
        if changes:
            print("### Restarting HAProxy container", changes)
            router.restart_container("haproxy")
