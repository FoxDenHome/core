import json
import re
from collections.abc import Callable
from time import monotonic, sleep
from typing import Any
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from routeros_api.exceptions import RouterOsApiCommunicationError

from configure.util import (
    CONTAINER_INTERFACE_LIST,
    ROUTERS,
    MTikContainer,
    MTikRouter,
    parse_mtik_bool,
)

WAIT_TIMEOUT = 600

VETH_DEPENDENTS = ("/ip/address", "/ipv6/address", "/interface/list/member")
ORPHAN_INTERFACE = re.compile(r"\*[0-9A-F]+")

MANIFEST_ACCEPT = (
    "application/vnd.oci.image.index.v1+json,"
    "application/vnd.oci.image.manifest.v1+json,"
    "application/vnd.docker.distribution.manifest.list.v2+json,"
    "application/vnd.docker.distribution.manifest.v2+json"
)

# RouterOS /system/resource architecture-name -> OCI platform architecture
OCI_ARCH = {
    "arm64": "arm64",
    "x86_64": "amd64",
    "arm": "arm",
}


def parse_image_ref(ref: str) -> tuple[str, str, str]:
    name, _, tag = ref.rpartition(":")
    if "/" in tag or not name:
        name, tag = ref, "latest"

    registry, _, repo = name.partition("/")
    if not repo or ("." not in registry and ":" not in registry):
        registry, repo = "registry-1.docker.io", name
        if "/" not in repo:
            repo = f"library/{repo}"
    elif registry == "docker.io":
        registry = "registry-1.docker.io"
    return registry, repo, tag


def _registry_get(url: str, token: str | None) -> Any:
    headers = {"Accept": MANIFEST_ACCEPT}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    with urlopen(Request(url, headers=headers), timeout=30) as resp:
        return json.load(resp)


def _registry_token(challenge: str, repo: str) -> str:
    scheme, _, params = challenge.partition(" ")
    if scheme.lower() != "bearer":
        raise RuntimeError(f"Unsupported registry auth challenge: {challenge}")
    fields: dict[str, str] = {}
    for part in params.split(","):
        key, _, value = part.strip().partition("=")
        fields[key] = value.strip('"')
    query = {"scope": f"repository:{repo}:pull"}
    if "service" in fields:
        query["service"] = fields["service"]
    with urlopen(f"{fields['realm']}?{urlencode(query)}", timeout=30) as resp:
        body = json.load(resp)
    return body.get("token") or body["access_token"]


def resolve_image_id(ref: str, os: str, arch: str) -> str:
    """Returns the config digest (what RouterOS reports as image-id) of ref for os/arch."""
    registry, repo, tag = parse_image_ref(ref)
    base = f"https://{registry}/v2/{repo}/manifests"

    token: str | None = None
    try:
        manifest = _registry_get(f"{base}/{tag}", token)
    except HTTPError as e:
        challenge = e.headers.get("WWW-Authenticate")
        if e.code != 401 or challenge is None:
            raise
        token = _registry_token(challenge, repo)
        manifest = _registry_get(f"{base}/{tag}", token)

    if "manifests" in manifest:
        for entry in manifest["manifests"]:
            platform = entry.get("platform", {})
            if platform.get("os") == os and platform.get("architecture") == arch:
                manifest = _registry_get(f"{base}/{entry['digest']}", token)
                break
        else:
            raise RuntimeError(f"No {os}/{arch} image for {ref}")

    return manifest["config"]["digest"].removeprefix("sha256:")


def _flag(ct: dict[str, str], flag: str) -> bool:
    return flag in ct and parse_mtik_bool(ct[flag])


def _wait_for(
    containers: Any, name: str, cond: Callable[[dict[str, str]], bool], what: str
) -> None:
    deadline = monotonic() + WAIT_TIMEOUT
    while not cond(containers.get(name=name)[0]):
        if monotonic() > deadline:
            raise TimeoutError(f"Timed out waiting for container {name} to {what}")
        sleep(0.5)


def _stop(containers: Any, name: str) -> None:
    try:
        containers.call("stop", {"numbers": name})
    except RouterOsApiCommunicationError:
        pass
    _wait_for(containers, name, lambda ct: _flag(ct, "stopped"), "stop")


def _start(containers: Any, name: str) -> None:
    if _flag(containers.get(name=name)[0], "running"):
        return
    try:
        containers.call("start", {"numbers": name})
    except RouterOsApiCommunicationError:
        # Might already be starting on its own (restart-policy, repull)
        pass
    _wait_for(containers, name, lambda ct: _flag(ct, "running"), "start")


def _image_ready(image_id: str) -> Callable[[dict[str, str]], bool]:
    return lambda ct: ct.get("image-id") == image_id and not _flag(ct, "extracting")


def _changes(current: dict[str, str], wanted: dict[str, str]) -> dict[str, str]:
    return {
        key: value for key, value in wanted.items() if current.get(key, "") != value
    }


def _refresh_network(api: Any, container: MTikContainer) -> bool:
    """Ensures the veth and its router side config, returns whether the veth changed."""
    veths = api.get_resource("/interface/veth")
    attribs = container.veth_attribs()
    veth_changed = False
    current = next(
        (veth for veth in veths.get() if veth["name"] == container.interface), None
    )
    if current is None:
        print("### Creating veth", container.interface)
        veths.add(**attribs)
        veth_changed = True
    else:
        changes = _changes(current, attribs)
        if changes:
            print("### Updating veth", container.interface, sorted(changes))
            veths.set(id=current["id"], **changes)
            veth_changed = True

    for path, wanted in (
        ("/ip/address", container.ip_address_attribs()),
        ("/ipv6/address", container.ipv6_address_attribs()),
    ):
        resource = api.get_resource(path)
        found = False
        for entry in resource.get():
            if entry.get("interface") != container.interface or _flag(entry, "dynamic"):
                continue
            if found or entry.get("address") != wanted["address"]:
                print(f"### Removing stray {path} entry {entry}")
                resource.remove(id=entry["id"])
                continue
            found = True
            changes = _changes(entry, wanted)
            if changes:
                print(f"### Updating {path} entry", wanted["address"], sorted(changes))
                resource.set(id=entry["id"], **changes)
        if not found:
            print(f"### Adding {path} entry", wanted["address"])
            resource.add(**wanted)

    members = api.get_resource("/interface/list/member")
    member = {"list": CONTAINER_INTERFACE_LIST, "interface": container.interface}
    if not any(
        entry.get("list") == member["list"]
        and entry.get("interface") == member["interface"]
        for entry in members.get()
    ):
        print("### Adding interface list member", member)
        members.add(**member)

    return veth_changed


def refresh_containers_router(
    router: MTikRouter,
    resolve: Callable[[str, str, str], str] = resolve_image_id,
) -> None:
    api = router.connection().get_api()
    containers = api.get_resource("/container")

    resource = api.get_resource("/system/resource").get()[0]
    arch = OCI_ARCH[resource["architecture-name"]]

    wanted = sorted(router.containers, key=lambda container: container.subnet)
    for field in ("subnet", "name"):
        values = [getattr(container, field) for container in wanted]
        if len(values) != len(set(values)):
            raise ValueError(f"Duplicate container {field} in {values}")

    existing_map = {ct["name"]: ct for ct in containers.get()}

    for container in wanted:
        veth_changed = _refresh_network(api, container)

        attribs = container.attribs()
        image_id = resolve(container.remote_image, "linux", arch)

        current = existing_map.pop(container.name, None)
        if current is None:
            print("### Creating container", container.name)
            containers.add(**attribs)
            _wait_for(containers, container.name, _image_ready(image_id), "pull")
            _start(containers, container.name)
            continue

        attribs.pop("remote-image")
        config_changes = _changes(current, attribs)
        image_changed = (
            current.get("remote-image") != container.remote_image
            or current.get("image-id") != image_id
        )
        restart_requested = container.name in router.container_restarts
        if not (config_changes or image_changed or veth_changed or restart_requested):
            continue

        print(
            "### Restarting container",
            container.name,
            {
                "config": sorted(config_changes),
                "image": image_changed,
                "veth": veth_changed,
                "requested": restart_requested,
            },
        )
        _stop(containers, container.name)

        if config_changes:
            containers.set(id=current["id"], **config_changes)

        if image_changed:
            print(
                "### Repulling container",
                container.name,
                current.get("image-id"),
                "->",
                image_id,
            )
            containers.call(
                "repull",
                {"number": container.name, "remote-image": container.remote_image},
            )
            _wait_for(containers, container.name, _image_ready(image_id), "repull")

        _start(containers, container.name)

    for name, ct in existing_map.items():
        print(f"### Removing stray container {name}")
        _stop(containers, name)
        containers.remove(id=ct["id"])

    # Mounts and envs are set inline on each container, so any lists are leftovers
    for path in ("/container/mounts", "/container/envs"):
        resource = api.get_resource(path)
        for entry in resource.get():
            print(f"### Removing stray {path} entry {entry.get('list')}")
            resource.remove(id=entry["id"])

    used_interfaces = {container.interface for container in wanted}
    stray_veths = [
        veth
        for veth in api.get_resource("/interface/veth").get()
        if veth["name"] not in used_interfaces
    ]
    stray_veth_names = {veth["name"] for veth in stray_veths}

    def _is_stray_interface(name: str) -> bool:
        # *<hex> is how RouterOS shows references to an already deleted interface
        return name in stray_veth_names or ORPHAN_INTERFACE.fullmatch(name) is not None

    for path in VETH_DEPENDENTS:
        resource = api.get_resource(path)
        for entry in resource.get():
            if _flag(entry, "dynamic"):
                continue
            if _is_stray_interface(entry.get("interface", "")):
                print(f"### Removing stray {path} entry {entry}")
                resource.remove(id=entry["id"])

    veths = api.get_resource("/interface/veth")
    for veth in stray_veths:
        print(f"### Removing stray veth {veth['name']}")
        veths.remove(id=veth["id"])


def refresh_containers() -> None:
    for router in ROUTERS:
        print(f"## {router.host} / {router.horizon}")
        refresh_containers_router(router)
