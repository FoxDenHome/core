"""Minimal OVHcloud API client (https://help.ovhcloud.com/csm/en-gb-api-getting-started-ovhcloud-api)

Signs requests with an application key/secret and a consumer key, the same
OVH_* variables the OVH terraform provider and python-ovh use.
"""

import hashlib
import json
import time
from os import environ
from typing import Any
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen

ENDPOINTS = {
    "ovh-eu": "https://eu.api.ovh.com/1.0",
    "ovh-ca": "https://ca.api.ovh.com/1.0",
    "ovh-us": "https://api.us.ovhcloud.com/1.0",
}


class ApiError(RuntimeError):
    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


def path(*parts: str) -> str:
    """/part/part/...: every part URL-encoded, slashes included"""
    return "".join("/" + quote(p, safe="") for p in parts)


class Client:
    def __init__(
        self, endpoint: str, app_key: str, app_secret: str, consumer_key: str
    ) -> None:
        self.base = ENDPOINTS.get(endpoint, endpoint)
        self.app_key = app_key
        self.app_secret = app_secret
        self.consumer_key = consumer_key
        self._time_delta: int | None = None

    @classmethod
    def from_env(cls) -> "Client":
        try:
            return cls(
                environ.get("OVH_ENDPOINT", "ovh-us"),
                environ["OVH_APPLICATION_KEY"],
                environ["OVH_APPLICATION_SECRET"],
                environ["OVH_CONSUMER_KEY"],
            )
        except KeyError as e:
            raise ApiError(f"{e.args[0]} is not set") from None

    def _open(self, req: Request) -> Any:
        try:
            with urlopen(req, timeout=30) as res:
                body = res.read()
        except HTTPError as e:
            try:
                message = json.loads(e.read()).get("message")
            except ValueError:
                message = None
            raise ApiError(
                f"OVH {req.get_method()} {req.full_url} failed: {e.code} {message or e.reason}",
                e.code,
            ) from None
        return json.loads(body) if body else None

    def time_delta(self) -> int:
        """Server time minus ours, as the signature has to use the former"""
        if self._time_delta is None:
            server = self._open(Request(f"{self.base}/auth/time"))
            self._time_delta = int(server) - int(time.time())
        return self._time_delta

    def call(self, method: str, url_path: str, body: Any = None) -> Any:
        url = self.base + url_path
        data = "" if body is None else json.dumps(body)
        now = str(int(time.time()) + self.time_delta())
        signed = f"{self.app_secret}+{self.consumer_key}+{method}+{url}+{data}+{now}"
        headers = {
            "X-Ovh-Application": self.app_key,
            "X-Ovh-Consumer": self.consumer_key,
            "X-Ovh-Timestamp": now,
            "X-Ovh-Signature": "$1$" + hashlib.sha1(signed.encode()).hexdigest(),
            "User-Agent": "foxden-dns",
        }
        if body is not None:
            headers["Content-Type"] = "application/json"
        req = Request(
            url, data=data.encode() if body is not None else None, method=method
        )
        for k, v in headers.items():
            req.add_header(k, v)
        return self._open(req)

    def list_blocks(self) -> list[str]:
        """The IP blocks of the account (1.2.3.4/32, 2001:db8::/64, ...)"""
        return self.call("GET", "/ip")

    def list_reverses(self, block: str) -> dict[str, str]:
        """IP => reverse (with its trailing dot) of the custom reverses in block"""
        ips = self.call("GET", path("ip", block, "reverse"))
        return {
            ip: self.call("GET", path("ip", block, "reverse", ip))["reverse"]
            for ip in ips
        }

    def set_reverse(self, block: str, ip: str, reverse: str) -> None:
        """Creates or replaces it. OVH checks that reverse resolves to ip."""
        self.call(
            "POST", path("ip", block, "reverse"), {"ipReverse": ip, "reverse": reverse}
        )

    def delete_reverse(self, block: str, ip: str) -> None:
        self.call("DELETE", path("ip", block, "reverse", ip))
