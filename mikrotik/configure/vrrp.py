from configure.util import MTikRouter, MTikScript, ROUTERS, mtik_path

MAIN_SCRIPT = "wan-online-adjust"
TEMPLATE = mtik_path(f"files/vrrp/{MAIN_SCRIPT}.rsc")

def make_vrrp_script(router: MTikRouter) -> None:
    with open(TEMPLATE, "r") as file:
        data = file.read()

    data = data.replace("# VRRP PRIORITY ONLINE #", str(router.vrrp_priority_online))
    data = data.replace("# VRRP PRIORITY OFFLINE #", str(router.vrrp_priority_offline))

    router.scripts.add(
        MTikScript(
            name=MAIN_SCRIPT,
            source=data,
            schedule="1m",
        )
    )


def refresh_vrrp():
    for router in ROUTERS:
        if router.horizon != "internal":
            continue
        print(f"## {router.host}")
        make_vrrp_script(router)
