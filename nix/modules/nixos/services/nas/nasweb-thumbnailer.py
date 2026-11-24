# Renders and caches thumbnails for nasweb's grid view.
#
# nginx (njs) has already checked access (login or share token) and maps
# "?thumb=<size>" to an internal "/_jsindex-static/_thumb/<size>/<fs path>"
# location proxied here. Results are cached on disk keyed by path, mtime and
# size, so a changed file gets a fresh thumbnail and nothing is rendered twice.
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

ROOT = os.path.realpath(os.environ.get("THUMB_ROOT", "/data"))
CACHE = os.environ["CACHE_DIRECTORY"].split(":")[0]
VIPSTHUMBNAIL = os.environ["VIPSTHUMBNAIL"]
FFMPEG = os.environ["FFMPEG"]
LISTEN_HOST, LISTEN_PORT = os.environ.get("LISTEN", "127.0.0.1:4190").rsplit(":", 1)
WORKERS = int(os.environ.get("WORKERS", "4"))
# Drop cache entries nobody asked for in this long (their source is usually gone or changed)
PRUNE_AFTER = int(os.environ.get("PRUNE_AFTER_DAYS", "90")) * 86400
# Refresh an entry's mtime at most this often when it gets served, as the "last used" marker
TOUCH_AFTER = 86400

PREFIX = "/_jsindex-static/_thumb/"
SIZES = {
    "small": (400, 75),
    "large": (1920, 85),
}
IMAGE_EXTS = {
    "jpg", "jpeg", "png", "gif", "webp", "avif", "bmp", "svg", "ico",
    "apng", "jxl", "heic", "heif", "tif", "tiff",
}
VIDEO_EXTS = {"mp4", "webm", "m4v", "mov", "ogv", "mkv"}

render_slots = threading.BoundedSemaphore(WORKERS)
key_locks = {}
key_locks_lock = threading.Lock()


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def run(cmd, timeout):
    res = subprocess.run(
        cmd,
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    if res.returncode != 0:
        raise RuntimeError(f"{cmd[0]} exited {res.returncode}: {res.stderr.decode(errors='replace').strip()[-500:]}")


def vips_thumbnail(src, dst, size):
    dim, quality = SIZES[size]
    run([
        VIPSTHUMBNAIL, src,
        "--size", f"{dim}x{dim}>",
        "-o", f"{dst}[Q={quality},strip]",
    ], timeout=120)


def video_frame(src, dst):
    # Seek a bit in to skip black intro frames, but tiny clips may be shorter than that
    for seek in ("1", "0"):
        try:
            run([
                FFMPEG, "-nostdin", "-v", "error", "-y",
                "-ss", seek, "-i", src,
                "-frames:v", "1", "-f", "image2", "-c:v", "png", dst,
            ], timeout=60)
        except RuntimeError:
            if seek == "0":
                raise
            continue
        # Seeking past the end of a short clip "succeeds" without writing anything
        if os.path.exists(dst) and os.path.getsize(dst) > 0:
            return
    raise RuntimeError("ffmpeg produced no frame")


def render(src, kind, size, out):
    with tempfile.TemporaryDirectory(dir=CACHE, prefix=".work-") as work:
        dst = os.path.join(work, "thumb.webp")
        if kind == "video":
            frame = os.path.join(work, "frame.png")
            video_frame(src, frame)
            vips_thumbnail(frame, dst, size)
        else:
            try:
                vips_thumbnail(src, dst, size)
            except RuntimeError:
                # e.g. formats libvips has no loader for, ffmpeg might
                frame = os.path.join(work, "frame.png")
                video_frame(src, frame)
                vips_thumbnail(frame, dst, size)
        os.replace(dst, out)


def lock_for(key):
    with key_locks_lock:
        lock = key_locks.get(key)
        if lock is None:
            lock = key_locks[key] = [threading.Lock(), 0]
        lock[1] += 1
        return lock


def release(key, lock):
    with key_locks_lock:
        lock[1] -= 1
        if lock[1] == 0:
            del key_locks[key]


def get_thumbnail(src, kind, size):
    """Returns (path, etag), or None if the file can't be thumbnailed"""
    st = os.stat(src)
    key = hashlib.sha256(f"{src}\0{st.st_mtime_ns}\0{st.st_size}\0{size}".encode()).hexdigest()
    shard = os.path.join(CACHE, key[:2])
    out = os.path.join(shard, f"{key}.webp")
    failed = os.path.join(shard, f"{key}.failed")

    lock = lock_for(key)
    try:
        with lock[0]:
            if os.path.exists(failed):
                return None
            if not os.path.exists(out):
                os.makedirs(shard, exist_ok=True)
                with render_slots:
                    try:
                        render(src, kind, size, out)
                    except Exception as e:  # noqa: BLE001
                        log(f"thumbnail failed for {src!r}: {e}")
                        open(failed, "w").close()
                        return None
            else:
                now = time.time()
                if now - os.stat(out).st_mtime > TOUCH_AFTER:
                    os.utime(out, (now, now))
    finally:
        release(key, lock)
    return out, key


def prune_loop():
    while True:
        cutoff = time.time() - PRUNE_AFTER
        removed = 0
        for dirpath, dirnames, filenames in os.walk(CACHE):
            for name in dirnames:
                work = os.path.join(dirpath, name)
                # Leftovers of renders interrupted by a restart (live ones are minutes old at most)
                try:
                    if name.startswith(".work-") and os.stat(work).st_mtime < time.time() - 3600:
                        shutil.rmtree(work, ignore_errors=True)
                except FileNotFoundError:
                    pass
            dirnames[:] = [d for d in dirnames if not d.startswith(".work-")]
            for name in filenames:
                path = os.path.join(dirpath, name)
                try:
                    if os.stat(path).st_mtime < cutoff:
                        os.unlink(path)
                        removed += 1
                except FileNotFoundError:
                    pass
        if removed:
            log(f"pruned {removed} stale cache entries")
        time.sleep(86400)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def fail(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if not path.startswith(PREFIX):
            return self.fail(404)
        size, _, rel = unquote(path[len(PREFIX):]).partition("/")
        if size not in SIZES or "\0" in rel:
            return self.fail(400)

        src = os.path.realpath("/" + rel)
        if not src.startswith(ROOT + "/"):
            return self.fail(403)

        ext = src.rsplit(".", 1)[-1].lower() if "." in os.path.basename(src) else ""
        kind = "video" if ext in VIDEO_EXTS else "image" if ext in IMAGE_EXTS else None
        if kind is None:
            return self.fail(404)

        try:
            if not os.path.isfile(src):
                return self.fail(404)
            result = get_thumbnail(src, kind, size)
        except (FileNotFoundError, NotADirectoryError):
            return self.fail(404)
        except PermissionError:
            return self.fail(403)
        if result is None:
            return self.fail(404)

        out, etag = result
        etag = f'"{etag}"'
        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.end_headers()
            return

        with open(out, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "image/webp")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "private, max-age=86400")
        self.send_header("ETag", etag)
        self.end_headers()
        self.wfile.write(data)


def main():
    threading.Thread(target=prune_loop, daemon=True).start()
    server = ThreadingHTTPServer((LISTEN_HOST, int(LISTEN_PORT)), Handler)
    server.daemon_threads = True
    log(f"serving thumbnails of {ROOT} from {CACHE} on {LISTEN_HOST}:{LISTEN_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
