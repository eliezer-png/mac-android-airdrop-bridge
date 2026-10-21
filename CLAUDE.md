# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A working, bidirectional file bridge between real Apple AirDrop and an Android phone (Samsung
Galaxy Z Fold 6), via a Mac you already own. **Not** an AirDrop-compatible reimplementation —
that approach was tried and confirmed blocked (see root `../CLAUDE.md` and `../android-app/docs/`
for the full investigation: AirDrop requires AWDL, which doesn't exist on non-Broadcom Wi-Fi
hardware). This project uses zero reverse-engineered Apple protocol: the Mac side only ever
talks to real AirDrop through legitimate public Apple APIs, and the Mac↔Android link is a wire
protocol designed from scratch (`docs/PROTOCOL.md`).

Both directions are implemented and confirmed working end-to-end on real hardware:
- **Mac → phone**: drop a file into the Mac's `~/Downloads` (or AirDrop one to the Mac from
  another Apple device) → it auto-appears in the phone's Downloads with a notification.
- **Phone → Mac**: "Send via Mac" in the Android share sheet, or the Mac's own "⇄" menu bar
  icon → "Send File to Phone…" → file lands in the other side's Downloads with a notification.

Read `docs/PRD.md` (goals/non-goals/success criteria), `docs/ARCHITECTURE.md` (component
breakdown, design history, open questions) and `docs/PROTOCOL.md` (wire format, why it's
shaped the way it is) before changing scope or protocol behavior.

## Commands

### macOS agent (`macos-agent/`, Swift Package Manager)

```
cd macos-agent
./package-app.sh        # builds + wraps the binary as AirBridge.app + ad-hoc codesigns it
open AirBridge.app       # run it
```

**Do not run `.build/debug/MacosAgent` directly** — `UNUserNotificationCenter` requires a real
`.app` bundle with a bundle identifier; without one it doesn't fail quietly, it crashes the
whole process on launch the moment a notification is requested. `package-app.sh` wraps the
built binary in a minimal bundle (`Info.plist` with `LSUIElement` so it's menu-bar-only, no
Dock icon) and ad-hoc signs it (`codesign --sign -`) — also required, since an unsigned bundle
gets its notification authorization silently denied. Re-run `package-app.sh` after any Swift
change; it rebuilds and re-copies the binary into the existing bundle structure.

To restart after a code change: `pkill -f MacosAgent`, re-run `package-app.sh`, `codesign
--force --deep --sign - AirBridge.app`, then `open AirBridge.app` again. Pairing state and the
TLS identity persist across restarts in `~/Library/Application Support/AirBridge/` — no
re-pairing needed. The Android app does **not** auto-reconnect when the Mac agent restarts
(known v1 limitation); force-stop and relaunch it to reconnect.

No automated tests — this is a small, manually-verified-on-real-hardware project.

### Android app (`android-app/`, Gradle)

```
cd android-app
./gradlew assembleDebug    # build a debug APK
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

No Android Studio installed — this Mac has no system Java, Gradle, or Android SDK by default.
All three were installed specifically for this project, not system-wide:
- JDK 21: `/Users/matt/tools/jdk21`
- Gradle 8.10.2: `/Users/matt/tools/gradle-8.10.2`
- Android SDK (platform-tools, platform 35, build-tools 35.0.0): `/Users/matt/tools/android-sdk`

Set these before running Gradle/adb commands in a fresh shell:
```
export JAVA_HOME=/Users/matt/tools/jdk21/Contents/Home
export ANDROID_HOME=/Users/matt/tools/android-sdk
export PATH=$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH
```
`local.properties` (git-ignored) already points `sdk.dir` at the SDK above for Gradle itself;
the exports above are only needed for the `java`/`gradlew`/`adb` invocations themselves.

For wireless debugging (no cable needed day-to-day): `adb tcpip 5555` once over USB, then
`adb connect <phone-ip>:5555`. After that, address every `adb` command at
`-s <phone-ip>:5555` explicitly if multiple devices/sessions are connected.

No automated tests here either — verification has been real share-sheet shares and real
AirDrop sends against the actual Fold 6 + Mac, not emulators.

## Architecture

### macOS agent (`macos-agent/Sources/MacosAgent/`)

- **`main.swift`** — the menu bar app (`AppDelegate`, `.accessory` activation policy, no Dock
  icon). Owns: the "⇄" `NSStatusItem` and its menu, the `DownloadsWatcher` (FSEvents wrapper)
  watching `~/Downloads`, the `NSSharingService(.sendViaAirDrop)` wrapper for genuinely sending
  to another Apple device (a separate feature from the phone bridge — see menu item naming),
  and `UNUserNotificationCenter`-based notifications. Menu item indices in `setUpStatusItem()`
  are load-bearing (`refreshPairingMenuItem()`/`refreshRecentlyDetectedMenu()` index into the
  menu directly) — keep the index comments in sync if you reorder items.
- **`AgentServer.swift`** — the TLS listener (`NWListener` on port 47835) and wire-protocol
  handler. One connection type dispatch (`handleHandshake`) accepts three first-message types:
  `pair_request` (first pairing), `reconnect` (phone's held connection re-establishing after a
  drop), `file_push` (phone→Mac one-shot send). `pairedConnection`/`pairingRecord` are accessed
  from both the FSEvents callback (`.main`) and connection handlers (`.global()`) — all access
  goes through the private `stateQueue` serial queue; don't bypass it when touching this code,
  a prior version had a real data race here that silently killed healthy connections.
- **`TLSIdentity.swift`** — generates/loads the self-signed cert (shells out to `/usr/bin/openssl`
  rather than hand-rolling X.509). The cert **must** have an explicit
  `keyUsage=digitalSignature,keyEncipherment` extension, or the imported Keychain key lands
  without signing capability and TLS 1.3's `CertificateVerify` step fails with
  `CSSMERR_CSP_INVALID_KEYATTR_MASK` — this was a real, hard-to-diagnose bug, not a
  theoretical concern.
- **`PairingState.swift`** — persisted pairing code + issued token (`pairing.json`).

### Android app (`android-app/app/src/main/java/com/airbridge/app/`)

- **`MainActivity.kt`** — pairing UI (Compose) + mDNS discovery display + requests
  `POST_NOTIFICATIONS` on launch (API 33+; without it, notifications **and Toasts** are
  silently dropped on this device — confirmed root cause of an earlier "it's not working"
  report where transfers were actually succeeding). Starts `BridgeConnectionService` on
  successful pairing or on launch if already paired.
- **`BridgeConnectionService.kt`** — foreground Service holding the Mac→phone receive
  connection open. **Guards against starting more than one concurrent connection loop**
  (`connectionJob?.isActive` check in `onStartCommand`) — without this guard, reopening the
  app spawns a second socket whose `reconnect` handshake makes the Mac adopt it, cancelling the
  still-live first connection mid-send. This was a real, observed bug, not defensive
  over-engineering.
- **`ShareReceiverActivity.kt`** — "Send via Mac" share-target entry point (phone→Mac
  direction). Reads the shared content fully into memory (no streaming) and wraps the read in
  try/catch — a shared `content://` URI can legitimately vanish or reject access between the
  share sheet handing it over and the read (deleted file, revoked grant); that must surface as
  a toast, not a crash.
- **`FileSendClient.kt`** / **`PairingClient.kt`** — each opens its **own**, separate,
  short-lived TLS connection (one-shot send, one-shot pairing) rather than reusing
  `BridgeConnectionService`'s held connection — separating these avoids a read/write race on
  one socket; see `docs/PROTOCOL.md` for why.
- **`TofuTrustManager.kt`** / **`BridgeSocketIO.kt`** — trust-on-first-use TLS pinning (pins
  the Mac cert's SHA-256 fingerprint on first successful connection, like an SSH host key) and
  the line-delimited-JSON-header + raw-body framing shared by every connection type.
- **`AirBridgeDiscovery.kt`** — JmDNS-based mDNS browsing for the Mac's `_airbridge._tcp`
  advertisement. Best-effort only: real home routers often block multicast between Wi-Fi
  clients even when unicast TCP works fine, so manual IP entry is the primary pairing path in
  the UI, not a fallback.

### Wire protocol (`docs/PROTOCOL.md`)

Not HTTP — line-delimited JSON header (`\n`-terminated) followed by exactly `bodyLength` raw
body bytes. Message types: `pair_request`/`pair_response`, `reconnect`/`reconnect_ack`,
`file_push`, `ack`, `error`. Only the Mac holds a TLS identity (server role); the phone is
always the TLS client, in two different connection shapes — one long-held (receive loop) and
one-shot-per-send (pairing, phone→Mac sends). Read `docs/PROTOCOL.md` before changing any of
this; it documents several designs that were tried and rejected (shared duplex connection →
real read/write race; both-sides-run-a-listener → needs Android to carry its own TLS identity)
and exactly why the current shape avoids those failure modes.

## Debugging across the Mac/phone boundary

- Mac agent logs: `/usr/bin/log show --last <Nm> --info --predicate 'process == "MacosAgent"
  AND category == "server"' --style compact` (the `--info` flag is required — `.info`-level
  `os.Logger` calls are hidden by default). `category == "general"` covers FSEvents/menu/UI
  events instead of wire-protocol events.
- Android logs: `adb logcat` — grep for `BridgeConnectionService`, `ShareReceiverActivity`, or
  `FATAL EXCEPTION`; a lot of Samsung/system log noise needs filtering out (`WindowManager`,
  `SurfaceFlinger`, `HoneySpace`, `SGM:`, `VRI[` are all irrelevant noise prefixes).
- TLS handshakes on this hardware are occasionally very slow (multi-second `SecKeyCreateSignature`
  delays unrelated to any bug) — don't conclude something is broken from a check made less than
  ~10 seconds after a reconnect attempt.
- FSEvents reliably fires more than once for a single file write/AirDrop-save; `main.swift`
  debounces pushes per-path over a 5-second window. Don't "fix" apparent duplicate detection
  without checking whether the debounce is already handling it.
