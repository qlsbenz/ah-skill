#!/usr/bin/env python3
"""Serve a Godot web export locally with the headers a Godot build needs.

Two things stop a Godot 4 web export from running, and neither produces a
useful message in the browser:

- ``file://``. The engine fetches ``index.wasm`` and ``index.pck`` with
  ``fetch()``; from a ``file://`` URL every one of those requests is blocked by
  CORS and the canvas stays blank.
- Missing cross-origin isolation. A build exported with
  ``variant/thread_support=true`` needs ``SharedArrayBuffer``, and a browser
  only hands that out when the document is *cross-origin isolated*, which needs
  ``Cross-Origin-Opener-Policy: same-origin`` **and**
  ``Cross-Origin-Embedder-Policy: require-corp`` on the HTML response.

This is ``python3 -m http.server`` plus those headers, the right MIME types for
``.wasm``/``.pck`` and no caching (so a re-export is picked up on reload).

    python3 serve_web.py ../build/web                # serve until Ctrl+C
    python3 serve_web.py ../build/web --check        # start, self-test, exit

``--check`` is the headless-agent mode: it starts the server, requests
``index.html`` and the ``.wasm`` over the loopback interface, asserts the status
codes, the content types and the isolation headers, prints one JSON document
and exits. Exit codes: 0 ok, 1 a check failed, 2 the directory is not a Godot
web export.
"""
from __future__ import annotations

import argparse
import http.server
import json
import socketserver
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path

# http.server's mimetypes table is whatever the host has registered, and a
# macOS/Linux box usually has no entry for .wasm or .pck at all — the browser
# then refuses the streaming WebAssembly compile with
# "Incorrect response MIME type. Expected 'application/wasm'".
EXTENSION_TYPES = {
    ".wasm": "application/wasm",
    ".pck": "application/octet-stream",
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".html": "text/html",
    ".json": "application/json",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".svg": "image/svg+xml",
    ".wav": "audio/wav",
    ".ogg": "audio/ogg",
    ".webmanifest": "application/manifest+json",
    ".icns": "image/icns",
    ".data": "application/octet-stream",
    ".side.wasm": "application/wasm",
}

ISOLATION_HEADERS = {
    "Cross-Origin-Opener-Policy": "same-origin",
    "Cross-Origin-Embedder-Policy": "require-corp",
    # Lets the same files be embedded from another origin (itch.io-style
    # iframes) without weakening the document's own isolation, which is what
    # COOP + COEP above provide.
    "Cross-Origin-Resource-Policy": "cross-origin",
}

NO_CACHE_HEADERS = {
    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
    "Pragma": "no-cache",
    "Expires": "0",
}


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Serve a Godot web export with COOP/COEP headers.")
    parser.add_argument("directory", help="Directory holding index.html / index.wasm / index.pck")
    parser.add_argument("--port", type=int, default=8060, help="Port to bind (default 8060; 0 picks a free one)")
    parser.add_argument("--bind", default="127.0.0.1",
                        help="Address to bind (default 127.0.0.1 — loopback only)")
    parser.add_argument("--no-isolation", action="store_true",
                        help="Do not send COOP/COEP. Only for reproducing what a plain static host does.")
    parser.add_argument("--check", action="store_true",
                        help="Start, self-request index.html and the .wasm, print JSON and exit")
    parser.add_argument("--open-url", default="",
                        help="Override the URL printed/checked (path part only, e.g. index.html)")
    parser.add_argument("--pretty", action="store_true")
    return parser.parse_args(argv)


def make_handler(directory: Path, isolation: bool) -> type[http.server.SimpleHTTPRequestHandler]:
    class Handler(http.server.SimpleHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def __init__(self, *args: object, **kwargs: object) -> None:
            super().__init__(*args, directory=str(directory), **kwargs)  # type: ignore[arg-type]

        def guess_type(self, path: str) -> str:  # type: ignore[override]
            lowered = str(path).lower()
            for suffix, content_type in EXTENSION_TYPES.items():
                if lowered.endswith(suffix):
                    return content_type
            return super().guess_type(path)

        def end_headers(self) -> None:
            if isolation:
                for name, value in ISOLATION_HEADERS.items():
                    self.send_header(name, value)
            for name, value in NO_CACHE_HEADERS.items():
                self.send_header(name, value)
            super().end_headers()

        def log_message(self, fmt: str, *args: object) -> None:
            # Keep stdout clean for the JSON document; requests go to stderr.
            sys.stderr.write("[serve_web] %s - %s\n" % (self.address_string(), fmt % args))

    return Handler


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def describe_export(directory: Path) -> dict:
    """Which of the files a Godot web export writes are present."""
    html = sorted(directory.glob("*.html"))
    wasm = sorted(p for p in directory.glob("*.wasm") if not p.name.endswith(".side.wasm"))
    scripts = sorted(directory.glob("*.js"))
    return {
        "html": [p.name for p in html],
        "wasm": [p.name for p in wasm],
        "pck": [p.name for p in sorted(directory.glob("*.pck"))],
        "js": [p.name for p in scripts],
        "threaded": is_threaded_build(directory, scripts),
    }


def is_threaded_build(directory: Path, scripts: list[Path]) -> bool:
    """A variant/thread_support=true build needs cross-origin isolation to run.

    4.7 writes no separate worker file for it — measured, a threaded and a
    single-threaded export of the same project produce the *same* file names.
    The loader itself is the tell: Emscripten's `PThread` runtime appears 38
    times in the threaded `index.js` and not at all in the other one.
    """
    if any((directory / name).is_file() for name in ("index.worker.js", "godot.worker.js")):
        return True
    for script in scripts:
        try:
            if "PThread" in script.read_text(encoding="utf-8", errors="replace"):
                return True
        except OSError:
            continue
    return False


def refuse(message: str, **extra: object) -> int:
    payload = {"ok": False, "error": message}
    payload.update(extra)
    print(json.dumps(payload, indent=2))
    return 2


def fetch(url: str) -> tuple[int, dict[str, str], int]:
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read()
            return response.status, {k.lower(): v for k, v in response.headers.items()}, len(body)
    except urllib.error.HTTPError as error:
        return error.code, {k.lower(): v for k, v in error.headers.items()}, 0


def run_checks(base_url: str, entry: str, export: dict, isolation: bool) -> tuple[bool, list[dict]]:
    checks: list[dict] = []

    def record(name: str, ok: bool, detail: str) -> None:
        checks.append({"check": name, "ok": ok, "detail": detail})

    status, headers, size = fetch(f"{base_url}/{entry}")
    record(f"GET /{entry}", status == 200, f"status {status}, {size} bytes")
    record("index content-type", headers.get("content-type", "").startswith("text/html"),
           headers.get("content-type", "<missing>"))
    for name, value in ISOLATION_HEADERS.items():
        actual = headers.get(name.lower(), "")
        if isolation:
            record(name, actual == value, actual or "<missing>")
        else:
            record(name, actual == "", actual or "<absent, as requested>")
    record("cache-control", "no-store" in headers.get("cache-control", ""),
           headers.get("cache-control", "<missing>"))

    if export["wasm"]:
        wasm_name = export["wasm"][0]
        status, headers, size = fetch(f"{base_url}/{wasm_name}")
        record(f"GET /{wasm_name}", status == 200 and size > 1024, f"status {status}, {size} bytes")
        record("wasm content-type", headers.get("content-type", "") == "application/wasm",
               headers.get("content-type", "<missing>"))
    if export["pck"]:
        pck_name = export["pck"][0]
        status, headers, size = fetch(f"{base_url}/{pck_name}")
        record(f"GET /{pck_name}", status == 200 and size > 0, f"status {status}, {size} bytes")
        record("pck content-type", headers.get("content-type", "") == "application/octet-stream",
               headers.get("content-type", "<missing>"))
    status, _, _ = fetch(f"{base_url}/definitely-not-here.txt")
    record("missing file is 404", status == 404, f"status {status}")
    return all(item["ok"] for item in checks), checks


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    directory = Path(args.directory).expanduser().resolve()
    if not directory.is_dir():
        return refuse(f"Not a directory: {directory}")

    export = describe_export(directory)
    if not export["html"]:
        return refuse(
            f"No .html file in {directory} — that is not a Godot web export. Create one with:\n"
            "  godot --headless --path PROJECT --script scripts/core/dispatcher.gd "
            "add_export_preset '{\"platform\":\"web\"}'\n"
            "  python3 scripts/export/export_project.py PROJECT Web "
            f"{directory}/index.html",
            directory=str(directory), found=sorted(p.name for p in directory.iterdir())[:20])
    entry = args.open_url or ("index.html" if "index.html" in export["html"] else export["html"][0])
    isolation = not args.no_isolation

    handler = make_handler(directory, isolation)
    try:
        server = Server((args.bind, args.port), handler)
    except OSError as error:
        return refuse(f"Cannot bind {args.bind}:{args.port} — {error}. "
                      "Pass --port 0 to let the OS pick a free port.")
    host, port = server.server_address[0], server.server_address[1]
    display_host = host if host not in ("0.0.0.0", "::") else "127.0.0.1"
    base_url = f"http://{display_host}:{port}"

    if args.check:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            passed, checks = run_checks(base_url, entry, export, isolation)
        finally:
            server.shutdown()
            server.server_close()
        payload = {
            "ok": passed,
            "url": f"{base_url}/{entry}",
            "directory": str(directory),
            "port": port,
            "isolation": isolation,
            "cross_origin_isolated": isolation,
            "threaded_build": export["threaded"],
            "files": export,
            "checks": checks,
            "failed": [item for item in checks if not item["ok"]],
        }
        print(json.dumps(payload, indent=2 if args.pretty else None))
        return 0 if passed else 1

    payload = {
        "ok": True,
        "url": f"{base_url}/{entry}",
        "directory": str(directory),
        "port": port,
        "isolation": isolation,
        "threaded_build": export["threaded"],
        "files": export,
        "headers": dict(ISOLATION_HEADERS) if isolation else {},
        "stop": "Ctrl+C",
    }
    print(json.dumps(payload, indent=2 if args.pretty else None), flush=True)
    print(f"Serving {directory} at {base_url}/{entry}  (Ctrl+C to stop)", flush=True)
    if export["threaded"] and not isolation:
        print("WARNING: this is a threaded build and --no-isolation is set; "
              "SharedArrayBuffer will be unavailable and the page will fail to start.",
              file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
