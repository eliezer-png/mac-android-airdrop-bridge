# AirBridge

Send files between a real Apple device and an Android phone, through a Mac you already own —
with no reverse-engineered Apple protocol anywhere.

```
Apple device ⇄ (real AirDrop) ⇄ Mac agent ⇄ (our own LAN protocol, TLS) ⇄ Android app ⇄ you
```

## Why this exists

A direct, AirDrop-compatible Android client was tried first and confirmed blocked: AirDrop
requires **AWDL**, a Wi-Fi-layer protocol tied to Apple's own Broadcom Wi-Fi firmware, for
actual peer discovery and transfer. No AWDL-compatible implementation exists for non-Broadcom
Wi-Fi hardware (e.g. the Qualcomm chipset in a Samsung Galaxy Z Fold 6) — confirmed by direct
hardware testing and independently by academic analysis of current `sharingd`. That
investigation is kept as a public record in a [separate
repo](https://github.com/eliezer-png/airdrop-reverse-engineering).

Instead of making an Android phone impersonate an AirDrop peer, AirBridge relays through a Mac
you already own:

- **Apple → Android**: AirDrop a file to the Mac like normal. A small menu-bar agent notices
  the new file (via FSEvents on `~/Downloads`) and pushes it to the phone automatically.
- **Android → Apple**: share a file from the phone ("Send via Mac" in the Android share sheet,
  or the Mac's own "⇄" menu → "Send File to Phone…" in reverse) and it lands directly in the
  other side's Downloads folder, with a notification on both platforms.

Both directions are implemented and verified working end-to-end on real hardware (a Mac, an
iPad, and a Samsung Galaxy Z Fold 6) — not just "builds clean."

## What's in here

- **`macos-agent/`** — a Swift Package Manager menu-bar app. Watches `~/Downloads` for new
  files, runs the TLS listener/wire-protocol server, and can trigger a real
  `NSSharingService(.sendViaAirDrop)` send (Apple's own public, documented API — not a
  workaround) for genuinely sending something onward to another Apple device.
- **`android-app/`** — a Kotlin/Jetpack Compose app. Handles pairing, mDNS discovery (with
  manual IP entry as the primary path — many home routers block multicast between Wi-Fi
  clients even when unicast TCP works fine), the long-held receive connection, and the
  share-target send flow.
- **`docs/`** — `PRD.md` (goals, non-goals, success criteria), `ARCHITECTURE.md` (component
  design, decisions made and reconsidered, open questions), `PROTOCOL.md` (the wire format and
  why it's shaped the way it is — including designs that were tried and rejected).

## Building and running

### macOS agent

```sh
cd macos-agent
./package-app.sh   # builds the Swift binary, wraps it in a minimal .app bundle, ad-hoc signs it
open AirBridge.app
```

The agent **must** run from inside a real `.app` bundle, not the raw `swift build` output —
`UNUserNotificationCenter` (used for "file received"/"file sent" banners) does not just fail
quietly without a proper bundle identifier, it crashes the process outright. `package-app.sh`
handles this; re-run it after any Swift change.

First launch will prompt for a notifications permission — allow it, or banners won't show
(the rest of the app still works either way).

### Android app

```sh
cd android-app
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Requires a JDK 17+, Gradle, and the Android SDK — see `CLAUDE.md` for exact versions/paths this
project was built against if you don't already have an Android dev environment set up.

### Pairing

1. Launch the Mac agent — its menu bar shows a 6-digit pairing code and the Mac's LAN IP.
2. Open the Android app, enter that IP and code (mDNS auto-discovery is attempted first, but
   don't rely on it — see note above).
3. Done. The phone holds a long-lived authenticated connection open in the background; AirDrop
   a file to the Mac or share one from the phone at any time afterward.

## Known limitations (v1, by design)

- No auto-reconnect if the connection drops (Mac restart, Wi-Fi blip) — reopen the Android app.
- No resumable/chunked transfer — a dropped connection mid-file means retrying from scratch.
- Requires the Mac to be powered on and reachable on the same LAN at transfer time; this isn't
  "always on" the way direct AirDrop is.

See `docs/PRD.md` for the full, explicit non-goals list and success-criteria checklist.
