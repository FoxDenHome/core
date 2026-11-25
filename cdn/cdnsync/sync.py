"""Diffs the live Fastly service against desired.Service and applies the diff

Versioned config (backends, VCL, dictionaries, settings, ...) is compared with
the active version. If it differs, the active version is cloned, changed,
validated and activated. Dictionary items, domains and the TLS subscription
are versionless and changed in place.
"""

from dataclasses import dataclass, field
from typing import Any

from cdnsync.api import VERSIONED_KINDS, Client
from cdnsync.desired import Service

CREATE = "create"
UPDATE = "update"
DELETE = "delete"
ORDER = [CREATE, UPDATE, DELETE]
SYMBOLS = {CREATE: "+", UPDATE: "~", DELETE: "-"}


@dataclass
class Change:
    action: str
    what: str  # an api.VERSIONED_KINDS kind, "settings", "item", "domain", ...
    name: str
    fields: dict[str, Any] = field(default_factory=dict)
    ref: str = ""  # the Fastly id of what is updated or deleted
    differs: list[str] = field(default_factory=list)

    def describe(self) -> str:
        line = " ".join(filter(None, [SYMBOLS[self.action], self.what, self.name]))
        if self.differs:
            line += f" ({', '.join(self.differs)})"
        return line


@dataclass
class Plan:
    service_id: str | None  # None: the service gets created
    base_version: int | None = None
    # Whether the base version can be changed in place instead of cloned
    base_editable: bool = False
    version: list[Change] = field(default_factory=list)
    items: dict[str, list[Change]] = field(default_factory=dict)  # by dictionary
    domains: list[Change] = field(default_factory=list)
    tls: list[Change] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    service: list[Change] = field(default_factory=list)

    @property
    def changes(self) -> list[Change]:
        items = [c for changes in self.items.values() for c in changes]
        return self.service + self.version + items + self.domains + self.tls

    def count(self, action: str) -> int:
        return sum(1 for c in self.changes if c.action == action)


def norm(v: Any) -> str:
    """Fastly answers with ints and bools where it takes strings"""
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def differing(want: dict[str, Any], have: dict[str, Any]) -> list[str]:
    return [k for k in sorted(want) if norm(want[k]) != norm(have.get(k))]


def diff_entities(
    want: dict[str, dict[str, dict[str, Any]]], live: dict[str, list[dict[str, Any]]]
) -> list[Change]:
    changes: list[Change] = []
    for kind in VERSIONED_KINDS:
        wanted = want.get(kind, {})
        have = {e["name"]: e for e in live.get(kind, [])}
        for name, fields in sorted(wanted.items()):
            if name not in have:
                changes.append(Change(CREATE, kind, name, {"name": name, **fields}))
            elif diff := differing(fields, have[name]):
                changes.append(Change(UPDATE, kind, name, fields, differs=diff))
        for name in sorted(set(have) - set(wanted)):
            changes.append(Change(DELETE, kind, name))
    return changes


def diff_settings(want: dict[str, Any], have: dict[str, Any]) -> list[Change]:
    if diff := differing(want, have):
        return [Change(UPDATE, "settings", "", want, differs=diff)]
    return []


def diff_items(dictionary: str, want: dict[str, str], have: dict[str, str]):
    what = f"item {dictionary}"
    changes: list[Change] = []
    for key, value in sorted(want.items()):
        if key not in have:
            changes.append(Change(CREATE, what, key, {"item_value": value}))
        elif have[key] != value:
            changes.append(Change(UPDATE, what, key, {"item_value": value}))
    for key in sorted(set(have) - set(want)):
        changes.append(Change(DELETE, what, key))
    return changes


def diff_domains(svc: Service, have: list[dict[str, Any]]) -> list[Change]:
    """have: the Domain Management API domains of the service"""
    changes: list[Change] = []
    by_fqdn = {d["fqdn"]: d for d in have}
    fields = {"description": svc.domain_description}
    for fqdn in sorted(svc.domains):
        if fqdn not in by_fqdn:
            changes.append(Change(CREATE, "domain", fqdn, fields))
        elif diff := differing(fields, by_fqdn[fqdn]):
            changes.append(
                Change(UPDATE, "domain", fqdn, fields, by_fqdn[fqdn]["id"], diff)
            )
    for fqdn in sorted(set(by_fqdn) - set(svc.domains)):
        changes.append(Change(DELETE, "domain", fqdn, ref=by_fqdn[fqdn]["id"]))
    return changes


def sub_domains(sub: dict[str, Any]) -> set[str]:
    return {d["id"] for d in sub["relationships"]["tls_domains"]["data"]}


def find_subscription(
    svc: Service, subs: list[dict[str, Any]]
) -> tuple[dict[str, Any] | None, list[Change], list[str]]:
    """The subscription covering the service's domains, the changes it needs
    and warnings"""
    ours = [s for s in subs if sub_domains(s) & set(svc.domains)]
    want = sorted(svc.domains)
    name = ",".join(want)
    if not ours:
        fields = {"certificate_authority": svc.certificate_authority}
        return None, [Change(CREATE, "tls subscription", name, fields)], []
    if len(ours) > 1:
        ids = ", ".join(s["id"] for s in ours)
        return None, [], [f"several TLS subscriptions cover the domains ({ids})"]

    sub = ours[0]
    changes: list[Change] = []
    warnings: list[str] = []
    if sub_domains(sub) != set(want):
        changes.append(
            Change(UPDATE, "tls subscription", name, ref=sub["id"], differs=["domains"])
        )
    attrs = sub["attributes"]
    if attrs["certificate_authority"] != svc.certificate_authority:
        warnings.append(
            f"TLS subscription {sub['id']} uses {attrs['certificate_authority']}, "
            f"not {svc.certificate_authority}; that can't be changed in place"
        )
    if attrs["state"] != "issued":
        warnings.append(f"TLS subscription {sub['id']} is {attrs['state']}")
    return sub, changes, warnings


def fastly_targets(
    sub: dict[str, Any], included: list[dict[str, Any]]
) -> dict[str, set[str]]:
    """fqdn => the CNAME targets Fastly wants it to point at"""
    ids = {a["id"] for a in sub["relationships"]["tls_authorizations"]["data"]}
    targets: dict[str, set[str]] = {}
    for auth in included:
        if auth["type"] != "tls_authorization" or auth["id"] not in ids:
            continue
        for ch in auth["attributes"]["challenges"]:
            if ch["type"] == "managed-http-cname":
                values = {v.removesuffix(".") for v in ch["values"]}
                targets.setdefault(ch["record_name"], set()).update(values)
    return targets


def check_dns(fastly: dict[str, set[str]], nix: dict[str, set[str]]) -> list[str]:
    warnings: list[str] = []
    for fqdn in sorted(nix):
        want = fastly.get(fqdn)
        if want and nix[fqdn] != want:
            warnings.append(
                f"{fqdn} points at {', '.join(sorted(nix[fqdn])) or 'nothing'} in nix "
                f"but Fastly wants {', '.join(sorted(want))}; update "
                "nix/systems/x86_64-linux/landevices/fastly-cdn.nix"
            )
    return warnings


def make_plan(
    client: Client, svc: Service, nix_targets: dict[str, set[str]] | None
) -> Plan:
    found = client.find_service(svc.name)
    if found is None:
        plan = Plan(service_id=None, base_version=1, base_editable=True)
        plan.service.append(Change(CREATE, "service", svc.name))
        live: dict[str, list[dict[str, Any]]] = {}
        settings: dict[str, Any] = {}
        domains: list[dict[str, Any]] = []
    else:
        sid = found["id"]
        versions = client.versions(sid)
        active = [v for v in versions if v["active"]]
        base = active[0] if active else max(versions, key=lambda v: v["number"])
        plan = Plan(
            service_id=sid,
            base_version=base["number"],
            base_editable=not (base["active"] or base["locked"]),
        )
        if not active:
            plan.warnings.append(
                f"service {sid} has no active version, comparing to {base['number']}"
            )
        live = {
            k: client.list_entities(sid, base["number"], k) for k in VERSIONED_KINDS
        }
        settings = client.get_settings(sid, base["number"])
        domains = client.list_domains(sid)

    plan.version = diff_entities(svc.entities, live) + diff_settings(
        svc.settings, settings
    )
    dict_ids = {d["name"]: d["id"] for d in live.get("dictionary", [])}
    for name, want in sorted(svc.dictionary_items.items()):
        have = {}
        if plan.service_id is not None and name in dict_ids:
            have = client.dictionary_items(plan.service_id, dict_ids[name])
        plan.items[name] = diff_items(name, want, have)
    plan.domains = diff_domains(svc, domains)

    subs, included = client.list_tls_subscriptions()
    sub, plan.tls, warnings = find_subscription(svc, subs)
    plan.warnings += warnings
    if sub is not None and nix_targets is not None:
        plan.warnings += check_dns(fastly_targets(sub, included), nix_targets)
    return plan


def apply(client: Client, svc: Service, plan: Plan) -> None:
    sid = plan.service_id
    if sid is None:
        print(f"Creating service {svc.name}")
        sid = client.create_service(svc.name)["id"]
    assert plan.base_version is not None

    if plan.version:
        version = plan.base_version
        if not plan.base_editable:
            version = client.clone_version(sid, version)
            print(f"Cloned version {plan.base_version} to {version}")
        for c in plan.version:
            print(c.describe())
            if c.what == "settings":
                client.update_settings(sid, version, c.fields)
            elif c.action == CREATE:
                client.create_entity(sid, version, c.what, c.fields)
            elif c.action == UPDATE:
                client.update_entity(sid, version, c.what, c.name, c.fields)
            else:
                client.delete_entity(sid, version, c.what, c.name)
        result = client.validate_version(sid, version)
        for w in result.get("warnings") or []:
            print(f"! {w}")
        if result.get("status") != "ok":
            raise RuntimeError(
                f"version {version} does not validate, left inactive: "
                f"{result.get('msg')} {result.get('errors')}"
            )
        client.activate_version(sid, version)
        print(f"Activated version {version}")
    else:
        version = plan.base_version

    item_changes = {name: cs for name, cs in plan.items.items() if cs}
    if item_changes:
        dict_ids = {
            d["name"]: d["id"] for d in client.list_entities(sid, version, "dictionary")
        }
        for name, changes in item_changes.items():
            ops = []
            for c in changes:
                print(c.describe())
                op = {"op": "delete" if c.action == DELETE else "upsert"}
                ops.append({**op, "item_key": c.name, **c.fields})
            client.batch_dictionary_items(sid, dict_ids[name], ops)

    for c in plan.domains:
        print(c.describe())
        if c.action == CREATE:
            client.create_domain(c.name, sid, c.fields["description"])
        elif c.action == UPDATE:
            client.update_domain(c.ref, sid, c.fields["description"])
        else:
            client.delete_domain(c.ref)

    for c in plan.tls:
        print(c.describe())
        if c.action == CREATE:
            client.create_tls_subscription(
                sorted(svc.domains), c.fields["certificate_authority"]
            )
        else:
            client.update_tls_subscription(c.ref, sorted(svc.domains))
