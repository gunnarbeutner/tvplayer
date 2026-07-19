#!/usr/bin/env python3

from __future__ import annotations

import ipaddress
import json
import os
import signal
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

from zeroconf import IPVersion, ServiceInfo, Zeroconf

from guide_cache import GuideCache


SERVICE_TYPE = "_tvplayer._tcp.local."


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise ValueError(f"{name} must not be empty")
    return value


def txt_property(key: str, value: str) -> str:
    if len(f"{key}={value}".encode("utf-8")) > 255:
        raise ValueError(f"{key} is too long for a DNS-SD TXT property")
    return value


def integer_setting(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name, str(default)).strip()
    try:
        value = int(raw)
    except ValueError as error:
        raise ValueError(f"{name} must be an integer") from error
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def advertised_address(host: str) -> ipaddress.IPv4Address:
    override = os.environ.get("TVPLAYER_MDNS_ADDRESS", "").strip()
    candidate = override or host

    try:
        address = ipaddress.ip_address(candidate)
    except ValueError:
        addresses = socket.getaddrinfo(candidate, None, socket.AF_INET, socket.SOCK_DGRAM)
        if not addresses:
            raise ValueError(f"Could not resolve an IPv4 address for {candidate}")
        address = ipaddress.ip_address(addresses[0][4][0])

    if address.version != 4:
        raise ValueError("TVPLAYER_MDNS_ADDRESS must be an IPv4 address")
    return address


def guide_handler(cache: GuideCache) -> type[BaseHTTPRequestHandler]:
    class GuideRequestHandler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            path = self.path.partition("?")[0]
            if path == "/guide.json":
                body = cache.json_guide()
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "public, max-age=30")
                self.end_headers()
                self.wfile.write(body)
                return
            if path == "/healthz":
                body = (json.dumps(cache.status(), separators=(",", ":")) + "\n").encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_error(404)

        def log_message(self, format: str, *args: object) -> None:
            print(f"Guide HTTP: {format % args}", flush=True)

    return GuideRequestHandler


def main() -> int:
    try:
        url = required("TVPLAYER_TVH_URL").strip()
        username = required("TVPLAYER_TVH_USERNAME").strip()
        password = required("TVPLAYER_TVH_PASSWORD")
        profile = os.environ.get("TVPLAYER_TVH_PROFILE", "pass").strip() or "pass"
        instance = os.environ.get("TVPLAYER_MDNS_NAME", "TVPlayer TVHeadend").strip()
        guide_port = integer_setting("TVPLAYER_GUIDE_PORT", 49382, 1, 65535)
        guide_refresh = integer_setting("TVPLAYER_GUIDE_REFRESH_SECONDS", 60, 15, 3600)
        guide_retention = integer_setting("TVPLAYER_GUIDE_RETENTION_HOURS", 24, 1, 720)
        guide_future = integer_setting("TVPLAYER_GUIDE_FUTURE_HOURS", 72, 6, 720)
        guide_limit = integer_setting("TVPLAYER_GUIDE_EVENT_LIMIT", 50_000, 1_000, 500_000)
        guide_bind = os.environ.get("TVPLAYER_GUIDE_BIND", "0.0.0.0").strip()
        guide_cache_path = os.environ.get(
            "TVPLAYER_GUIDE_CACHE_PATH",
            "/data/guide-cache.json",
        ).strip()

        parsed = urlparse(url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ValueError("TVPLAYER_TVH_URL must be an absolute HTTP or HTTPS URL")
        if not instance or "." in instance:
            raise ValueError("TVPLAYER_MDNS_NAME must be a non-empty single DNS label")
        if len(instance.encode("utf-8")) > 63:
            raise ValueError("TVPLAYER_MDNS_NAME must be at most 63 UTF-8 bytes")

        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        address = advertised_address(parsed.hostname)
        guide = f"http://{address}:{guide_port}/guide.json"

        cache = GuideCache(
            base_url=url,
            username=username,
            password=password,
            cache_path=guide_cache_path,
            retention_hours=guide_retention,
            future_hours=guide_future,
            event_limit=guide_limit,
        )
        try:
            channel_count, event_count = cache.refresh()
            print(
                f"Initial guide cache: {channel_count} channels, {event_count} events",
                flush=True,
            )
        except Exception as error:
            if cache.status()["events"] == 0:
                raise ValueError(f"Initial guide refresh failed and no saved cache exists: {error}") from error
            print(
                f"Initial guide refresh failed; serving the saved cache: {error}",
                file=sys.stderr,
                flush=True,
            )
        http_server = ThreadingHTTPServer((guide_bind, guide_port), guide_handler(cache))
        properties = {
            "version": "1",
            "url": txt_property("url", url),
            "username": txt_property("username", username),
            "password": txt_property("password", password),
            "profile": txt_property("profile", profile),
            "guide": txt_property("guide", guide),
        }

        server_name = f"{socket.gethostname().split('.')[0]}.local."
        info = ServiceInfo(
            SERVICE_TYPE,
            f"{instance}.{SERVICE_TYPE}",
            addresses=[address.packed],
            port=port,
            properties=properties,
            server=server_name,
        )
    except (OSError, ValueError) as error:
        print(f"Configuration error: {error}", file=sys.stderr, flush=True)
        return 2

    stopped = threading.Event()

    def stop(_signum: int, _frame: object) -> None:
        stopped.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    def refresh_guide() -> None:
        while not stopped.is_set():
            if stopped.wait(guide_refresh):
                return
            started = time.monotonic()
            try:
                channel_count, event_count = cache.refresh()
                print(
                    f"Guide cache refreshed: {channel_count} channels, {event_count} events",
                    flush=True,
                )
            except Exception as error:
                print(f"Guide cache refresh failed: {error}", file=sys.stderr, flush=True)
            elapsed = time.monotonic() - started
            if elapsed > guide_refresh:
                print(
                    f"Guide refresh took {elapsed:.1f}s, longer than its {guide_refresh}s interval",
                    flush=True,
                )

    http_thread = threading.Thread(target=http_server.serve_forever, name="guide-http", daemon=True)
    refresh_thread = threading.Thread(target=refresh_guide, name="guide-refresh", daemon=True)
    http_thread.start()
    refresh_thread.start()

    zeroconf = Zeroconf(ip_version=IPVersion.V4Only)
    try:
        zeroconf.register_service(info, allow_name_change=True)
        print(
            f"Advertising {url} and rich guide {guide} as {info.name} "
            "on _tvplayer._tcp.local. "
            "(credentials omitted from logs)",
            flush=True,
        )
        stopped.wait()
    finally:
        stopped.set()
        zeroconf.unregister_service(info)
        zeroconf.close()
        http_server.shutdown()
        http_server.server_close()
        http_thread.join(timeout=5)
        refresh_thread.join(timeout=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
