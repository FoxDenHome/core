"""What Fastly should hold: the FoxDen CDN service at cdn.foxden.network"""

import base64
import json
from dataclasses import dataclass, field
from pathlib import Path
from subprocess import check_output
from typing import Any

CDN_DIR = Path(__file__).resolve().parent.parent
NIX_DIR = CDN_DIR.parent / "nix"

SERVICE_NAME = "FoxDen CDN"
# The DNS records pointing at them are in nix
# (nix/systems/x86_64-linux/landevices/fastly-cdn.nix)
DOMAINS = ["cdn.foxden.network", "foxden.network", "www.foxden.network"]
DOMAIN_DESCRIPTION = "FoxDen CDN domain"
CERTIFICATE_AUTHORITY = "certainly"

# Served by the VCL from the static_root dictionary: each file under static/ is
# an item /<path> => base64 of the file. <path>.meta holds key=value response
# metadata (content-type, status).
STATIC_DICTIONARY = "static_root"
STATIC_DIR = CDN_DIR / "static"
# Its items are owned by foxden-vpn-portal (VPN provisioning blobs), not here
VPN_DICTIONARY = "vpn_peers"


@dataclass
class Service:
    name: str
    # kind (as in api.VERSIONED_KINDS) => name => fields. Fields not listed are
    # left at Fastly's defaults and not compared. Entities of any kind that
    # aren't listed here are deleted.
    entities: dict[str, dict[str, dict[str, Any]]] = field(default_factory=dict)
    settings: dict[str, Any] = field(default_factory=dict)
    # Dictionary name => items. Dictionaries not listed keep their items.
    dictionary_items: dict[str, dict[str, str]] = field(default_factory=dict)
    domains: list[str] = field(default_factory=list)
    domain_description: str = ""
    certificate_authority: str = ""


def static_items(root: Path) -> dict[str, str]:
    return {
        "/" + p.relative_to(root).as_posix(): base64.b64encode(p.read_bytes()).decode()
        for p in sorted(root.rglob("*"))
        if p.is_file()
    }


def load() -> Service:
    return Service(
        name=SERVICE_NAME,
        entities={
            # Everything is answered in VCL; Fastly wants a backend anyway
            "backend": {"dummy": {"address": "127.0.0.1", "port": 1}},
            "vcl": {
                "foxden_cdn_vcl": {
                    "content": (CDN_DIR / "foxden-cdn.vcl").read_text(),
                    "main": True,
                }
            },
            "dictionary": {STATIC_DICTIONARY: {}, VPN_DICTIONARY: {}},
        },
        settings={
            "general.default_ttl": 3600,
            "general.default_host": "",
            "general.stale_if_error": False,
            "general.stale_if_error_ttl": 43200,
        },
        dictionary_items={STATIC_DICTIONARY: static_items(STATIC_DIR)},
        domains=DOMAINS,
        domain_description=DOMAIN_DESCRIPTION,
        certificate_authority=CERTIFICATE_AUTHORITY,
    )


def load_dns_json() -> dict[str, Any]:
    """The nix flake output dns.json"""
    path = check_output(
        ["nix", "build", f"{NIX_DIR}#dns.json", "--no-link", "--print-out-paths"],
        text=True,
    ).strip()
    with open(path) as f:
        return json.load(f)


def nix_targets(dns: dict[str, Any], fqdns: list[str]) -> dict[str, set[str]]:
    """fqdn => values of its external CNAME/ALIAS records in nix (no trailing dot)"""
    wanted = set(fqdns)
    targets: dict[str, set[str]] = {f: set() for f in fqdns}
    for zone, records in dns["records"]["external"].items():
        for r in records:
            fqdn = zone if r["name"] == "@" else f"{r['name']}.{zone}"
            if fqdn in wanted and r["type"].upper() in ("CNAME", "ALIAS"):
                targets[fqdn].add(r["value"].removesuffix("."))
    return targets
