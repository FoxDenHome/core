from os.path import dirname, realpath, join
from os import unlink
from dataclasses import dataclass
from subprocess import check_call

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

@dataclass(frozen=True, kw_only=True)
class MTikUser:
    username: str
    password: str

    def ensure(self, target: str) -> None:
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
            
    def disable(self, target: str) -> None:
        print("Disabling user", self.username, "on", target)
        check_call(["ssh", target, f'/user/disable [ find name="{self.username}"]'])
