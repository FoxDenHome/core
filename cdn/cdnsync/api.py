"""Minimal Fastly API client (https://www.fastly.com/documentation/reference/api/)

Authenticates with FASTLY_API_KEY, the variable the Fastly terraform provider
used.
"""

import json
from os import environ
from typing import Any
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

BASE = "https://api.fastly.com"

# The entities a service version holds, by their path segment. Each has
# GET/POST .../version/<v>/<kind> and PUT/DELETE .../version/<v>/<kind>/<name>.
VERSIONED_KINDS = [
    "acl",
    "backend",
    "cache_settings",
    "condition",
    "dictionary",
    "director",
    "domain",
    "gzip",
    "header",
    "healthcheck",
    "request_settings",
    "response_object",
    "snippet",
    "vcl",
]

JSONAPI = "application/vnd.api+json"


class ApiError(RuntimeError):
    def __init__(self, message: str, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


def q(part: str | int) -> str:
    return quote(str(part), safe="")


def _form_value(v: Any) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


class Client:
    def __init__(self, token: str, base: str = BASE) -> None:
        self.token = token
        self.base = base

    @classmethod
    def from_env(cls) -> "Client":
        try:
            return cls(environ["FASTLY_API_KEY"])
        except KeyError:
            raise ApiError("FASTLY_API_KEY is not set") from None

    def call(
        self,
        method: str,
        path: str,
        form: dict[str, Any] | None = None,
        body: Any = None,
        content_type: str = "application/json",
    ) -> Any:
        """form is sent url-encoded, body as JSON. Returns the parsed JSON."""
        req = Request(self.base + path, method=method)
        req.add_header("Fastly-Key", self.token)
        req.add_header("Accept", "application/json")
        req.add_header("User-Agent", "foxden-cdn")
        if form is not None:
            req.data = urlencode({k: _form_value(v) for k, v in form.items()}).encode()
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
        elif body is not None:
            req.data = json.dumps(body).encode()
            req.add_header("Content-Type", content_type)
        try:
            with urlopen(req, timeout=60) as res:
                data = res.read()
        except HTTPError as e:
            detail = e.read().decode(errors="replace").strip()[:1000]
            raise ApiError(
                f"Fastly {method} {path} failed: {e.code} {detail or e.reason}",
                e.code,
            ) from None
        return json.loads(data) if data else None

    # Services and versions

    def find_service(self, name: str) -> dict[str, Any] | None:
        try:
            return self.call("GET", "/service/search?" + urlencode({"name": name}))
        except ApiError as e:
            if e.status == 404:
                return None
            raise

    def create_service(self, name: str) -> dict[str, Any]:
        return self.call("POST", "/service", form={"name": name, "type": "vcl"})

    def versions(self, service: str) -> list[dict[str, Any]]:
        return self.call("GET", f"/service/{q(service)}/version")

    def _version(self, service: str, version: int) -> str:
        return f"/service/{q(service)}/version/{version}"

    def clone_version(self, service: str, version: int) -> int:
        return self.call("PUT", self._version(service, version) + "/clone")["number"]

    def validate_version(self, service: str, version: int) -> dict[str, Any]:
        return self.call("GET", self._version(service, version) + "/validate")

    def activate_version(self, service: str, version: int) -> None:
        self.call("PUT", self._version(service, version) + "/activate")

    def list_entities(self, service: str, version: int, kind: str) -> list[dict]:
        return self.call("GET", f"{self._version(service, version)}/{kind}")

    def create_entity(
        self, service: str, version: int, kind: str, fields: dict[str, Any]
    ) -> None:
        self.call("POST", f"{self._version(service, version)}/{kind}", form=fields)

    def update_entity(
        self, service: str, version: int, kind: str, name: str, fields: dict[str, Any]
    ) -> None:
        path = f"{self._version(service, version)}/{kind}/{q(name)}"
        self.call("PUT", path, form=fields)

    def delete_entity(self, service: str, version: int, kind: str, name: str) -> None:
        self.call("DELETE", f"{self._version(service, version)}/{kind}/{q(name)}")

    def get_settings(self, service: str, version: int) -> dict[str, Any]:
        return self.call("GET", self._version(service, version) + "/settings")

    def update_settings(
        self, service: str, version: int, settings: dict[str, Any]
    ) -> None:
        self.call("PUT", self._version(service, version) + "/settings", form=settings)

    # Dictionary items (versionless)

    def dictionary_items(self, service: str, dictionary_id: str) -> dict[str, str]:
        items: dict[str, str] = {}
        for page in range(1, 1000):
            got = self.call(
                "GET",
                f"/service/{q(service)}/dictionary/{q(dictionary_id)}/items"
                f"?per_page=500&page={page}",
            )
            items.update({i["item_key"]: i["item_value"] for i in got})
            if len(got) < 500:
                break
        return items

    def batch_dictionary_items(
        self, service: str, dictionary_id: str, ops: list[dict[str, str]]
    ) -> None:
        """ops: {op: upsert|delete, item_key, item_value}, at most 1000 per call"""
        path = f"/service/{q(service)}/dictionary/{q(dictionary_id)}/items"
        for i in range(0, len(ops), 1000):
            self.call("PATCH", path, body={"items": ops[i : i + 1000]})

    # Domains (versionless, the Domain Management API)

    def list_domains(self, service: str) -> list[dict[str, Any]]:
        domains: list[dict[str, Any]] = []
        cursor = ""
        while True:
            params = {"service_id": service, "limit": 100}
            if cursor:
                params["cursor"] = cursor
            got = self.call("GET", "/domains/v1?" + urlencode(params))
            domains += got["data"]
            cursor = (got.get("meta") or {}).get("next_cursor") or ""
            if not cursor:
                return domains

    def create_domain(self, fqdn: str, service: str, description: str) -> None:
        self.call(
            "POST",
            "/domains/v1",
            body={"fqdn": fqdn, "service_id": service, "description": description},
        )

    def update_domain(self, domain_id: str, service: str, description: str) -> None:
        self.call(
            "PATCH",
            f"/domains/v1/{q(domain_id)}",
            body={"service_id": service, "description": description},
        )

    def delete_domain(self, domain_id: str) -> None:
        self.call("DELETE", f"/domains/v1/{q(domain_id)}")

    # TLS subscriptions (JSON:API)

    def list_tls_subscriptions(self) -> tuple[list[dict], list[dict]]:
        """(subscriptions, included tls_authorizations)"""
        subs: list[dict] = []
        included: list[dict] = []
        for page in range(1, 1000):
            got = self.call(
                "GET",
                "/tls/subscriptions?include=tls_authorizations"
                f"&page%5Bsize%5D=100&page%5Bnumber%5D={page}",
            )
            subs += got["data"]
            included += got.get("included") or []
            if page >= (got.get("meta") or {}).get("total_pages", 1):
                break
        return subs, included

    @staticmethod
    def _tls_domains(domains: list[str]) -> dict[str, Any]:
        return {"data": [{"type": "tls_domain", "id": d} for d in domains]}

    def create_tls_subscription(self, domains: list[str], ca: str) -> None:
        body = {
            "data": {
                "type": "tls_subscription",
                "attributes": {"certificate_authority": ca},
                "relationships": {"tls_domains": self._tls_domains(domains)},
            }
        }
        self.call("POST", "/tls/subscriptions", body=body, content_type=JSONAPI)

    def update_tls_subscription(self, sub_id: str, domains: list[str]) -> None:
        body = {
            "data": {
                "type": "tls_subscription",
                "id": sub_id,
                "relationships": {"tls_domains": self._tls_domains(domains)},
            }
        }
        self.call(
            "PATCH", f"/tls/subscriptions/{q(sub_id)}", body=body, content_type=JSONAPI
        )
