from os.path import dirname, realpath, join
from os import unlink
from dataclasses import dataclass, field
from subprocess import check_call
from routeros_api import RouterOsApiPool

MTIK_DIR = realpath(dirname(__file__) + "/../")
NIX_DIR = realpath(dirname(__file__) + "/../../nix/")


def unlink_safe(path: str):
    try:
        unlink(path)
    except FileNotFoundError:
        pass

def mtik_path(path: str) -> str:
    return join(MTIK_DIR, path)

VLAN_NAMES = ["", "mgmt", "lan", "dmz", "labnet", "security", "hypervisor", "retro"]
def get_ipv4_netname(ip: str) -> str:
    parts = ip.split(".")
    if parts[0] == "10":
        return VLAN_NAMES[int(parts[1])]
    if parts[0] == "100" and parts[1] == "96" and parts[2] == "41":
        return "cghmn"
    raise ValueError(f"Unknown net for IP {ip}")

@dataclass(frozen=True, eq=True, kw_only=True)
class MTikScript:
    name: str
    source: str
    policy: str = "read,write,policy,test"
    dontRequirePermissions: bool = True
    schedule: str | None = None
    runOnChange: bool = False

@dataclass(frozen=True, eq=True, kw_only=True)
class MTikRouter:
    host: str
    vrrpPriorityOnline: int
    vrrpPriorityOffline: int
    dynDNSSuffix6: str
    scripts: set[MTikScript] = field(default_factory=set)

@dataclass(frozen=True, kw_only=True)
class MTikUser:
    username: str
    password: str

    connections: dict[str, RouterOsApiPool] = None

    def connection(self, router: MTikRouter) -> RouterOsApiPool:
        target = router.host
        if target not in self.connections:
            pool = RouterOsApiPool(
                target,
                username=self.username,
                password=self.password,
                use_ssl=True,
                plaintext_login=True,
            )
            self.connections[target] = pool
        return self.connections[target]

    def ensure(self, router: MTikRouter) -> None:
        target = router.host
        print("Ensuring user", self.username, "on", target)
        cmd = f"""
            /user ;
            :local prev [find name="{self.username}"] ;
            :if ([:len $prev] > 0) do={{
                set $prev password="{self.password}" group=full disabled=no
            }} else={{
                add name="{self.username}" password="{self.password}" group=full disabled=no
            }}
        """
        check_call(["ssh", target, cmd.replace("\n", "")])

    def disable(self, router: MTikRouter) -> None:
        target = router.host
        print("Disabling user", self.username, "on", target)
        check_call(["ssh", target, f'/user/disable [ find name="{self.username}"]'])

def parse_mtik_bool(val: str | bool) -> bool:
    if val == "true" or val == True:
        return True
    if val == "false" or val == False:
        return False
    raise ValueError(f"Invalid Mikrotik boolean value: {val}")

def format_mtik_bool(val: bool) -> str:
    return "true" if val else "false"

def is_ipv6(addr: str) -> bool:
    return "." not in addr

def format_weird_mtik_ip(addr: str) -> str:
    if is_ipv6(addr) and "/" not in addr:
        return addr + "/128"
    else:
        return addr.removesuffix("/32")

ROUTERS = [
    #MTikRouter(host="router.foxden.network", vrrpPriorityOnline=50, vrrpPriorityOffline=10, dynDNSSuffix6="::1"),
    MTikRouter(host="router-backup.foxden.network", vrrpPriorityOnline=25, vrrpPriorityOffline=5, dynDNSSuffix6="::2"),
]
