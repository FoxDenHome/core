from configure.util import MTikScript, ROUTERS

def refresh_vrrp():
    for router in ROUTERS:
        print(f"## {router.host}")
        router.scripts.add(MTikScript(
            name="onboot-vrrp-config",
            source=
                f":global VRRPPriorityOnline {router.vrrp_priority_online}\n" +
                f":global VRRPPriorityOffline {router.vrrp_priority_offline}\n",
            run_on_change=True,
            schedule="startup",
        ))
