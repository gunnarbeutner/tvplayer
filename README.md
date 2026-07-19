# TVPlayer for tvOS

TVPlayer is a focused TVheadend client for Apple TV. It provides an accessible
electronic programme guide and direct live MPEG-TS playback through TVVLCKit,
without requiring Plex or another licensed media-server client.

The application bundle identifier is `de.beutner.TVPlayer`.

## Features

- Channels, Guide, Recordings, and Settings tabs, with Guide selected by default
- TVheadend channels, channel icons, and EPG data loaded directly from the server
- Optional XMLTV guide override; the override URL is empty by default
- High-contrast timeline guide with clear focus styling and programme details
- Background guide refresh and lazy row rendering for responsive tab and focus navigation
- Select opens programme details; Play/Pause starts the selected channel immediately
- VLC-based live MPEG-TS playback using the `pass` stream profile by default
- Pause/resume, catch-up, Go Live, audio-track selection, and subtitle selection
- Live timeline labels use absolute local times
- Player controls hide after five seconds of inactivity
- Select or a directional press reveals hidden controls
- Back/Menu hides visible controls first and exits playback on the following press
- TVheadend password storage in the tvOS Keychain
- A connection indicator in Settings verifies the configured credentials

The Recordings tab is currently a placeholder.

## Requirements

- Xcode with the tvOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An accessible TVheadend server

TVVLCKit 3.7.3 is downloaded by the included installation script and kept under
the git-ignored `.build` directory.

## Generate and build

```sh
bash Scripts/install-vlckit.sh
xcodegen generate
xcodebuild \
  -project TVApp.xcodeproj \
  -scheme TVApp \
  -sdk appletvsimulator \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

`TVApp.xcodeproj` is generated from `project.yml` and is intentionally not
tracked.

## Configure TVheadend

Open Settings in the app and enter:

- Server URL, for example `http://tvheadend.local:9981`
- Username and password
- Stream profile, normally `pass`
- Optional XMLTV URL

The password is written to the Keychain rather than project files or user
defaults. Server settings used during development can also be passed through
process environment variables; they should not be added to tracked files.

## Run in the simulator

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

## Probe a TVheadend server

The probe script checks server information, profiles, channels, and EPG data.
It also prompts for the password without writing it to disk:

```sh
bash Scripts/probe-tvheadend.sh http://tvheadend.local:9981 username
```

## Live-timeshift limitation

The current transport is TVheadend's ticketed HTTP MPEG-TS stream. VLC can
pause the stream and resume behind live, and TVPlayer can catch up or reconnect
at the live edge. Arbitrary backwards seeking is enabled only when VLC reports
the source as seekable. Reliable server-side rewind for a non-seekable live
HTTP stream would require an HTSP transport or a dedicated local DVR buffer.
