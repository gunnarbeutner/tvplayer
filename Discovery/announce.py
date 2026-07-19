#!/usr/bin/env python3

from __future__ import annotations

import ipaddress
import os
import signal
import socket
import sys
import threading
from urllib.parse import urlparse

from zeroconf import IPVersion, ServiceInfo, Zeroconf


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


def advertised_address(host: str) -> bytes:
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
    return address.packed


def main() -> int:
    try:
        url = required("TVPLAYER_TVH_URL").strip()
        username = required("TVPLAYER_TVH_USERNAME").strip()
        password = required("TVPLAYER_TVH_PASSWORD")
        profile = os.environ.get("TVPLAYER_TVH_PROFILE", "pass").strip() or "pass"
        xmltv = os.environ.get("TVPLAYER_XMLTV_URL", "").strip()
        instance = os.environ.get("TVPLAYER_MDNS_NAME", "TVPlayer TVHeadend").strip()

        parsed = urlparse(url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ValueError("TVPLAYER_TVH_URL must be an absolute HTTP or HTTPS URL")
        if xmltv:
            parsed_xmltv = urlparse(xmltv)
            if parsed_xmltv.scheme not in {"http", "https"} or not parsed_xmltv.hostname:
                raise ValueError("TVPLAYER_XMLTV_URL must be empty or an absolute HTTP/HTTPS URL")
        if not instance or "." in instance:
            raise ValueError("TVPLAYER_MDNS_NAME must be a non-empty single DNS label")
        if len(instance.encode("utf-8")) > 63:
            raise ValueError("TVPLAYER_MDNS_NAME must be at most 63 UTF-8 bytes")

        port = parsed.port or (443 if parsed.scheme == "https" else 80)
        address = advertised_address(parsed.hostname)
        properties = {
            "version": "1",
            "url": txt_property("url", url),
            "username": txt_property("username", username),
            "password": txt_property("password", password),
            "profile": txt_property("profile", profile),
        }
        if xmltv:
            properties["xmltv"] = txt_property("xmltv", xmltv)

        server_name = f"{socket.gethostname().split('.')[0]}.local."
        info = ServiceInfo(
            SERVICE_TYPE,
            f"{instance}.{SERVICE_TYPE}",
            addresses=[address],
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

    zeroconf = Zeroconf(ip_version=IPVersion.V4Only)
    try:
        zeroconf.register_service(info, allow_name_change=True)
        print(
            f"Advertising {url} as {info.name} on _tvplayer._tcp.local. "
            "(credentials omitted from logs)",
            flush=True,
        )
        stopped.wait()
    finally:
        zeroconf.unregister_service(info)
        zeroconf.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
