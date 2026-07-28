from configure.util import ROUTERS, mtik_path

ROOT_PATH = mtik_path("files/tftp")


def refresh_tftp() -> None:
    for router in ROUTERS:
        print(f"## {router.host}")
        changes = router.sync(ROOT_PATH, "/tftp")
        if changes:
            print("### TFTP files changed", changes)
