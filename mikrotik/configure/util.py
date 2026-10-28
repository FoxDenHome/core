from dataclasses import dataclass, field
from ipaddress import IPv4Address, IPv6Address
from os.path import dirname, join, realpath
from subprocess import check_call, check_output
from uuid import uuid4

from routeros_api import RouterOsApiPool

MTIK_DIR = realpath(dirname(__file__) + "/../")
NIX_DIR = realpath(dirname(__file__) + "/../../nix/")
VLAN_NAMES = ["", "mgmt", "lan", "dmz", "labnet", "security", "hypervisor", "retro"]


def mtik_path(path: str) -> str:
    return join(MTIK_DIR, path)


def get_ipv4_netname(ip: str) -> str:
    parts = ip.split(".")
    if parts[0] == "10":
        return VLAN_NAMES[int(parts[1])]
    if parts[0] == "100" and parts[1] == "68" and parts[2] == "41":
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


@dataclass(frozen=True, kw_only=True)
class MTikFirewallRule:
    families: list[str]
    table: str
    attribs: dict[str, str]
    ignoreChanges: set[str] = field(default_factory=set)


# Each container gets subnet X: 172.17.X.0/24 and CONTAINER_IPV6_BASE + X/120,
# with .1 on the router side of its veth and .2 in the container
CONTAINER_IPV4_NET = "172.17.0.0/16"
CONTAINER_IPV6_BASE = IPv6Address("fd2c:f4cb:63be::ac11:0")
CONTAINER_INTERFACE_LIST = "zone-local"
ROUTER_HOST = 1
CONTAINER_HOST = 2


@dataclass(frozen=True, kw_only=True)
class MTikContainer:
    name: str
    remote_image: str
    subnet: int
    mounts: tuple[str, ...] = ()
    # (key, value) pairs, kept in the /container/envs list named after the container
    env: tuple[tuple[str, str], ...] = field(default=(), repr=False)
    workdir: str = "/"
    restart_policy: str = "always"
    restart_interval: str = "15s"
    logging: bool = True
    start_on_boot: bool = True

    def __post_init__(self) -> None:
        if not 0 <= self.subnet <= 255:
            raise ValueError(f"Container {self.name} subnet out of range")

    @property
    def interface(self) -> str:
        return f"veth-{self.name}"

    def ipv4(self, host: int) -> str:
        return str(
            IPv4Address(CONTAINER_IPV4_NET.split("/")[0]) + self.subnet * 256 + host
        )

    def ipv6(self, host: int) -> str:
        return str(CONTAINER_IPV6_BASE + self.subnet * 256 + host)

    def attribs(self) -> dict[str, str]:
        return {
            "name": self.name,
            "remote-image": self.remote_image,
            "interface": self.interface,
            "dns": self.ipv4(ROUTER_HOST),
            "mount": ",".join(self.mounts),
            "envlists": self.name if self.env else "",
            "root-dir": f"/{self.name}-root",
            "workdir": self.workdir,
            "restart-policy": self.restart_policy,
            "restart-interval": self.restart_interval,
            "logging": format_mtik_bool(self.logging),
            "start-on-boot": format_mtik_bool(self.start_on_boot),
        }

    def veth_attribs(self) -> dict[str, str]:
        return {
            "name": self.interface,
            "address": f"{self.ipv4(CONTAINER_HOST)}/24,{self.ipv6(CONTAINER_HOST)}/120",
            "gateway": self.ipv4(ROUTER_HOST),
            "gateway6": self.ipv6(ROUTER_HOST),
            "dhcp": format_mtik_bool(False),
        }

    def ip_address_attribs(self) -> dict[str, str]:
        return {"address": f"{self.ipv4(ROUTER_HOST)}/24", "interface": self.interface}

    def ipv6_address_attribs(self) -> dict[str, str]:
        return {
            "address": f"{self.ipv6(ROUTER_HOST)}/120",
            "interface": self.interface,
            "advertise": format_mtik_bool(False),
        }


@dataclass(kw_only=True)
class MTikRouter:
    host: str
    vrrp_priority_online: int
    vrrp_priority_offline: int
    dyndns_suffix_ipv6: str
    horizon: str
    scripts: set[MTikScript] = field(default_factory=set)
    containers: set[MTikContainer] = field(default_factory=set)
    # Containers whose config files changed, restarted by refresh_containers
    container_restarts: set[str] = field(default_factory=set)
    # Placed after the default head rules and before the nix generated ones
    firewall_rules: list[MTikFirewallRule] = field(default_factory=list)

    _connection_cache: RouterOsApiPool | None = None
    _username: str = "foxden-core-configure"
    _password: str | None = None

    @property
    def name(self) -> str:
        return self.host.split(".")[0]

    def connection(self) -> RouterOsApiPool:
        if self._connection_cache is None:
            if self._password is None:
                raise RuntimeError(
                    f"ensure_user() must be called before connecting to {self.host}"
                )
            pool = RouterOsApiPool(
                self.host,
                username=self._username,
                password=self._password,
                use_ssl=False,
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
        result = check_output(
            [
                "rsync",
                "--info=NAME",
                "--exclude=.type",
                "--checksum",
                "--recursive",
                "--delete",
                "--update",
                f"{src}/",
                f"{self.host}:/data{dest}/",
            ],
            encoding="utf-8",
        )
        return result.splitlines()

    def run_in_container(self, name: str, command: str) -> None:
        connection = self.connection()
        api = connection.get_api()
        containers = api.get_resource("/container")
        containers.call(
            "shell", {"number": name, "cmd": command, "no-sh": format_mtik_bool(True)}
        )


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


def format_mtik_duration(seconds: int) -> str:
    output = ""
    if seconds >= 86400:
        output += f"{seconds // 86400}d"
        seconds %= 86400
    if seconds >= 3600:
        output += f"{seconds // 3600}h"
        seconds %= 3600
    if seconds >= 60:
        output += f"{seconds // 60}m"
        seconds %= 60
    if seconds > 0 or output == "":
        return output + f"{seconds}s"
    return output


ROUTERS = [
    MTikRouter(
        host="router.foxden.network",
        horizon="internal",
        vrrp_priority_online=50,
        vrrp_priority_offline=10,
        dyndns_suffix_ipv6="::1",
    ),
    MTikRouter(
        host="router-backup.foxden.network",
        horizon="internal",
        vrrp_priority_online=25,
        vrrp_priority_offline=5,
        dyndns_suffix_ipv6="::2",
    ),
    MTikRouter(
        host="redfox.foxden.network",
        horizon="external",
        vrrp_priority_online=0,
        vrrp_priority_offline=0,
        dyndns_suffix_ipv6="",
    ),
]
