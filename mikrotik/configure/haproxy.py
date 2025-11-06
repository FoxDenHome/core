from subprocess import check_call
from configure.util import unlink_safe, NIX_DIR, mtik_path, ROUTERS
from os import path

ROOTPATH = mtik_path("files/haproxy")
FILENAME = path.join(ROOTPATH, "haproxy.cfg")

def refresh_haproxy():
    unlink_safe("result")
    check_call(["nix", "build", f"{NIX_DIR}#haproxy.text.router"])
    with open("result", "r") as file:
        config = file.read()

    config = config.replace("#uid#", "uid").replace("#gid#", "gid")

    with open(FILENAME, "w") as out_file:
        out_file.write(config)

    for router in ROUTERS:
        print(f"## {router.host}")
        changes = router.sync(ROOTPATH, "/haproxy")
        if changes:
            print("### Restarting HAProxy container", changes)
            router.restart_container("haproxy")
