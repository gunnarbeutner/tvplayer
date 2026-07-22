# TVPlayer mDNS discovery

This container advertises a TVheadend endpoint as `_tvplayer._tcp.local.` and
its rich guide endpoint as `_tvplayer-guide._tcp.local.`. Both DNS-SD records
carry the same stable ID, allowing either endpoint to run on a different host
while this daemon remains the sole mDNS publisher. It also retains programme
metadata after TVheadend removes finished EPG events and serves the resulting
native metadata through a compact JSON endpoint. TVPlayer uses the first valid
TVheadend service for initial configuration and keeps every advertised server
in its server list.
Advertised settings continue to update automatically until a user edits that
server; automatic updates can later be restored from Settings. Passwords are
stored per server in the device Keychain.

## Run

This is intended to run on a Linux host on the same LAN/VLAN as the Apple TV.
mDNS uses link-local multicast, so Compose uses host networking.

```sh
cp .env.example .env
# Edit .env and set the URL. Add credentials if the server requires them.
docker compose up -d --build
docker compose logs -f
```

The local `.env` is covered by the repository's git-ignore rules. The compose
file accepts:

- `TVPLAYER_TVH_URL` (required)
- `TVPLAYER_TVH_USERNAME` (optional; must be set together with the password)
- `TVPLAYER_TVH_PASSWORD` (optional; must be set together with the username)
- `TVPLAYER_TVH_PROFILE` (default `pass`)
- `TVPLAYER_TVH_HTSP_PORT` (default `9982`)
- `TVPLAYER_GUIDE_PORT` (default `49382`)
- `TVPLAYER_GUIDE_BIND` (default `::`, with dual-stack IPv4/IPv6 enabled)
- `TVPLAYER_GUIDE_REFRESH_SECONDS` (default `60`, minimum `15`)
- `TVPLAYER_GUIDE_RETENTION_HOURS` (default `24`)
- `TVPLAYER_GUIDE_FUTURE_HOURS` (default `72`)
- `TVPLAYER_GUIDE_EVENT_LIMIT` (default `50000`)
- `TVPLAYER_MDNS_NAME` (default `TVPlayer TVHeadend`)
- `TVPLAYER_MDNS_ID` (optional stable identity override; otherwise a UUID is
  generated and retained in the `guide-cache` volume)
- `TVPLAYER_MDNS_HOSTNAME` (optional hostname for the daemon and guide SRV target)
- `TVPLAYER_MDNS_ADDRESS` (optional comma-separated address override; otherwise
  the daemon advertises the IPv4 and IPv6 addresses on the LAN interface used
  to reach TVheadend)

## DNS-SD records

The daemon publishes both records. TVheadend and the guide server do not need
to run their own mDNS responders.

```text
<name>._tvplayer._tcp.local.
  SRV -> <TVheadend host>:<TVheadend HTTP port>
  TXT -> txtvers=1, id=<stable ID>, scheme=<http|https>, path=<HTTP root>,
         [username=..., password=...], profile=..., htsp_port=...

<name>._tvplayer-guide._tcp.local.
  SRV -> <discovery daemon host>:<guide port>
  TXT -> txtvers=1, id=<same stable ID>, scheme=http, path=/guide.json,
         format=tvplayer-json
```

When both endpoints resolve to the same host, they share the daemon's SRV
hostname and A/AAAA records. For a split-host deployment, the TVheadend record
targets the configured TVheadend hostname (or a stable synthetic `.local` name
for an IP literal), while the guide record continues to target the daemon.

The generated guide is available at:

- `http://<advertised-address>:49382/guide.json`
- `http://<advertised-address>:49382/healthz`

The JSON guide retains the complete native TVheadend event object, including
event and series identifiers, episode metadata, ratings, format flags, and DVR
state when TVheadend provides them. This lets recording actions continue to use
TVheadend event IDs instead of falling back to title/time matching.
Channels absent from a successful TVheadend refresh are hidden immediately.
Their retained programme history remains cached until the normal retention
window expires and is exposed again if the same channel UUID reappears.

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
For reliable discovery, run this on a Linux machine on the Apple TV's local
network. It may run on the TVheadend host or a separate host.

## Security

The JSON guide endpoint is intentionally unauthenticated on the local network and
contains programme metadata but no TVheadend credentials. DNS-SD TXT records
are not encrypted. When configured, this service deliberately publishes the
TVheadend username and password because it is a bootstrap mechanism requested
for a trusted home network. Omitting both means anonymous access; partial
credentials are rejected. Any device able to observe mDNS on that network can
read configured credentials. Use a restricted TVheadend account, isolate
untrusted Wi-Fi clients, and do not run this announcer on an untrusted network.
