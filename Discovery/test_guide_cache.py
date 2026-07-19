from __future__ import annotations

import io
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from guide_cache import GuideCache


class FakeOpener:
    def __init__(self, channels: list[dict], events: list[dict]) -> None:
        self.channels = channels
        self.events = events

    def open(self, request: object, timeout: int) -> io.BytesIO:
        url = request.full_url
        entries = self.channels if "/api/channel/grid" in url else self.events
        return io.BytesIO(json.dumps({"entries": entries}).encode())


class GuideCacheTests(unittest.TestCase):
    def test_finished_programmes_remain_in_xmltv_until_retention_expires(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "guide-cache.json")
            now = 100_000
            opener = FakeOpener(
                channels=[
                    {
                        "uuid": "channel-1",
                        "name": "Test & One",
                        "icon_public_url": "imagecache/1",
                    }
                ],
                events=[
                    {
                        "eventId": 1,
                        "channelUuid": "channel-1",
                        "title": "Earlier <Show>",
                        "description": "Already finished",
                        "start": now - 3_600,
                        "stop": now - 1_800,
                    },
                    {
                        "eventId": 2,
                        "channelUuid": "channel-1",
                        "title": "Current Show",
                        "start": now - 300,
                        "stop": now + 1_500,
                    },
                ],
            )
            cache = GuideCache(
                base_url="http://tvheadend.test:9981",
                username="viewer",
                password="secret",
                cache_path=path,
                retention_hours=1,
                opener=opener,
            )

            cache.refresh(now=now)
            root = ET.fromstring(cache.xmltv())

            self.assertEqual(root.findtext("./channel/display-name"), "Test & One")
            self.assertEqual(
                [programme.findtext("title") for programme in root.findall("programme")],
                ["Earlier <Show>", "Current Show"],
            )

            opener.events = [opener.events[1]]
            cache.refresh(now=now + 3_601)
            root = ET.fromstring(cache.xmltv())
            self.assertEqual(
                [programme.findtext("title") for programme in root.findall("programme")],
                ["Current Show"],
            )

    def test_cache_survives_process_restart(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "guide-cache.json")
            now = 100_000
            opener = FakeOpener(
                channels=[{"uuid": "channel-1", "name": "Test"}],
                events=[
                    {
                        "eventId": 1,
                        "channelUuid": "channel-1",
                        "title": "Persisted Show",
                        "start": now - 600,
                        "stop": now + 600,
                    }
                ],
            )
            cache = GuideCache(
                base_url="http://tvheadend.test:9981",
                username="viewer",
                password="secret",
                cache_path=path,
                opener=opener,
            )
            cache.refresh(now=now)

            restored = GuideCache(
                base_url="http://tvheadend.test:9981",
                username="viewer",
                password="secret",
                cache_path=path,
                opener=FakeOpener([], []),
            )

            self.assertEqual(restored.status()["events"], 1)
            self.assertIn(b"Persisted Show", restored.xmltv())


if __name__ == "__main__":
    unittest.main()
