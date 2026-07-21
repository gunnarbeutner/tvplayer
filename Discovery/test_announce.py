from __future__ import annotations

import ipaddress
import os
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

# The unit tests exercise pure configuration helpers and do not need the
# optional network dependency installed by the container image.
sys.modules.setdefault(
    "zeroconf",
    SimpleNamespace(IPVersion=object, ServiceInfo=object, Zeroconf=object),
)
sys.modules.setdefault("ifaddr", SimpleNamespace(get_adapters=lambda: []))

from announce import (
    addresses_served_by_guide,
    credential_txt_properties,
    discovery_id,
    etag_matches,
    guide_advertised_addresses,
    resolved_addresses,
    service_target,
    tvheadend_credentials,
)


class AnnounceTests(unittest.TestCase):
    def test_if_none_match_uses_weak_etag_comparison(self) -> None:
        current = 'W/"guide-content"'

        self.assertTrue(etag_matches(current, current))
        self.assertTrue(etag_matches('"other", "guide-content"', current))
        self.assertTrue(etag_matches("*", current))
        self.assertFalse(etag_matches(None, current))
        self.assertFalse(etag_matches('W/"different"', current))

    def test_tvheadend_credentials_allow_authenticated_access(self) -> None:
        with patch.dict(
            os.environ,
            {
                "TVPLAYER_TVH_USERNAME": " viewer ",
                "TVPLAYER_TVH_PASSWORD": "secret",
            },
            clear=False,
        ):
            self.assertEqual(tvheadend_credentials(), ("viewer", "secret"))

    def test_tvheadend_credentials_allow_anonymous_access(self) -> None:
        with patch.dict(
            os.environ,
            {
                "TVPLAYER_TVH_USERNAME": "",
                "TVPLAYER_TVH_PASSWORD": "",
            },
            clear=False,
        ):
            self.assertEqual(tvheadend_credentials(), ("", ""))

    def test_tvheadend_credentials_reject_partial_credentials(self) -> None:
        for username, password in [("viewer", ""), ("", "secret")]:
            with self.subTest(username=username, password=password), patch.dict(
                os.environ,
                {
                    "TVPLAYER_TVH_USERNAME": username,
                    "TVPLAYER_TVH_PASSWORD": password,
                },
                clear=False,
            ):
                with self.assertRaisesRegex(ValueError, "must both be set or both be empty"):
                    tvheadend_credentials()

    def test_txt_credentials_distinguish_supported_access_modes(self) -> None:
        self.assertEqual(credential_txt_properties("", ""), {})
        self.assertEqual(
            credential_txt_properties("viewer", "secret"),
            {"username": "viewer", "password": "secret"},
        )
        with self.assertRaisesRegex(ValueError, "advertised together"):
            credential_txt_properties("viewer", "")

    def test_configured_discovery_id_takes_precedence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "discovery-id"
            with patch.dict(
                os.environ,
                {
                    "TVPLAYER_MDNS_ID": "configured-server",
                    "TVPLAYER_MDNS_ID_PATH": str(path),
                },
                clear=False,
            ):
                self.assertEqual(discovery_id(), "configured-server")
                self.assertFalse(path.exists())

    def test_generated_discovery_id_is_stable_across_calls(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "discovery-id"
            with patch.dict(
                os.environ,
                {
                    "TVPLAYER_MDNS_ID": "",
                    "TVPLAYER_MDNS_ID_PATH": str(path),
                },
                clear=False,
            ):
                first = discovery_id()
                second = discovery_id()

            self.assertEqual(second, first)
            self.assertEqual(path.read_text(encoding="utf-8").strip(), first)
            self.assertEqual(str(uuid.UUID(first)), first)

    def test_ip_tvheadend_uses_a_stable_synthetic_srv_target(self) -> None:
        self.assertEqual(
            service_target("192.168.3.5", "550e8400-e29b-41d4-a716-446655440000"),
            "tvheadend-550e8400.local.",
        )

    def test_hostname_tvheadend_uses_its_hostname_as_srv_target(self) -> None:
        self.assertEqual(
            service_target("tvheadend.local", "unused"),
            "tvheadend.local.",
        )
        self.assertEqual(
            service_target("tvheadend.example.com", "unused"),
            "tvheadend.example.com.",
        )

    def test_explicit_guide_addresses_are_only_a_guide_endpoint_override(self) -> None:
        with patch.dict(
            os.environ,
            {"TVPLAYER_MDNS_ADDRESS": "192.168.3.9,fd00::9"},
            clear=False,
        ):
            self.assertEqual(
                [
                    str(address)
                    for address in guide_advertised_addresses(
                        [ipaddress.ip_address("192.168.3.5")]
                    )
                ],
                ["192.168.3.9", "fd00::9"],
            )

    def test_guide_advertises_ipv4_and_ipv6_on_selected_interface(self) -> None:
        selected_adapter = SimpleNamespace(ips=[
            SimpleNamespace(ip="192.168.3.5"),
            SimpleNamespace(ip=("fe80::1234", 0, 2)),
            SimpleNamespace(ip=("fd00::5", 0, 2)),
        ])
        unrelated_adapter = SimpleNamespace(ips=[SimpleNamespace(ip="10.0.0.1")])
        with patch.dict(os.environ, {"TVPLAYER_MDNS_ADDRESS": ""}, clear=False), patch(
            "announce.route_source_address",
            return_value=ipaddress.ip_address("192.168.3.5"),
        ), patch(
            "announce.ifaddr.get_adapters",
            return_value=[unrelated_adapter, selected_adapter],
        ):
            addresses = guide_advertised_addresses([
                ipaddress.ip_address("192.168.3.5")
            ])

        self.assertEqual(
            [str(address) for address in addresses],
            ["192.168.3.5", "fd00::5", "fe80::1234"],
        )

    def test_ipv6_literal_is_a_resolved_endpoint(self) -> None:
        self.assertEqual(
            resolved_addresses("fd00::5"),
            [ipaddress.ip_address("fd00::5")],
        )

    def test_ipv4_guide_bind_does_not_advertise_unserved_ipv6(self) -> None:
        addresses = [
            ipaddress.ip_address("192.168.3.5"),
            ipaddress.ip_address("fd00::5"),
        ]
        self.assertEqual(
            addresses_served_by_guide("0.0.0.0", addresses),
            [ipaddress.ip_address("192.168.3.5")],
        )
        self.assertEqual(addresses_served_by_guide("::", addresses), addresses)


if __name__ == "__main__":
    unittest.main()
