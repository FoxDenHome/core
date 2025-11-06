from os.path import dirname, realpath, join
from os import unlink
from dataclasses import dataclass, field
from subprocess import check_call, check_output
from uuid import uuid4
from time import sleep
from routeros_api import RouterOsApiPool
from routeros_api.exceptions import RouterOsApiCommunicationError

MTIK_DIR = realpath(dirname(__file__) + "/../")
NIX_DIR = realpath(dirname(__file__) + "/../../nix/")
VLAN_NAMES = ["", "mgmt", "lan", "dmz", "labnet", "security", "hypervisor", "retro"]

def unlink_safe(path: str):
    try:
        unlink(path)
    except FileNotFoundError:
        pass

def mtik_path(path: str) -> str:
    return join(MTIK_DIR, path)

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
    dont_require_permissions: bool = True
    schedule: str | None = None
    run_on_change: bool = False

@dataclass(kw_only=True)
class MTikRouter:
    host: str
    vrrp_priority_online: int
    vrrp_priority_offline: int
    dyndns_suffix_ipv6: str
    scripts: set[MTikScript] = field(default_factory=set)

    _connection_cache: RouterOsApiPool | None = None
    _username: str = "foxden-core-configure"
    _password: str | None = None

    def connection(self) -> RouterOsApiPool:
        if self._connection_cache is None:
            pool = RouterOsApiPool(
                self.host,
                username=self._username,
                password=self._password,
                use_ssl=True,
                plaintext_login=True,
            )
            self._connection_cache = pool
        return self._connection_cache

    def ensure_user(self) -> None:
        self._password = str(uuid4())
        print("Ensuring user", self._username, "on", self.host)
        cmd = f"""
            /user ;
            :local prev [find name="{self._username}"] ;
            :if ([:len $prev] > 0) do={{
                set $prev password="{self._password}" group=full disabled=no
            }} else {{
                add name="{self._username}" password="{self._password}" group=full disabled=no
            }}
        """
        check_call(["ssh", self.host, cmd.replace("\n", "")])

    def disable_user(self) -> None:
        print("Disabling user", self._username, "on", self.host)
        check_call(["ssh", self.host, f'/user/disable [ find name="{self._username}"]'])

    def sync(self, src: str, dest: str) -> list[str]:
        result = check_output(["rsync", "--info=NAME", "--exclude=.type", "--checksum", "--recursive", "--delete", "--update", f"{src}/", f"{self.host}:/data{dest}/"])
        return result.splitlines()

    def restart_container(self, name: str) -> None:
        connection = self.connection()
        api = connection.get_api()
        containers = api.get_resource("/container")
        try:
            containers.call("stop", {"numbers": name})
        except RouterOsApiCommunicationError:
            pass
        while not parse_mtik_bool(containers.get(name=name)[0]["stopped"]):
            sleep(0.1)
        containers.call("start", {"numbers": name})

def format_mtik_bool(val: bool) -> str:
    return "true" if val else "false"

def parse_mtik_bool(val: str | bool) -> bool:
    if val == "true" or val == True:
        return True
    if val == "false" or val == False:
        return False
    raise ValueError(f"Invalid MTik boolean value: {val}")

def is_ipv6(addr: str) -> bool:
    return "." not in addr

def format_weird_mtik_ip(addr: str) -> str:
    # They want /128 for IPv6 but no CIDR for single-host IPv4
    if is_ipv6(addr) and "/" not in addr:
        return addr + "/128"
    else:
        return addr.removesuffix("/32")

ROUTERS = [
    MTikRouter(host="router.foxden.network", vrrp_priority_online=50, vrrp_priority_offline=10, dyndns_suffix_ipv6="::1"),
    MTikRouter(host="router-backup.foxden.network", vrrp_priority_online=25, vrrp_priority_offline=5, dyndns_suffix_ipv6="::2"),
]
