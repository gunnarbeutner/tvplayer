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
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import TypeAlias
from urllib.parse import urlparse

import ifaddr
from zeroconf import IPVersion, ServiceInfo, Zeroconf

from guide_cache import GuideCache


TVHEADEND_SERVICE_TYPE = "_tvplayer._tcp.local."
GUIDE_SERVICE_TYPE = "_tvplayer-guide._tcp.local."
IPAddress: TypeAlias = ipaddress.IPv4Address | ipaddress.IPv6Address


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise ValueError(f"{name} must not be empty")
    return value


def tvheadend_credentials() -> tuple[str, str]:
    username = os.environ.get("TVPLAYER_TVH_USERNAME", "").strip()
    password = os.environ.get("TVPLAYER_TVH_PASSWORD", "")
    if bool(username) != bool(password):
        raise ValueError(
            "TVPLAYER_TVH_USERNAME and TVPLAYER_TVH_PASSWORD must both be set or both be empty"
        )
    return username, password


def credential_txt_properties(username: str, password: str) -> dict[str, str]:
    if bool(username) != bool(password):
        raise ValueError("A username and password must be advertised together")
    if not username:
        return {}
    return {
        "username": txt_property("username", username),
        "password": txt_property("password", password),
    }


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


def resolved_addresses(host: str) -> list[IPAddress]:
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        resolved = socket.getaddrinfo(host, None, socket.AF_UNSPEC, socket.SOCK_STREAM)
        addresses = {
            ipaddress.ip_address(result[4][0])
            for result in resolved
        }
        if not addresses:
            raise ValueError(f"Could not resolve an address for {host}")
        return sorted(addresses, key=lambda value: (value.version, int(value)))

    return [address]


def usable_lan_address(address: IPAddress) -> bool:
    return not (
        address.is_unspecified
        or address.is_loopback
        or address.is_multicast
    )


def adapter_addresses(adapter: object) -> list[IPAddress]:
    addresses: set[IPAddress] = set()
    for adapter_ip in adapter.ips:  # type: ignore[attr-defined]
        raw = adapter_ip.ip[0] if isinstance(adapter_ip.ip, tuple) else adapter_ip.ip
        address = ipaddress.ip_address(raw.split("%", 1)[0])
        if usable_lan_address(address):
            addresses.add(address)
    return sorted(addresses, key=lambda value: (value.version, int(value)))


def route_source_address(destination: IPAddress) -> IPAddress:
    family = socket.AF_INET6 if destination.version == 6 else socket.AF_INET
    endpoint: tuple[object, ...]
    if destination.version == 6:
        endpoint = (str(destination), 9, 0, 0)
    else:
        endpoint = (str(destination), 9)
    with socket.socket(family, socket.SOCK_DGRAM) as route:
        route.connect(endpoint)
        return ipaddress.ip_address(route.getsockname()[0].split("%", 1)[0])


def guide_advertised_addresses(tvheadend_addresses: list[IPAddress]) -> list[IPAddress]:
    override = os.environ.get("TVPLAYER_MDNS_ADDRESS", "").strip()
    if override:
        addresses = {
            ipaddress.ip_address(value.strip())
            for value in override.split(",")
            if value.strip()
        }
        if not addresses or not all(usable_lan_address(value) for value in addresses):
            raise ValueError(
                "TVPLAYER_MDNS_ADDRESS must contain usable comma-separated IP addresses"
            )
        return sorted(addresses, key=lambda value: (value.version, int(value)))

    # A UDP connect does not send a packet, but lets the kernel select the
    # interface that can reach TVheadend. We then advertise every usable IPv4
    # and IPv6 address on that interface.
    source_addresses: list[IPAddress] = []
    for destination in tvheadend_addresses:
        try:
            source = route_source_address(destination)
        except OSError:
            continue
        if usable_lan_address(source):
            source_addresses.append(source)

    adapters = [(adapter, adapter_addresses(adapter)) for adapter in ifaddr.get_adapters()]
    for source in source_addresses:
        for _adapter, addresses in adapters:
            if source in addresses:
                return addresses

    # A local TVheadend address can cause the route lookup to choose loopback.
    # The IPv4 mDNS route identifies the primary LAN interface in that case.
    try:
        multicast_source = route_source_address(ipaddress.ip_address("224.0.0.251"))
    except OSError:
        multicast_source = None
    if multicast_source is not None:
        for _adapter, addresses in adapters:
            if multicast_source in addresses:
                return addresses

    for _adapter, addresses in adapters:
        if addresses:
            return addresses
    raise ValueError(
        "Could not determine the discovery daemon's LAN addresses; "
        "set TVPLAYER_MDNS_ADDRESS"
    )


class DualStackThreadingHTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self) -> None:
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def make_guide_http_server(
    bind: str,
    port: int,
    handler: type[BaseHTTPRequestHandler],
) -> ThreadingHTTPServer:
    bind_address = ipaddress.ip_address(bind.split("%", 1)[0])
    server_type = DualStackThreadingHTTPServer if bind_address.version == 6 else ThreadingHTTPServer
    return server_type((bind, port), handler)


def addresses_served_by_guide(bind: str, addresses: list[IPAddress]) -> list[IPAddress]:
    bind_address = ipaddress.ip_address(bind.split("%", 1)[0])
    if not bind_address.is_unspecified:
        return [bind_address]
    if bind_address.version == 4:
        ipv4_addresses = [address for address in addresses if address.version == 4]
        if not ipv4_addresses:
            raise ValueError("TVPLAYER_GUIDE_BIND is IPv4-only but no IPv4 address is available")
        return ipv4_addresses
    return addresses


def service_target(host: str, stable_id: str) -> str:
    try:
        ipaddress.ip_address(host)
    except ValueError:
        target = host.rstrip(".")
        if "." not in target:
            target = f"{target}.local"
        return f"{target}."
    return f"tvheadend-{stable_id[:8]}.local."


def guide_server_name() -> str:
    configured = os.environ.get("TVPLAYER_MDNS_HOSTNAME", "").strip()
    target = (configured or socket.gethostname().split(".")[0]).rstrip(".")
    if not target:
        raise ValueError("TVPLAYER_MDNS_HOSTNAME must not be empty")
    if "." not in target:
        target = f"{target}.local"
    return f"{target}."


def discovery_id() -> str:
    configured = os.environ.get("TVPLAYER_MDNS_ID", "").strip()
    if configured:
        return txt_property("id", configured)

    path = Path(os.environ.get("TVPLAYER_MDNS_ID_PATH", "/data/discovery-id").strip())
    try:
        saved = path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        saved = ""
    if saved:
        return txt_property("id", saved)

    generated = str(uuid.uuid4())
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(f"{generated}\n", encoding="utf-8")
    temporary.replace(path)
    return generated


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
        username, password = tvheadend_credentials()
        profile = os.environ.get("TVPLAYER_TVH_PROFILE", "pass").strip() or "pass"
        htsp_port = integer_setting("TVPLAYER_TVH_HTSP_PORT", 9982, 1, 65535)
        instance = os.environ.get("TVPLAYER_MDNS_NAME", "TVPlayer TVHeadend").strip()
        guide_port = integer_setting("TVPLAYER_GUIDE_PORT", 49382, 1, 65535)
        guide_refresh = integer_setting("TVPLAYER_GUIDE_REFRESH_SECONDS", 60, 15, 3600)
        guide_retention = integer_setting("TVPLAYER_GUIDE_RETENTION_HOURS", 24, 1, 720)
        guide_future = integer_setting("TVPLAYER_GUIDE_FUTURE_HOURS", 72, 6, 720)
        guide_limit = integer_setting("TVPLAYER_GUIDE_EVENT_LIMIT", 50_000, 1_000, 500_000)
        guide_bind = os.environ.get("TVPLAYER_GUIDE_BIND", "::").strip()
        guide_cache_path = os.environ.get(
            "TVPLAYER_GUIDE_CACHE_PATH",
            "/data/guide-cache.json",
        ).strip()

        parsed = urlparse(url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ValueError("TVPLAYER_TVH_URL must be an absolute HTTP or HTTPS URL")
        if parsed.query or parsed.fragment:
            raise ValueError("TVPLAYER_TVH_URL must not contain a query or fragment")
        if not instance or "." in instance:
            raise ValueError("TVPLAYER_MDNS_NAME must be a non-empty single DNS label")
        if len(instance.encode("utf-8")) > 63:
            raise ValueError("TVPLAYER_MDNS_NAME must be at most 63 UTF-8 bytes")

        stable_id = discovery_id()
        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        tvheadend_addresses = resolved_addresses(parsed.hostname)
        guide_addresses = addresses_served_by_guide(
            guide_bind,
            guide_advertised_addresses(tvheadend_addresses),
        )
        guide_target = guide_server_name()
        uses_shared_host = bool(set(guide_addresses) & set(tvheadend_addresses))
        tvheadend_target = guide_target if uses_shared_host else service_target(
            parsed.hostname,
            stable_id,
        )
        if uses_shared_host:
            tvheadend_addresses = guide_addresses

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
        http_server = make_guide_http_server(guide_bind, guide_port, guide_handler(cache))
        tvheadend_properties = {
            "txtvers": "1",
            "id": stable_id,
            "scheme": parsed.scheme,
            "path": txt_property("path", parsed.path or "/"),
            "profile": txt_property("profile", profile),
            "htsp_port": txt_property("htsp_port", str(htsp_port)),
        }
        tvheadend_properties.update(credential_txt_properties(username, password))
        guide_properties = {
            "txtvers": "1",
            "id": stable_id,
            "scheme": "http",
            "path": "/guide.json",
            "format": "tvplayer-json",
        }

        tvheadend_info = ServiceInfo(
            TVHEADEND_SERVICE_TYPE,
            f"{instance}.{TVHEADEND_SERVICE_TYPE}",
            addresses=[address.packed for address in tvheadend_addresses],
            port=port,
            properties=tvheadend_properties,
            server=tvheadend_target,
        )
        guide_info = ServiceInfo(
            GUIDE_SERVICE_TYPE,
            f"{instance}.{GUIDE_SERVICE_TYPE}",
            addresses=[address.packed for address in guide_addresses],
            port=guide_port,
            properties=guide_properties,
            server=guide_target,
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

    zeroconf = Zeroconf(ip_version=IPVersion.All)
    registered: list[ServiceInfo] = []
    try:
        for info in (tvheadend_info, guide_info):
            zeroconf.register_service(info, allow_name_change=True)
            registered.append(info)
        print(
            f"Advertising TVheadend {tvheadend_info.server}:{tvheadend_info.port} "
            f"and guide {guide_info.server}:{guide_info.port} "
            f"with discovery ID {stable_id} "
            "(credentials omitted from logs)",
            flush=True,
        )
        stopped.wait()
    finally:
        stopped.set()
        for info in reversed(registered):
            zeroconf.unregister_service(info)
        zeroconf.close()
        http_server.shutdown()
        http_server.server_close()
        http_thread.join(timeout=5)
        refresh_thread.join(timeout=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
