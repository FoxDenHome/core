from dataclasses import dataclass, replace
from ipaddress import ip_address
from typing import Any

# ClouDNS rejects any other TTL
VALID_TTLS = frozenset(
    [60, 300, 900, 1800, 3600, 21600, 43200, 86400, 172800, 259200, 604800]
    + [1209600, 2592000]
)

# Types whose value is a hostname: ClouDNS stores them without the final dot
HOSTNAME_TYPES = frozenset(["CNAME", "ALIAS", "NS", "SRV", "MX"])

# The extra fields each type uses. Everything else stays None.
TYPE_FIELDS: dict[str, tuple[str, ...]] = {
    "MX": ("priority",),
    "SRV": ("priority", "weight", "port"),
    "SSHFP": ("algorithm", "fptype"),
}
EXTRA_FIELDS = ("priority", "weight", "port", "algorithm", "fptype")


def _int(value: Any) -> int | None:
    if value is None or value == "":
        return None
    return int(value)


@dataclass(frozen=True)
class Record:
    type: str
    host: str  # relative to the zone, "" for the apex
    value: str
    ttl: int
    priority: int | None = None
    weight: int | None = None
    port: int | None = None
    algorithm: int | None = None
    fptype: int | None = None

    @classmethod
    def make(cls, type: str, host: str, value: str, ttl: int, **extra: Any):
        """A record with only the extra fields its type uses"""
        type = type.upper()
        if type in HOSTNAME_TYPES:
            value = value.removesuffix(".")
        used = TYPE_FIELDS.get(type, ())
        fields = {k: _int(extra.get(k)) for k in EXTRA_FIELDS if k in used}
        return cls(type=type, host=host, value=value, ttl=int(ttl), **fields)

    @classmethod
    def from_api(cls, raw: dict[str, Any]) -> "Record":
        return cls.make(
            raw["type"],
            raw["host"],
            raw["record"],
            raw["ttl"],
            priority=raw.get("priority"),
            weight=raw.get("weight"),
            port=raw.get("port"),
            algorithm=raw.get("algorithm"),
            fptype=raw.get("fp_type", raw.get("fptype")),
        )

    def key(self) -> tuple[str, str, str]:
        """What identifies the record: type, host and normalized value"""
        value = self.value
        if self.type in ("A", "AAAA"):
            try:
                value = str(ip_address(value))
            except ValueError:
                pass
        elif self.type in HOSTNAME_TYPES or self.type == "SSHFP":
            value = value.lower()
        return (self.type, self.host.lower(), value)

    def slot(self) -> tuple[str, str]:
        """Type and host, for records whose value someone else keeps"""
        return (self.type, self.host.lower())

    def attrs(self) -> tuple[int | None, ...]:
        return (self.ttl,) + tuple(getattr(self, f) for f in EXTRA_FIELDS)

    def with_value(self, value: str) -> "Record":
        return replace(self, value=value)

    def params(self) -> dict[str, Any]:
        params: dict[str, Any] = {
            "record-type": self.type,
            "host": self.host,
            "record": self.value,
            "ttl": self.ttl,
        }
        for field in EXTRA_FIELDS:
            value = getattr(self, field)
            if value is not None:
                params[field] = value
        return params

    def describe(self) -> str:
        extra = " ".join(
            f"{f}={getattr(self, f)}"
            for f in EXTRA_FIELDS
            if getattr(self, f) is not None
        )
        host = self.host or "@"
        return f"{self.type:<5} {host} {self.value} ttl={self.ttl} {extra}".rstrip()


@dataclass(frozen=True)
class LiveRecord:
    id: str
    record: Record

    @classmethod
    def from_api(cls, raw: dict[str, Any]) -> "LiveRecord":
        return cls(id=str(raw["id"]), record=Record.from_api(raw))
