from __future__ import annotations

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

from announce import discovery_id


class AnnounceTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
