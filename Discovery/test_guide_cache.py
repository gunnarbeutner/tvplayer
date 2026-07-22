from __future__ import annotations

import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

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
    def test_guide_etag_changes_only_when_guide_content_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            now = 100_000
            opener = FakeOpener(
                channels=[{"uuid": "channel-1", "name": "Test"}],
                events=[{
                    "eventId": 1,
                    "channelUuid": "channel-1",
                    "title": "Current Show",
                    "start": now - 300,
                    "stop": now + 1_500,
                }],
            )
            cache = GuideCache(
                base_url="http://tvheadend.test:9981",
                username="",
                password="",
                cache_path=str(Path(directory) / "guide-cache.json"),
                opener=opener,
            )

            cache.refresh(now=now)
            first_body, first_etag = cache.guide_response()
            cache.refresh(now=now + 60)
            second_body, second_etag = cache.guide_response()

            self.assertNotEqual(first_body, second_body)
            self.assertEqual(first_etag, second_etag)

            opener.events[0]["title"] = "Amended Show"
            cache.refresh(now=now + 120)
            _, amended_etag = cache.guide_response()
            self.assertNotEqual(amended_etag, second_etag)

    def test_anonymous_cache_uses_an_unauthenticated_opener(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch(
            "guide_cache.urllib.request.build_opener"
        ) as build_opener:
            opener = object()
            build_opener.return_value = opener

            cache = GuideCache(
                base_url="http://tvheadend.test:9981",
                username="",
                password="",
                cache_path=str(Path(directory) / "guide-cache.json"),
            )

            self.assertIs(cache._opener, opener)
            build_opener.assert_called_once_with()

    def test_cache_rejects_partial_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for username, password in [("viewer", ""), ("", "secret")]:
                with self.subTest(username=username, password=password):
                    with self.assertRaisesRegex(ValueError, "provided together"):
                        GuideCache(
                            base_url="http://tvheadend.test:9981",
                            username=username,
                            password=password,
                            cache_path=str(Path(directory) / "guide-cache.json"),
                        )

    def test_finished_programmes_remain_in_json_until_retention_expires(self) -> None:
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
            document = json.loads(cache.json_guide())

            self.assertEqual(document["channels"][0]["name"], "Test & One")
            self.assertEqual(
                [programme["title"] for programme in document["events"]],
                ["Earlier <Show>", "Current Show"],
            )

            opener.events = [opener.events[1]]
            cache.refresh(now=now + 3_601)
            document = json.loads(cache.json_guide())
            self.assertEqual(
                [programme["title"] for programme in document["events"]],
                ["Current Show"],
            )

    def test_reassigned_event_id_replaces_stale_cached_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "guide-cache.json")
            now = 100_000
            opener = FakeOpener(
                channels=[{"uuid": "channel-1", "name": "Test"}],
                events=[
                    {
                        "eventId": 1,
                        "channelUuid": "channel-1",
                        "title": "Nichts geht mehr",
                        "start": now - 300,
                        "stop": now + 1_500,
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

            # TVHeadend's EPG grabber re-parses schedule data and reassigns
            # a new event id to the same broadcast, with its start drifting
            # by a few seconds.
            opener.events = [
                {
                    "eventId": 2,
                    "channelUuid": "channel-1",
                    "title": "Nichts geht mehr",
                    "start": now - 297,
                    "stop": now + 1_503,
                }
            ]
            cache.refresh(now=now + 60)
            document = json.loads(cache.json_guide())

            self.assertEqual(
                [programme["eventId"] for programme in document["events"]],
                [2],
            )

    def test_large_schedule_amendment_drops_absent_future_event(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            now = 100_000
            opener = FakeOpener(
                channels=[{"uuid": "channel-1", "name": "Test"}],
                events=[
                    {
                        "eventId": 1,
                        "channelUuid": "channel-1",
                        "title": "phoenix vor ort",
                        "start": now + 1_000,
                        "stop": now + 2_800,
                    }
                ],
            )
            cache = GuideCache(
                base_url="http://tvheadend.test:9981",
                username="viewer",
                password="secret",
                cache_path=str(Path(directory) / "guide-cache.json"),
                opener=opener,
            )
            cache.refresh(now=now)

            # The amended event begins 30 minutes earlier, keeps the same
            # end, and receives a new id. The old future slot is absent from
            # TVHeadend's successful refresh and must not survive in cache.
            opener.events = [
                {
                    "eventId": 2,
                    "channelUuid": "channel-1",
                    "title": "phoenix vor ort",
                    "start": now - 800,
                    "stop": now + 2_800,
                }
            ]
            cache.refresh(now=now + 60)
            document = json.loads(cache.json_guide())

            self.assertEqual(
                [programme["eventId"] for programme in document["events"]],
                [2],
            )

    def test_absent_finished_event_remains_as_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            now = 100_000
            opener = FakeOpener(
                channels=[{"uuid": "channel-1", "name": "Test"}],
                events=[
                    {
                        "eventId": 1,
                        "channelUuid": "channel-1",
                        "title": "Finished Show",
                        "start": now - 1_800,
                        "stop": now - 300,
                    }
                ],
            )
            cache = GuideCache(
                base_url="http://tvheadend.test:9981",
                username="viewer",
                password="secret",
                cache_path=str(Path(directory) / "guide-cache.json"),
                opener=opener,
            )
            cache.refresh(now=now)

            opener.events = []
            cache.refresh(now=now + 60)
            document = json.loads(cache.json_guide())

            self.assertEqual(
                [programme["eventId"] for programme in document["events"]],
                [1],
            )

    def test_removed_channel_is_hidden_while_its_history_obeys_retention(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "guide-cache.json"
            now = 100_000
            opener = FakeOpener(
                channels=[{"uuid": "channel-1", "name": "Temporary"}],
                events=[
                    {
                        "eventId": 1,
                        "channelUuid": "channel-1",
                        "title": "Finished Show",
                        "start": now - 1_800,
                        "stop": now - 300,
                    }
                ],
            )
            cache = GuideCache(
                base_url="http://tvheadend.test:9981",
                username="viewer",
                password="secret",
                cache_path=str(path),
                retention_hours=1,
                opener=opener,
            )
            cache.refresh(now=now)

            opener.channels = []
            opener.events = []
            self.assertEqual(cache.refresh(now=now + 60), (0, 0))
            document = json.loads(cache.json_guide())
            self.assertEqual(document["channels"], [])
            self.assertEqual(document["events"], [])

            persisted = json.loads(path.read_text())
            self.assertEqual(
                [channel["id"] for channel in persisted["channels"]],
                ["channel-1"],
            )
            self.assertEqual(
                [event["eventId"] for event in persisted["events"]],
                [1],
            )

            restored = GuideCache(
                base_url="http://tvheadend.test:9981",
                username="viewer",
                password="secret",
                cache_path=str(path),
                retention_hours=1,
                opener=opener,
            )
            document = json.loads(restored.json_guide())
            self.assertEqual(document["channels"], [])
            self.assertEqual(document["events"], [])

            opener.channels = [{"uuid": "channel-1", "name": "Temporary"}]
            restored.refresh(now=now + 120)
            document = json.loads(restored.json_guide())
            self.assertEqual(
                [channel["id"] for channel in document["channels"]],
                ["channel-1"],
            )
            self.assertEqual(
                [event["eventId"] for event in document["events"]],
                [1],
            )

            opener.channels = []
            restored.refresh(now=now + 4_000)
            persisted = json.loads(path.read_text())
            self.assertEqual(persisted["channels"], [])
            self.assertEqual(persisted["events"], [])

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
            self.assertIn(b"Persisted Show", restored.json_guide())

    def test_json_guide_preserves_native_recording_and_episode_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            now = 100_000
            cache = GuideCache(
                base_url="http://tvheadend.test:9981",
                username="viewer",
                password="secret",
                cache_path=str(Path(directory) / "guide-cache.json"),
                opener=FakeOpener(
                    channels=[{"uuid": "channel-1", "name": "Test", "number": 7}],
                    events=[
                        {
                            "eventId": 42,
                            "channelUuid": "channel-1",
                            "title": {"ger": "Beispiel"},
                            "subtitle": "Folge zwei",
                            "summary": "Zusammenfassung",
                            "start": now - 300,
                            "stop": now + 1_500,
                            "episodeUri": "crid://example/episode/2",
                            "serieslinkUri": "crid://example/series/1",
                            "seasonNumber": 3,
                            "episodeNumber": 2,
                            "genre": [16, 17],
                            "ageRating": 12,
                            "ratingLabel": "FSK 12",
                            "hd": 1,
                            "subtitled": 1,
                            "dvrUuid": "recording-uuid",
                            "dvrState": "scheduled",
                            "image": "http://images.example/show.jpg",
                            "futureMetadata": {"value": "retained"},
                        }
                    ],
                ),
            )

            cache.refresh(now=now)
            document = json.loads(cache.json_guide())

            self.assertEqual(document["version"], 1)
            self.assertEqual(document["channels"][0]["number"], 7)
            event = document["events"][0]
            self.assertEqual(event["eventId"], 42)
            self.assertEqual(event["title"], "Beispiel")
            self.assertEqual(event["serieslinkUri"], "crid://example/series/1")
            self.assertEqual(event["seasonNumber"], 3)
            self.assertEqual(event["genre"], [16, 17])
            self.assertEqual(event["dvrState"], "scheduled")
            self.assertEqual(event["image"], "http://images.example/show.jpg")
            self.assertEqual(event["futureMetadata"], {"value": "retained"})


if __name__ == "__main__":
    unittest.main()
