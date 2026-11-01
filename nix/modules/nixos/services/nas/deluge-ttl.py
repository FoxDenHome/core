import logging
import os
import sys
import time

from deluge_client import DelugeRPCClient
from deluge_client.client import RemoteException

DELUGE_HOST = "127.0.0.1"
DELUGE_PORT = 58846
DELUGE_USER = "localclient"

logger = logging.getLogger("deluge-ttl")


def read_password(auth_file: str) -> str | None:
    with open(auth_file) as f:
        for line in f:
            parts = line.strip().split(":")
            if len(parts) >= 2 and parts[0] == DELUGE_USER:
                return parts[1]
    return None


def purge(client: DelugeRPCClient, ttl_seconds: int) -> bool:
    now = time.time()
    torrents = client.call("core.get_torrents_status", {}, ["name", "time_added"])

    ok = True
    for torrent_id, status in torrents.items():
        time_added = status.get("time_added") or 0
        # Never purge on a missing timestamp, it would read as 1970
        if time_added <= 0:
            logger.warning(
                "Skipping %s (%s): no time_added", torrent_id, status.get("name")
            )
            continue

        age = now - time_added
        if age < ttl_seconds:
            continue

        logger.info(
            "Removing %s (%s), added %.1f days ago",
            torrent_id,
            status.get("name"),
            age / 86400,
        )
        try:
            client.call("core.remove_torrent", torrent_id, True)
        except RemoteException:
            logger.exception("Failed to remove %s", torrent_id)
            ok = False

    return ok


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    ttl_seconds = int(os.environ["DELUGE_TTL_SECONDS"])

    password = read_password(os.environ["DELUGE_AUTH_FILE"])
    if password is None:
        logger.error("%s not found in deluge auth file", DELUGE_USER)
        return 1

    client = DelugeRPCClient(
        DELUGE_HOST, DELUGE_PORT, DELUGE_USER, password, decode_utf8=True
    )
    client.connect()
    return 0 if purge(client, ttl_seconds) else 1


if __name__ == "__main__":
    sys.exit(main())
