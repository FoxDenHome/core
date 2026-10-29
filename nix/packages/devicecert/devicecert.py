"""Puts a Let's Encrypt certificate on a UPS/ATS network card.

devicecert eaton <fqdn> <lego dir>
    Eaton Network-M2. The card keeps its private key: it makes a CSR, lego
    gets it signed over DNS-01 (HURRICANE_TOKENS) and the result goes back to
    the card.

devicecert cyberpower <fqdn> <cert dir>
    CyberPower RMCARD, with HTTPS already enabled. Uploads the certificate and
    key security.acme keeps in <cert dir>.

devicecert netcmdr <fqdn> <cert dir>
    Tripp Lite NetCommander IP KVM, through the netcmdr CLI. Same as
    cyberpower otherwise.

All log in with DEVICECERTS_USERNAME/DEVICECERTS_PASSWORD (a static RADIUS
user) and leave the device alone while it serves a certificate that is good
for a while longer, or that already matches the one in <cert dir>.
"""

import base64
import hashlib
import http.cookiejar
import json
import os
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

RENEW_BEFORE = timedelta(days=30)


class CardError(Exception):
    pass


def log(msg: str) -> None:
    print(msg, flush=True)


def fatal(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)
    sys.exit(1)


def tls_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    # The KVM prefers DHE with a 1024-bit group, which OpenSSL refuses, over
    # the plain RSA it also offers
    ctx.set_ciphers("DEFAULT:!kDHE")
    return ctx


def served_cert(fqdn: str) -> x509.Certificate | None:
    ctx = tls_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((fqdn, 443), timeout=10) as sock:
            with ctx.wrap_socket(sock, server_hostname=fqdn) as tls:
                der = tls.getpeercert(binary_form=True)
    except OSError:
        return None
    return x509.load_der_x509_certificate(der) if der else None


def trusted(fqdn: str) -> bool:
    """Whether the card's certificate verifies against the system CAs."""
    try:
        with socket.create_connection((fqdn, 443), timeout=10) as sock:
            with tls_context().wrap_socket(sock, server_hostname=fqdn):
                return True
    except (OSError, ssl.SSLError):
        return False


def fingerprint(cert: x509.Certificate | None) -> str:
    return cert.fingerprint(hashes.SHA256()).hex(":") if cert else "none"


def wait_served(fqdn: str, want: str) -> None:
    current = "none"
    for _ in range(30):
        time.sleep(10)
        current = fingerprint(served_cert(fqdn))
        if current == want:
            log(f"Certificate: card now serves {current}")
            return
    raise CardError(f"card serves {current} instead of {want}")


def credentials() -> tuple[str, str]:
    return os.environ["DEVICECERTS_USERNAME"], os.environ["DEVICECERTS_PASSWORD"]


def pkcs1_key(key_file: Path) -> bytes:
    """The devices only read PKCS#1 keys, lego writes PKCS#8."""
    return serialization.load_pem_private_key(
        key_file.read_bytes(), password=None
    ).private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    )


def acme_fingerprint(cert_dir: Path) -> str | None:
    """The certificate security.acme keeps in cert_dir, unless it's still the
    placeholder it signs with a throwaway CA until lego has one."""
    if (
        subprocess.run(
            [
                "openssl",
                "verify",
                "-CAfile",
                "/etc/ssl/certs/ca-certificates.crt",
                "-untrusted",
                str(cert_dir / "chain.pem"),
                str(cert_dir / "cert.pem"),
            ],
            capture_output=True,
        ).returncode
        != 0
    ):
        log("Certificate: not issued yet, leaving the device alone")
        return None
    return fingerprint(
        x509.load_pem_x509_certificate((cert_dir / "cert.pem").read_bytes())
    )


def eaton(fqdn: str, lego_dir: Path) -> None:
    # The card serves the certificate without its chain, so it doesn't
    # verify on its own. Compare it with what lego last issued instead.
    current = served_cert(fqdn)
    issued_file = lego_dir / "certificates" / f"{fqdn}.crt"
    last = (
        x509.load_pem_x509_certificates(issued_file.read_bytes())[0]
        if issued_file.exists()
        else None
    )
    if (
        current
        and fingerprint(current) == fingerprint(last)
        and current.not_valid_after_utc - datetime.now(timezone.utc) > RENEW_BEFORE
    ):
        log(f"Certificate: valid until {current.not_valid_after_utc}")
        return
    log(f"Certificate: {fingerprint(current)} needs replacing")

    ctx = ssl.create_default_context()
    if not trusted(fqdn):
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    base = f"https://{fqdn}/rest/mbdetnrs/1.0"
    token = ""

    def call(method: str, path: str, body: object = None) -> bytes:
        req = urllib.request.Request(
            path if path.startswith("https://") else f"https://{fqdn}{path}",
            method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Content-Type": "application/json", "Accept": "application/json"}
            | ({"Authorization": f"Bearer {token}"} if token else {}),
        )
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=60) as res:
                return res.read()
        except urllib.error.HTTPError as e:
            raise CardError(f"{method} {path}: {e.code} {e.read()[:2000]!r}") from e

    username, password = credentials()
    login = json.loads(
        call(
            "POST",
            f"{base}/oauth2/token",
            {
                "username": username,
                "password": password,
                "grant_type": "password",
                "scope": "GUIAccess",
            },
        )
    )
    token = login["access_token"]
    log("Certificate: logged in")

    service = json.loads(
        call("GET", f"{base}/managers/1/certificatesManager/services/webserver")
    )["serverAuthentication"]
    # Without the IP address in it, which Let's Encrypt would not sign
    csr = call("POST", service["csr"]["actions"]["#generate"], {"cacbCompliance": True})
    try:
        csr = json.loads(csr).encode()
    except ValueError:
        pass
    # The card says version 2 in its CSR, which cryptography refuses to load
    # but lego (Go) takes
    log("Certificate: card made a CSR")

    lego_dir.mkdir(parents=True, exist_ok=True)
    (lego_dir / "card.csr").write_bytes(csr)
    subprocess.run(
        [
            "lego",
            "run",
            "--accept-tos",
            "--email",
            "ssl@foxden.network",
            "--dns",
            "hurricane",
            "--path",
            str(lego_dir),
            "--csr",
            str(lego_dir / "card.csr"),
            "--cert.name",
            fqdn,
            "--no-random-sleep",
        ],
        check=True,
    )
    issued = (lego_dir / "certificates" / f"{fqdn}.crt").read_bytes()
    leaf = x509.load_pem_x509_certificates(issued)[0]
    log(f"Certificate: Let's Encrypt issued {fingerprint(leaf)}")

    # Try the chain first, then just the leaf
    import_url = service["certificate"]["actions"]["#import"]
    for pem in (issued, leaf.public_bytes(serialization.Encoding.PEM)):
        try:
            call("POST", import_url, {"certificate": pem.decode(), "format": "PEM"})
        except CardError as e:
            log(f"Certificate: card rejected it: {e}")
            continue
        log("Certificate: card took it")
        break
    else:
        raise CardError("card took neither the chain nor the leaf")

    wait_served(fqdn, fingerprint(leaf))


class CyberPower:
    """The RMCARD web UI. Its session is tied to the client's address and
    User-Agent, so everything has to go through this one opener."""

    def __init__(self, fqdn: str) -> None:
        self.base = f"https://{fqdn}/"
        # Until it serves our certificate, the card's own is self-signed
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
            urllib.request.HTTPSHandler(context=ctx),
        )
        # The card drops the certificate upload from clients that don't look
        # like a browser
        self.opener.addheaders = [
            (
                "User-Agent",
                "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0",
            ),
            ("Accept", "text/html,application/xhtml+xml,*/*;q=0.8"),
        ]

    def get(self, path: str):
        return self.opener.open(self.base + path, timeout=30)

    def login(self, username: str, password: str) -> None:
        # The login form encrypts its fields to the card's X25519 key, with
        # AES-GCM under SHA-256 of the shared secret
        with self.get("login.html") as res:
            card_key = base64.b64decode(res.headers["X25519-Public-Key"])
        ours = X25519PrivateKey.generate()
        key = hashlib.sha256(
            ours.exchange(X25519PublicKey.from_public_bytes(card_key))
        ).digest()
        nonce = os.urandom(12)
        form = urllib.parse.urlencode(
            {"username": username, "password": password, "action": "login"},
            quote_via=urllib.parse.quote,
        )
        body = {
            "ephemeral_pub": base64.b64encode(
                ours.public_key().public_bytes(
                    serialization.Encoding.Raw, serialization.PublicFormat.Raw
                )
            ).decode(),
            "nonce": base64.b64encode(nonce).decode(),
            "ciphertext": base64.b64encode(
                AESGCM(key).encrypt(nonce, form.encode(), None)
            ).decode(),
        }
        req = urllib.request.Request(
            self.base + "login_pass.cgi",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
        )
        with self.opener.open(req, timeout=30) as res:
            if json.load(res).get("result") != "ok":
                raise CardError("card refused the login form")

        # The card asks RADIUS in the background, login_pass.html polls it
        for step in (0, 1):
            self.get(f"login_counter.html?stap={step}").read()
        for _ in range(30):
            with self.get("login_counter.html?stap=2") as res:
                if res.headers.get("auth_state") not in (None, "0"):
                    break
            time.sleep(2)
        with self.get("login.cgi?action=LOGIN") as res:
            if res.url.endswith("/error.html"):
                raise CardError("could not log in to the web UI")
        log("Certificate: logged in")

    def logout(self) -> None:
        try:
            self.get("logout.html").read()
        except OSError:
            pass


def cyberpower(fqdn: str, cert_dir: Path) -> None:
    desired = acme_fingerprint(cert_dir)
    if desired is None:
        return
    served = served_cert(fqdn)
    current = fingerprint(served)
    # The card keeps its old key when it can't read the new one, so the
    # certificate matching isn't enough
    if current == desired and trusted(fqdn):
        log(f"Certificate: {current}")
        return
    log(f"Certificate: {current} -> {desired}")

    # Only HTTPS is let through from here. A card that broke it (an empty
    # certificate after an upload it couldn't read) has to be recovered on its
    # console: web access http, upload a certificate, web access https
    if served is None:
        raise CardError("card has no working HTTPS, recover it on its console")
    card = CyberPower(fqdn)
    card.login(*credentials())
    try:
        upload_cyberpower(card, cert_dir)
    finally:
        card.logout()
    wait_served(fqdn, desired)
    if not trusted(fqdn):
        raise CardError("card serves the certificate, but not with its key")


def upload_cyberpower(card: CyberPower, cert_dir: Path) -> None:
    # Network > Web Service > Upload Certificate takes one PEM file with the
    # key, the certificate and its chain, in that order (the manual's RMC.crt).
    # The card only switches to it when it reboots, which logging out does.
    # What it says right after the upload ("Uploaded an invalid certificate")
    # is no indication either way.
    with card.get("cert_modify.html") as res:
        res.read()
    boundary = "----WebKitFormBoundary" + os.urandom(8).hex()
    body = (
        (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="upfile"; filename="RMC.crt"\r\n'
            "Content-Type: application/x-x509-ca-cert\r\n\r\n"
        ).encode()
        + pkcs1_key(cert_dir / "key.pem")
        + (cert_dir / "fullchain.pem").read_bytes()
        + f"\r\n--{boundary}--\r\n".encode()
    )
    req = urllib.request.Request(
        card.base + "cert_modify.cgi",
        data=body,
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Origin": card.base.rstrip("/"),
            "Referer": card.base + "cert_modify.html",
        },
    )
    with card.opener.open(req, timeout=60) as res:
        res.read()
        if res.url.endswith("/error.html"):
            raise CardError("card refused the upload")
    log("Certificate: uploaded, logging out so the card reboots into it")


def netcmdr(fqdn: str, cert_dir: Path) -> None:
    desired = acme_fingerprint(cert_dir)
    if desired is None:
        return
    # The KVM serves the certificate without its chain, so it doesn't verify
    # on its own. With DHE off it uses RSA key exchange, so a handshake only
    # works with the certificate's key: matching it is enough.
    served = served_cert(fqdn)
    current = fingerprint(served)
    if current == desired:
        log(f"Certificate: {current}")
        return
    log(f"Certificate: {current} -> {desired}")

    # netcmdr only talks HTTPS, so a KVM that lost it needs its reset button
    if served is None:
        raise CardError("KVM has no working HTTPS")
    username, password = credentials()
    with tempfile.TemporaryDirectory() as tmp:
        key = Path(tmp) / "key.pem"
        key.write_bytes(pkcs1_key(cert_dir / "key.pem"))
        # The KVM reboots into it, which takes about a minute
        subprocess.run(
            [
                "netcmdr",
                "certificate",
                "--certificate",
                str(cert_dir / "fullchain.pem"),
                "--key",
                str(key),
                "--confirm",
            ],
            env=os.environ
            | {
                "NETCMDR_HOST": fqdn,
                "NETCMDR_USER": username,
                "NETCMDR_PASSWORD": password,
            },
            check=True,
        )
    log("Certificate: uploaded, the KVM reboots into it")
    wait_served(fqdn, desired)


def main() -> None:
    handlers = {"eaton": eaton, "cyberpower": cyberpower, "netcmdr": netcmdr}
    if len(sys.argv) != 4 or sys.argv[1] not in handlers:
        fatal(f"usage: {sys.argv[0]} {'|'.join(handlers)} <fqdn> <dir>")
    kind, fqdn, path = sys.argv[1], sys.argv[2], Path(sys.argv[3])
    try:
        handlers[kind](fqdn, path)
    except CardError as e:
        fatal(f"Certificate: {e}")


if __name__ == "__main__":
    main()
