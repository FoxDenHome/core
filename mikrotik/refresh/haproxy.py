from subprocess import check_call
from refresh.util import unlink_safe, NIX_DIR, mtik_path

# TODO: Diff config and restart HAProxy only if changed

FILENAME = mtik_path("files/haproxy/haproxy.cfg")

def refresh_haproxy():
    unlink_safe("result")
    check_call(["nix", "build", f"{NIX_DIR}#haproxy.text.router"])
    with open("result", "r") as file:
        config = file.read()

    config = config.replace("#uid#", "uid").replace("#gid#", "gid")

    with open(FILENAME, "w") as out_file:
        out_file.write(config)
