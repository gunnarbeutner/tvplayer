# TVPlayer mDNS discovery

This container advertises one TVheadend configuration as a DNS-SD service of
type `_tvplayer._tcp.local.`. TVPlayer uses the first valid service only when it
does not already have a server URL, then stores the password in its Keychain.

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
- `TVPLAYER_XMLTV_URL` (optional)
- `TVPLAYER_MDNS_NAME` (default `TVPlayer TVHeadend`)
- `TVPLAYER_MDNS_ADDRESS` (optional IPv4 override; otherwise the URL host is resolved)

Docker Desktop's host-network support and multicast behavior vary by platform.
For reliable discovery, run this on the TVheadend host or another Linux machine
on the Apple TV's local network.

## Security

DNS-SD TXT records are not encrypted. This service deliberately publishes the
TVheadend username and password because it is a bootstrap mechanism requested
for a trusted home network. Any device able to observe mDNS on that network can
read them. Use a restricted TVheadend account, isolate untrusted Wi-Fi clients,
and do not run this announcer on an untrusted network.
