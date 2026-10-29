"""nginx auth_request backend that checks HTTP Basic credentials against a
kanidm application password.

kanidm-app-auth <socket> <ldap url> <application> [realm]

Listens for HTTP on the unix <socket>. Each request's Authorization header is
checked with an LDAP bind as name=<user>,app=<application>, which kanidm only
accepts with one of that user's passwords for <application>, and only while
the user is in the application's linked group. Answers 204 if the bind works,
401 with a Basic challenge for <realm> otherwise.

Good credentials are remembered for a minute, so a WebDAV client making many
requests does not cost a bind each.
"""

import base64
import binascii
import hashlib
import os
import re
import socketserver
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler

import ldap3
from ldap3.core.exceptions import LDAPException, LDAPSASLPrepError

CACHE_SECONDS = 60
# Also keeps the name from adding RDNs to the bind DN
USER_RE = re.compile(r"[A-Za-z0-9_.-]+")

socket_path, ldap_url, application = sys.argv[1:4]
realm = sys.argv[4] if len(sys.argv) > 4 else application

cache: dict[bytes, float] = {}
cache_lock = threading.Lock()


def parse_basic(header: str) -> tuple[str, str] | None:
    scheme, _, encoded = header.partition(" ")
    if scheme.lower() != "basic":
        return None
    try:
        decoded = base64.b64decode(encoded.strip(), validate=True).decode()
    except (binascii.Error, UnicodeDecodeError):
        return None
    user, sep, password = decoded.partition(":")
    if not sep:
        return None
    return user, password


def check(user: str, password: str) -> bool:
    # An empty password would be an unauthenticated bind
    if not password or not USER_RE.fullmatch(user):
        return False

    key = hashlib.sha256(f"{user}\0{password}".encode()).digest()
    now = time.monotonic()
    with cache_lock:
        if cache.get(key, 0) > now:
            return True

    # A fresh Server each time: a shared one remembers an address that failed
    # once and refuses it from then on
    server = ldap3.Server(
        ldap_url,
        connect_timeout=5,
        # ldap3 skips certificate checks unless told otherwise
        tls=ldap3.Tls(validate=ssl.CERT_REQUIRED),
    )
    conn = ldap3.Connection(
        server,
        user=f"name={user},app={application}",
        password=password,
        receive_timeout=10,
    )
    try:
        ok = conn.bind()
    except LDAPSASLPrepError:
        # A password no client could have been given (e.g. control characters)
        return False
    finally:
        conn.unbind()
    if not ok:
        return False

    with cache_lock:
        for k in [k for k, expiry in cache.items() if expiry <= now]:
            del cache[k]
        cache[key] = now + CACHE_SECONDS
    return True


class Handler(BaseHTTPRequestHandler):
    def address_string(self) -> str:
        return "unix"

    def do_GET(self) -> None:
        creds = parse_basic(self.headers.get("Authorization", ""))
        try:
            ok = creds is not None and check(*creds)
        except LDAPException as e:
            self.log_message("LDAP error: %s", e)
            self.send_response(502)
            self.end_headers()
            return

        if ok:
            self.send_response(204)
        else:
            self.send_response(401)
            self.send_header(
                "WWW-Authenticate", f'Basic realm="{realm}", charset="UTF-8"'
            )
        self.end_headers()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


if os.path.exists(socket_path):
    os.unlink(socket_path)
with Server(socket_path, Handler) as server:
    server.serve_forever()
