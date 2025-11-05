from refresh.util import MTikScript, ROUTERS

def refresh_vrrp():
    for router in ROUTERS:
        router.scripts.add(MTikScript(
            name="onboot-vrrp-config",
            source=
                f":global VRRPPriorityOnline {router.vrrpPriorityOnline}\n" +
                f":global VRRPPriorityOffline {router.vrrpPriorityOffline}\n",
            runOnChange=True,
            schedule="startup",
        ))
