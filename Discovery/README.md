# TVPlayer mDNS discovery

This container advertises one TVheadend configuration as a DNS-SD service of
type `_tvplayer._tcp.local.`. It also retains programme metadata after
TVheadend removes finished EPG events and serves the resulting guide as XMLTV.
TVPlayer uses the first valid service only when it does not already have a
server URL, then stores the password in its Keychain and adopts the cached
XMLTV URL from the service's TXT record.

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
- `TVPLAYER_XMLTV_URL` (optional explicit XMLTV URL; leave empty to advertise the generated cache)
- `TVPLAYER_GUIDE_PORT` (default `49382`)
- `TVPLAYER_GUIDE_BIND` (default `0.0.0.0`)
- `TVPLAYER_GUIDE_REFRESH_SECONDS` (default `60`, minimum `15`)
- `TVPLAYER_GUIDE_RETENTION_HOURS` (default `24`)
- `TVPLAYER_GUIDE_FUTURE_HOURS` (default `72`)
- `TVPLAYER_GUIDE_EVENT_LIMIT` (default `50000`)
- `TVPLAYER_MDNS_NAME` (default `TVPlayer TVHeadend`)
- `TVPLAYER_MDNS_ADDRESS` (optional IPv4 override; otherwise the URL host is resolved)

The generated guide is available at:

- `http://<advertised-address>:49382/guide.xml`
- `http://<advertised-address>:49382/healthz`

Compose uses host networking because mDNS is link-local multicast. Therefore
the guide server binds directly to the host's configured
`TVPLAYER_GUIDE_PORT`; no separate Docker port mapping is required. The
Dockerfile also declares `49382/tcp` with `EXPOSE` for image metadata.

The `guide-cache` named volume preserves observed events across container
rebuilds and restarts. It begins with TVheadend's current and future EPG and
accumulates history as programmes finish. It cannot reconstruct programmes
which expired before the cache was first started.

Docker Desktop's host-network support and multicast behavior vary by platform.
For reliable discovery, run this on the TVheadend host or another Linux machine
on the Apple TV's local network.

## Security

The XMLTV endpoint is intentionally unauthenticated on the local network and
contains programme metadata but no TVheadend credentials. DNS-SD TXT records
are not encrypted. This service deliberately publishes the
TVheadend username and password because it is a bootstrap mechanism requested
for a trusted home network. Any device able to observe mDNS on that network can
read them. Use a restricted TVheadend account, isolate untrusted Wi-Fi clients,
and do not run this announcer on an untrusted network.
