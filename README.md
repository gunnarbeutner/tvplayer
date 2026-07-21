# TV Player for Apple Platforms

TVPlayer is a native TVheadend client for Apple TV, iPhone, iPad, and Mac. It
provides an accessible electronic programme guide and direct live MPEG-TS
playback through the platform-appropriate VLCKit framework, without requiring
Plex or another licensed media-server client.

The application bundle identifier is `de.beutner.TVPlayer`.

## Features

- Channels, Guide, Recordings, and Settings navigation, with Guide selected by default
- Remote-first focus navigation on Apple TV, touch-first compact layouts on iPhone,
  sidebar and pointer support on iPad, and native split-view, keyboard, and window behavior on Mac
- TVheadend channels, channel icons, and EPG data loaded directly or through the persistent rich guide cache
- Device-local favourite channels pinned above the normal TVHeadend order in Channels and Guide, stored separately per server/account
- No bundled demo guide: Channels and Guide require a configured, reachable TVheadend server
- Optional rich JSON guide cache with an external XMLTV fallback; both URLs are empty by default
- High-contrast timeline guide with clear focus styling and programme details
- Subtle auditory confirmation when focus moves between channels or programmes
- Instant guide restoration from an on-device parsed snapshot, background refresh, and lazy row rendering
- Delayed guide-shaped loading placeholders that progressively reveal channel names and logos on a cold load
- Select opens programme details; Play/Pause starts the selected channel immediately
- VLC-based live MPEG-TS playback using the `pass` stream profile by default
- Native TVheadend timeshift over HTSP for live pause, resume, and seeking
- Automatic ticketed-HTTP live-only fallback when HTSP timeshift is unavailable
- A programme-aware timeline showing current/next titles, absolute times, the playhead, and the available time-shift range
- Up opens the timeline; Down opens Details, Playback, and Technical tabs
- Playback settings include TVheadend stream profiles, audio/subtitle streams, and timing adjustments
- Technical playback details include delivery mode, codecs, resolution, bitrate, timeshift window, dropped pictures, and discontinuities
- Player controls hide after five seconds of inactivity; Back has a short guard after automatic hiding
- Leaving native-timeshift playback pauses on TVheadend and restores focus to the playing channel/current programme
- Opening programme details prewarms an otherwise-empty channel session and advances it to live when playback starts
- Record Once and Record All actions in programme details, with scheduled/recording badges in the guide
- Cached TVheadend DVR views for recordings in progress, upcoming, completed, failed, and Record All rules
- Recording management for cancelling timers, gracefully stopping active recordings, deleting files, and removing Record All rules
- VLC playback of completed and in-progress recordings with seeking, track selection, and technical details
- In-progress recording playback starts at the beginning and exposes Watch Live as a separate action
- TVheadend password storage in the platform Keychain
- First-run TVheadend configuration discovery over `_tvplayer._tcp` Bonjour/mDNS
- An optional always-on discovery container that preserves native EPG metadata and publishes its JSON guide URL over mDNS
- Connection and timeshift badges in Settings verify HTTP credentials and native HTSP availability

## Requirements

- Xcode with the iOS, macOS, and tvOS 26 SDKs
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An accessible TVheadend server
- A TVheadend account with Web Interface, HTSP streaming, Basic recorder, View All, Failed View, and—when managing recordings created by other users—Manage All permissions
- TVheadend timeshift enabled on the server and its HTSP service reachable (port `9982` by default)

TVVLCKit, MobileVLCKit, and VLCKit 3.7.3 are downloaded and checksum-verified by
the included installation script, then kept under the git-ignored `.build`
directory.

## Generate and build

```sh
bash Scripts/install-vlckit.sh
xcodegen generate

# Apple TV
xcodebuild \
  -project TVApp.xcodeproj \
  -scheme TVApp \
  -sdk appletvsimulator \
  -configuration Debug \
  build

# iPhone and iPad
xcodebuild \
  -project TVApp.xcodeproj \
  -scheme TVApp-iOS \
  -sdk iphonesimulator \
  -configuration Debug \
  build

# Mac
xcodebuild \
  -project TVApp.xcodeproj \
  -scheme TVApp-macOS \
  -configuration Debug \
  build
```

For a signing-free compile check of all three application targets, run
`bash Scripts/build-all.sh`. The iOS target includes both iPhone and iPad device
families; iPadOS does not require a separate Xcode target.

Keep each simulator's normal local ad-hoc signing enabled. TV Player's Keychain
access group is supplied through a signing entitlement, so an unsigned build
cannot save discovered or manually entered passwords.

`TVApp.xcodeproj` is generated from `project.yml` and is intentionally not
tracked.

## Configure TVheadend

Open Settings in the app and enter:

- Server URL, for example `http://tvheadend.local:9981`
- Username and password
- Stream profile, normally `pass`
- HTSP port, normally `9982`
- Optional rich guide-cache URL
- Optional external XMLTV fallback URL

The password is written to the app's own Keychain access group rather than
project files or user defaults. Server settings used during development can
also be passed through process environment variables; they should not be added
to tracked files.

TVPlayer continuously browses for `_tvplayer._tcp`, adds discovered servers,
and keeps their settings current until they are manually edited. The optional
[Discovery container](Discovery/README.md) publishes a complete configuration
from environment variables. It also polls TVheadend's EPG, retains expired
events and native event metadata in a persistent volume, and advertises its
JSON endpoint on configurable port `49382` by default. A discovered password is
copied into a per-server Keychain entry, the other fields are saved as app
preferences, and the normal connection test and guide load run automatically.

Because mDNS TXT records are unencrypted and visible to devices on the local
network, use discovery only on a trusted LAN and give its TVheadend account the
minimum permissions it needs.

### Recording permissions

TV Player uses TVheadend's JSON DVR API rather than HTSP. Enable **Basic** in
the account's recorder permissions to list and schedule recordings. **View
All** exposes recordings created by other accounts, **Failed View** exposes
failed entries, and **Manage All** permits cancelling, stopping, or deleting
recordings owned by another account. The account also needs **Web Interface**
for API access and a streaming permission for live and recorded playback.

The app inherits the requesting user's default DVR profile, including its
padding, priority, retention, duplicate handling, and recording format.

## Run on Apple TV Simulator

Build the simulator target first, then use the credential-safe launch helper.
It prompts for the password without writing it to disk:

```sh
bash Scripts/run-simulator.sh http://tvheadend.local:9981 username
```

An optional simulator UDID can be supplied as the third argument.

## Deploy to an Apple TV

Set the development team in `project.yml`, regenerate the Xcode project, and
select the paired Apple TV as the Xcode destination. The application can then
be run from Xcode or installed with `xcrun devicectl` after a signed device
build.

## Run on iPhone, iPad, and Mac

Select the `TVApp-iOS` scheme for either an iPhone or iPad destination. The same
target adapts between bottom-tab, sidebar, compact guide, and regular timeline
layouts. Select `TVApp-macOS` for the native Mac application; it supports normal
window resizing, full-screen playback, menus, pointer input, and keyboard
transport controls. Signing uses the same development team and bundle identity
as Apple TV.

## Probe a TVheadend server

The probe script checks server information, profiles, channels, and EPG data.
It also prompts for the password without writing it to disk:

```sh
bash Scripts/probe-tvheadend.sh http://tvheadend.local:9981 username
```

## Live time-shift

TVPlayer uses TVheadend's native HTSP timeshift as its only timeshift mode.
Pause, relative seeking, the available rewind window, and returning to live are
controlled by TVheadend, so storage limits and retention follow the server's
timeshift configuration. The app does not maintain a second on-device
timeshift file.

Before selecting this mode, TVPlayer checks the server capability and opens an
authenticated HTSP session. If timeshift is disabled, the HTSP service is
unreachable, the account lacks HTSP streaming permission, or a native session
fails, live playback continues through a fresh ticketed HTTP MPEG-TS URL with
pause and seeking disabled. The Settings timeshift badge reports whether native
TVheadend timeshift is ready, active, or unavailable.

## Recording playback

TV Player resolves a fresh ticket-authenticated `dvrfile` URL whenever a
recording starts. Completed recordings use their normal finite seekable
timeline. A recording still in progress exposes only the portion already
written by TVheadend; if VLC reaches that temporary end, the app refreshes the
ticket and reopens the growing file at the previous position. Watched position
is not persisted between app sessions.
