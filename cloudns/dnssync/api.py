"""Minimal ClouDNS API client (https://www.cloudns.net/wiki/article/41/)"""

import json
from os import environ
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen

API_URL = "https://api.cloudns.net"
ZONE_PAGE_SIZE = 100


class ApiError(RuntimeError):
    pass


class Client:
    def __init__(self, auth_id: str, password: str) -> None:
        self.auth_id = auth_id
        self.password = password

    @classmethod
    def from_env(cls) -> "Client":
        try:
            return cls(environ["CLOUDNS_AUTH_ID"], environ["CLOUDNS_PASSWORD"])
        except KeyError as e:
            raise ApiError(f"{e.args[0]} is not set") from None

    def call(self, endpoint: str, params: dict[str, Any] | None = None) -> Any:
        """POSTs form params to /<endpoint>.json, raises ApiError if it fails"""
        form = {"auth-id": self.auth_id, "auth-password": self.password}
        form.update({k: v for k, v in (params or {}).items() if v is not None})
        req = Request(
            f"{API_URL}/{endpoint}.json",
            data=urlencode(form, doseq=True).encode(),
            headers={"User-Agent": "foxden-cloudns"},
        )
        with urlopen(req, timeout=30) as res:
            body = json.load(res)
        if isinstance(body, dict) and body.get("status") not in (None, "Success"):
            desc = body.get("statusDescription") or body
            raise ApiError(f"ClouDNS {endpoint} failed: {desc}")
        return body

    def list_zones(self) -> list[str]:
        zones: list[str] = []
        page = 1
        while True:
            res = self.call(
                "dns/list-zones", {"page": page, "rows-per-page": ZONE_PAGE_SIZE}
            )
            zones += [z["name"] for z in res]
            if len(res) < ZONE_PAGE_SIZE:
                return zones
            page += 1

    def register_zone(self, zone: str, nameservers: list[str]) -> None:
        self.call(
            "dns/register",
            {"domain-name": zone, "zone-type": "master", "ns[]": nameservers},
        )

    def list_records(self, zone: str) -> list[dict[str, Any]]:
        res = self.call("dns/records", {"domain-name": zone})
        # An empty zone comes back as [], anything else as {id: record}
        return list(res.values()) if isinstance(res, dict) else []

    def add_record(self, zone: str, params: dict[str, Any]) -> str:
        res = self.call("dns/add-record", {"domain-name": zone, **params})
        return str(res["data"]["id"])

    def modify_record(self, zone: str, record_id: str, params: dict[str, Any]) -> None:
        # Modify can't change the type, so it's dropped
        params = {k: v for k, v in params.items() if k != "record-type"}
        self.call(
            "dns/mod-record",
            {"domain-name": zone, "record-id": record_id, **params},
        )

    def delete_record(self, zone: str, record_id: str) -> None:
        self.call("dns/delete-record", {"domain-name": zone, "record-id": record_id})

    def dynamic_url(self, zone: str, record_id: str) -> str:
        """The record's DynamicURL. Creates (or re-enables) it if needed."""
        res = self.call(
            "dns/get-dynamic-url", {"domain-name": zone, "record-id": record_id}
        )
        return res["url"]
