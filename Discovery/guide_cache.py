from __future__ import annotations

import json
import os
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


class GuideCache:
    CACHE_VERSION = 2

    def __init__(
        self,
        *,
        base_url: str,
        username: str,
        password: str,
        cache_path: str,
        retention_hours: int = 24,
        future_hours: int = 72,
        event_limit: int = 50_000,
        request_timeout: int = 30,
        opener: urllib.request.OpenerDirector | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.cache_path = Path(cache_path)
        self.retention_seconds = retention_hours * 3_600
        self.future_seconds = future_hours * 3_600
        self.event_limit = event_limit
        self.request_timeout = request_timeout
        self._lock = threading.RLock()
        self._channels: dict[str, dict[str, Any]] = {}
        self._events: dict[str, dict[str, Any]] = {}
        self._last_refresh: float | None = None
        self._opener = opener or self._request_opener(username, password)
        self._load()

    def refresh(self, now: float | None = None) -> tuple[int, int]:
        if now is None:
            now = time.time()
        channel_grid = self._fetch_json(
            "/api/channel/grid",
            {"start": "0", "limit": "10000"},
        )
        event_grid = self._fetch_json(
            "/api/epg/events/grid",
            {"start": "0", "limit": str(self.event_limit)},
        )

        fresh_channels = {
            channel["uuid"]: normalized
            for channel in channel_grid.get("entries", [])
            if (normalized := self._normalize_channel(channel)) is not None
        }
        fresh_events = {
            self._event_key(event): normalized
            for event in event_grid.get("entries", [])
            if (normalized := self._normalize_event(event)) is not None
        }

        oldest_stop = int(now - self.retention_seconds)
        newest_start = int(now + self.future_seconds)
        with self._lock:
            self._channels.update(fresh_channels)

            # TVHeadend reassigns an event's id when its EPG grabber
            # re-parses schedule data, even though the broadcast itself
            # hasn't changed. Keying purely by event id then retains both
            # the stale cached entry and its fresh replacement, and clients
            # render two overlapping cards for one programme. Drop a cached
            # event once this refresh already has a fresh event for the
            # same broadcast slot under a different id.
            fresh_broadcast_keys = {
                self._broadcast_key(event) for event in fresh_events.values()
            }
            self._events = {
                key: event
                for key, event in self._events.items()
                if key in fresh_events
                or self._broadcast_key(event) not in fresh_broadcast_keys
            }
            self._events.update(fresh_events)
            self._events = {
                key: event
                for key, event in self._events.items()
                if event["stop"] > oldest_stop and event["start"] < newest_start
            }
            self._last_refresh = now
            self._save_locked()
            return len(self._channels), len(self._events)

    def json_guide(self) -> bytes:
        with self._lock:
            channels = sorted(self._channels.values(), key=lambda item: item["name"].casefold())
            events = sorted(
                self._events.values(),
                key=lambda item: (item["start"], item["channelUuid"], item["title"]),
            )
            payload = {
                "version": 1,
                "lastRefresh": self._last_refresh,
                "channels": channels,
                "events": events,
            }
        return (json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n").encode()

    def status(self) -> dict[str, Any]:
        with self._lock:
            return {
                "channels": len(self._channels),
                "events": len(self._events),
                "last_refresh": self._last_refresh,
            }

    def _request_opener(
        self,
        username: str,
        password: str,
    ) -> urllib.request.OpenerDirector:
        if bool(username) != bool(password):
            raise ValueError("TVHeadend username and password must be provided together")
        if not username:
            return urllib.request.build_opener()
        password_manager = urllib.request.HTTPPasswordMgrWithDefaultRealm()
        password_manager.add_password(None, self.base_url, username, password)
        return urllib.request.build_opener(
            urllib.request.HTTPDigestAuthHandler(password_manager),
            urllib.request.HTTPBasicAuthHandler(password_manager),
        )

    def _fetch_json(self, path: str, query: dict[str, str]) -> dict[str, Any]:
        url = f"{self.base_url}{path}?{urllib.parse.urlencode(query)}"
        request = urllib.request.Request(url, headers={"Accept": "application/json"})
        with self._opener.open(request, timeout=self.request_timeout) as response:
            return json.load(response)

    def _normalize_channel(self, source: dict[str, Any]) -> dict[str, Any] | None:
        identifier = self._text(source.get("uuid"))
        name = self._text(source.get("name"))
        if not identifier or not name:
            return None

        icon = self._text(source.get("icon_public_url"))
        if icon:
            icon = urllib.parse.urljoin(f"{self.base_url}/", icon.lstrip("/"))
        return {
            "id": identifier,
            "name": name,
            "number": source.get("number"),
            "icon": icon,
        }

    def _normalize_event(self, source: dict[str, Any]) -> dict[str, Any] | None:
        channel = self._text(source.get("channelUuid"))
        title = self._text(source.get("title"))
        try:
            start = int(source["start"])
            stop = int(source["stop"])
        except (KeyError, TypeError, ValueError):
            return None
        if not channel or not title or stop <= start:
            return None

        # Retain every native TVheadend field so newer metadata can flow to
        # clients without requiring a cache schema migration. Canonical fields
        # are overlaid to normalize localized string dictionaries and IDs.
        normalized = dict(source)
        normalized.update(
            {
                "eventId": source.get("eventId"),
                "channelUuid": channel,
                "title": title,
                "subtitle": self._text(source.get("subtitle")),
                "summary": self._text(source.get("summary")),
                "description": self._text(source.get("description")),
                "extraText": self._text(source.get("extraText")),
                "episodeUri": self._text(source.get("episodeUri")),
                "serieslinkUri": self._text(source.get("serieslinkUri")),
                "start": start,
                "stop": stop,
            }
        )
        return normalized

    def _event_key(self, source: dict[str, Any]) -> str:
        if source.get("eventId") is not None:
            return f"event-{source['eventId']}"
        return "|".join(
            [
                self._text(source.get("channelUuid")) or "unknown",
                str(source.get("start", "")),
                self._text(source.get("title")) or "untitled",
            ]
        )

    def _broadcast_key(self, event: dict[str, Any]) -> str:
        """Identifies the same broadcast slot independent of TVHeadend's
        event id. Start times for the same broadcast have been observed to
        drift by a few seconds between grabber runs, so this rounds to the
        nearest minute."""
        rounded_start = round(event.get("start", 0) / 60) * 60
        channel = event.get("channelUuid") or "unknown"
        title = (event.get("title") or "").strip().casefold()
        return f"{channel}|{title}|{rounded_start}"

    @staticmethod
    def _text(value: Any) -> str | None:
        if isinstance(value, str):
            stripped = value.strip()
            return stripped or None
        if isinstance(value, dict):
            for candidate in value.values():
                text = GuideCache._text(candidate)
                if text:
                    return text
        return None

    def _load(self) -> None:
        try:
            payload = json.loads(self.cache_path.read_text(encoding="utf-8"))
            if payload.get("version") != self.CACHE_VERSION:
                return
            self._channels = {
                channel["id"]: channel
                for channel in payload.get("channels", [])
                if channel.get("id") and channel.get("name")
            }
            self._events = {
                event["key"]: {key: value for key, value in event.items() if key != "key"}
                for event in payload.get("events", [])
                if event.get("key")
            }
            self._last_refresh = payload.get("last_refresh")
        except (OSError, ValueError, TypeError):
            return

    def _save_locked(self) -> None:
        self.cache_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "version": self.CACHE_VERSION,
            "last_refresh": self._last_refresh,
            "channels": list(self._channels.values()),
            "events": [dict(event, key=key) for key, event in self._events.items()],
        }
        descriptor, temporary_path = tempfile.mkstemp(
            prefix=f".{self.cache_path.name}.",
            dir=self.cache_path.parent,
            text=True,
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(payload, stream, ensure_ascii=False, separators=(",", ":"))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary_path, self.cache_path)
        finally:
            try:
                os.unlink(temporary_path)
            except FileNotFoundError:
                pass
