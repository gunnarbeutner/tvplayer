# TVPlayer mDNS discovery

This container advertises one TVheadend configuration as a DNS-SD service of
type `_tvplayer._tcp.local.`. It also retains programme metadata after
TVheadend removes finished EPG events and serves the resulting native metadata
through a compact JSON endpoint. TVPlayer uses the first valid service for
initial configuration, or supplements an existing matching TVheadend
configuration with a missing guide-cache URL. Passwords are stored in the
tvOS Keychain.

## Run

This is intended to run on a Linux host on the same LAN/VLAN as the Apple TV.
mDNS uses link-local multicast, so Compose uses host networking.

```sh
cp .env.example .env
# Edit .env and set the URL, username, and password.
docker compose up -d --build
docker compose logs -f
```

The local `.env` is covered by the repository's git-ignore rules. The compose
file accepts:

- `TVPLAYER_TVH_URL` (required)
- `TVPLAYER_TVH_USERNAME` (required)
- `TVPLAYER_TVH_PASSWORD` (required)
- `TVPLAYER_TVH_PROFILE` (default `pass`)
- `TVPLAYER_TVH_HTSP_PORT` (default `9982`)
- `TVPLAYER_GUIDE_PORT` (default `49382`)
- `TVPLAYER_GUIDE_BIND` (default `0.0.0.0`)
- `TVPLAYER_GUIDE_REFRESH_SECONDS` (default `60`, minimum `15`)
- `TVPLAYER_GUIDE_RETENTION_HOURS` (default `24`)
- `TVPLAYER_GUIDE_FUTURE_HOURS` (default `72`)
- `TVPLAYER_GUIDE_EVENT_LIMIT` (default `50000`)
- `TVPLAYER_MDNS_NAME` (default `TVPlayer TVHeadend`)
- `TVPLAYER_MDNS_ADDRESS` (optional IPv4 override; otherwise the URL host is resolved)

The generated guide is available at:

- `http://<advertised-address>:49382/guide.json`
- `http://<advertised-address>:49382/healthz`

The JSON guide retains the complete native TVheadend event object, including
event and series identifiers, episode metadata, ratings, format flags, and DVR
state when TVheadend provides them. This lets recording actions continue to use
TVheadend event IDs instead of falling back to title/time matching.

Compose uses host networking because mDNS is link-local multicast. Therefore
the guide server binds directly to the host's configured
`TVPLAYER_GUIDE_PORT`; no separate Docker port mapping is required. The
Dockerfile also declares `49382/tcp` with `EXPOSE` for image metadata.

The `guide-cache` named volume preserves observed events across container
rebuilds and restarts. It begins with TVheadend's current and future EPG and
accumulates history as programmes finish. It cannot reconstruct programmes
which expired before the cache was first started. Cache format version 2 is not
compatible with the earlier XMLTV-oriented cache; remove the old volume when
upgrading.

Docker Desktop's host-network support and multicast behavior vary by platform.
For reliable discovery, run this on the TVheadend host or another Linux machine
on the Apple TV's local network.

## Security

The JSON guide endpoint is intentionally unauthenticated on the local network and
contains programme metadata but no TVheadend credentials. DNS-SD TXT records
are not encrypted. This service deliberately publishes the
TVheadend username and password because it is a bootstrap mechanism requested
for a trusted home network. Any device able to observe mDNS on that network can
read them. Use a restricted TVheadend account, isolate untrusted Wi-Fi clients,
and do not run this announcer on an untrusted network.
