# Architecture

## Components

```
macos-agent/        Swift menu bar app (or launchd background daemon)
  - FSEvents watcher on ~/Downloads (AirDrop's default save location - VERIFY: is this
    still accurate on current macOS, and is it independently configurable? Check before
    building; if configurable, point the watcher at whatever the user's actual AirDrop
    save location is, not a hardcoded assumption)
  - Lightweight HTTPS client: POSTs newly-detected files to the paired Android device
  - Lightweight HTTPS server: accepts incoming file uploads FROM the Android app, then
    invokes NSSharingService(.sendViaAirDrop) with that file - opens the native AirDrop
    send picker for the user to choose the destination device
  - mDNS: advertises itself under our OWN custom service type (e.g. _airbridge._tcp,
    nothing to do with Apple's _airdrop._tcp - just ordinary Bonjour for our own app to
    find its own peer) for pairing/discovery
  - Pairing: first-run shows a QR code / short code; Android app scans/enters it to
    establish a shared secret, used thereafter for a bearer-token-authenticated,
    self-signed-TLS (trust-on-first-use, like SSH host keys) connection

android-app/         Kotlin app (reuse scaffolding ideas from the superseded direct-compat
  plan's :core:transport module structure where applicable, but this is much simpler -
  no Apple protocol compatibility logic needed anywhere)
  - mDNS browse: finds the Mac agent via _airbridge._tcp (JmDNS, as previously researched)
  - HTTPS server: accepts pushed files from the Mac agent, saves to Downloads/a chosen
    folder, shows a notification
  - HTTPS client: uploads a shared file to the Mac agent (share-target / "Send via Mac"
    entry point from Android's share sheet)
  - Pairing UI: scan/enter the Mac agent's pairing code on first setup
```

## Design notes

- **No Apple protocol compatibility anywhere.** This is our own protocol end to end between
  the Mac agent and the Android app - any reasonable transport works (HTTPS + JSON/multipart
  is simplest, reuses the Ktor/OkHttp/JmDNS library choices already researched for the
  superseded plan, still valid here for entirely different reasons: they're just good
  libraries, not because they match Apple's wire format).
- **Security is now a first-class real concern** (it wasn't as sharply relevant in the
  original Everyone-mode-only compat plan, since no real identity was at stake there): this
  moves personal files over a network via a long-lived paired relationship. Minimum bar:
  TLS (self-signed, pinned after first pairing - trust-on-first-use), a shared secret
  established at pairing time, bearer-token-authenticated requests, and the Mac agent should
  only accept connections from the paired device's identity, not anyone who finds it via mDNS.
- **The `NSSharingService(.sendViaAirDrop)` call is a legitimate, Apple-documented public
  API** (`NSSharingService(named: .sendViaAirDrop)`), not a workaround or hidden API. This is
  the exact mechanism third-party Mac apps use to add "Share via AirDrop" to their own Share
  menus. Confirmed working end-to-end with real hardware 2026-10-19.
  **Real bug hit and fixed:** `perform(withItems:)` is asynchronous - the whole picker UI and
  transfer happen after the call returns. If the `NSSharingService` instance is a local
  variable with nothing else retaining it, ARC deallocates it as soon as the creating
  function's scope exits, silently tearing down the in-flight operation right as the user
  picks a destination device (symptom: picker shows "Waiting...", then fails a second or two
  later - confirmed via `sharingd`'s own log showing our process's XPC connection invalidated
  ~1.5s in, with `transfersInitiated: 0`). **Fix: keep a strong reference to the service for
  the duration of the operation** (a property on the owning object, not a local var), set its
  `delegate` to an `NSSharingServiceDelegate`, and clear the reference in the delegate's
  success/failure callbacks. See `macos-agent/Sources/MacosAgent/main.swift` -
  `AppDelegate.activeSharingService` for the fixed pattern. This is a generic
  `NSSharingService` gotcha, not specific to AirDrop - worth remembering for any future use of
  this API.
- **FSEvents-based Downloads watching is a heuristic**, not a guaranteed signal that something
  arrived specifically via AirDrop (vs. a regular download). Acceptable for v1 (forward
  anything new), refine later if noise becomes a problem (e.g. a dedicated redirected save
  folder, if that turns out to be configurable - research task, not yet confirmed).
- **Mac-liveness is a real UX constraint**, not a bug: Apple→Android only auto-delivers when
  the Mac is on, reachable, and the agent is running. State this plainly to the user in the
  app UI (e.g. a "Mac agent last seen: X minutes ago" indicator) rather than silently failing.

## Phased task list

### Phase 1: macOS agent skeleton (isolated from Android work, can run in parallel)
1. Confirm current macOS AirDrop default save location and configurability (research task,
   quick desk-check).
2. FSEvents watcher on the confirmed save location; log newly-created files for now (no
   networking yet).
3. Prototype `NSSharingService(.sendViaAirDrop)` with a static test file - confirm the native
   picker opens correctly on the current macOS version.
4. Menu bar UI shell (status: paired/not paired, Mac-liveness indicator, pairing-code display).

### Phase 2: Android app skeleton (isolated, parallel to Phase 1) - DONE 2026-10-19
5. Project skeleton (Kotlin, Compose). Done - built and installed on the real Fold 6
   (`SM_F956B`) via `adb`, confirmed no crash and correct Wi-Fi-interface binding.
6. mDNS browse for `_airbridge._tcp` (JmDNS) - browsing side done; advertising side (so the
   Mac agent can find the phone, not just vice versa) is still open, needed for Phase 3.
   **Hardening note:** the local-IPv4 picker (`localIPv4Address()` in
   `AirBridgeDiscovery.kt`) currently takes the first up, non-loopback interface with an
   IPv4 address - correct in the real test (only `wlan0` had one), but should explicitly
   prefer an interface named `wlan0`/check `ConnectivityManager` network capabilities before
   Phase 3, since a device with simultaneous cellular data could otherwise bind to the wrong
   interface.
7. Pairing UI (scan/enter code, store shared secret) - not started, Phase 3 scope.
8. Share-target entry point ("Send via Mac" in Android's share sheet) - registered and
   installed (`ShareReceiverActivity`), placeholder only (shows a toast, doesn't upload yet -
   Phase 3 wires the actual send).

### Phase 3: Wire protocol + transfer (needs both skeletons)
9. Define the actual wire protocol: endpoints, auth header format, multipart/streaming body
   shape for file upload in both directions. Keep it simple - this is ours to design, not
   something to reverse-engineer.
10. TLS: self-signed cert generation + trust-on-first-use pinning on both ends.
11. Mac agent: wire FSEvents detection -> upload to paired Android device.
12. Android: wire incoming upload -> save to folder -> notification.
13. Android: wire share-target -> upload to Mac agent.
14. Mac agent: wire incoming upload -> invoke `NSSharingService(.sendViaAirDrop)`.

### Phase 4: Hardening and polish
15. Reconnection/retry logic for when the Mac is briefly unreachable.
16. Large-file and multi-file transfer testing (SC4).
17. Pairing persistence across reboots (SC3) - verify TLS pin and shared secret survive.
18. Basic transfer history / status UI on both ends.

## Phase 3 status: Mac→Android direction confirmed working end-to-end on real hardware

Full path verified on the real Mac + Fold 6: a file dropped into `~/Downloads` is detected by
FSEvents, pushed over the TLS-pinned, token-authenticated connection, and lands byte-for-byte
in the Fold 6's `MediaStore.Downloads` with a notification.

Found and fixed one real bug in the process, not just a v1 scope gap: the original design
(and `PROTOCOL.md`) assumed `BridgeConnectionService` would keep the *same* socket open that
`PairingClient` used for the initial handshake. In reality `PairingClient` closes its socket
(`.use { }`) right after pairing, and `BridgeConnectionService` opens a fresh connection that
the Mac had no way to recognize - `pushFile()` kept writing to the now-dead pairing socket.
Fixed by adding a `reconnect` message type (carries the stored token) that a fresh connection
sends immediately after the TLS handshake; the Mac accepts it as an alternate to
`pair_request` and adopts that connection as the paired one. This also correctly covers the
"app relaunched, already paired" case, which could never have worked by literally reusing a
socket across process/Service boundaries anyway. See `PROTOCOL.md` for the updated message
flow.

Known minor issue, not yet fixed: FSEvents fired twice for a single file write during testing,
producing a duplicate push (Android correctly dedup'd into `name (1).ext` via MediaStore, so
no data loss, but it's wasted bandwidth/noise). Worth debouncing `DownloadsWatcher` by path
with a short coalescing window in a later pass.

## Open questions to resolve early (Phase 1 step 1 covers the first one)
- Exact current-macOS AirDrop save-location behavior and whether it's configurable.
- ~~Whether `NSSharingService` needs any special entitlement/sandboxing consideration~~
  **RESOLVED (2026-10-19, tested on this machine, macOS 15.7.9):** it needs (1) a real
  `NSWindow` made key+front (an app with *zero* windows gives the picker nowhere to anchor -
  confirmed via log evidence that ShareKit windows were created and animated but never became
  visible without a window), and (2) `app.activate(ignoringOtherApps: true)` with activation
  policy `.regular`. With both, the native AirDrop picker opens correctly and genuinely browses
  for nearby people ("No People Found" when none are in range - confirms it's really
  searching, not stubbed). `.accessory` policy alone, with *no window at all*, was NOT
  sufficient in that first isolated test.
  **Follow-up, confirmed in the real menu-bar app (same day):** a `.accessory`-policy
  status-bar app with no persistent window of its own *does* work too, via the flow
  "status item -> menu -> NSOpenPanel (user picks a file) -> panel closes -> sendViaAirDrop()".
  The open panel's own brief window/key-app moment is apparently sufficient leftover context
  for the picker that follows immediately after - no dummy window needed in the real app, as
  long as there's a genuine user-interaction moment (like a file picker) just before the call.
  See `macos-agent/Sources/MacosAgent/main.swift` for the current working implementation.
- Whether it requires the file to already exist on disk at a stable path (confirmed yes, by
  construction of the test) vs. being able to hand it an in-memory buffer (not tested).
- Whether launchd background-agent vs. a regular menu-bar app login item is the better fit
  for "always running when the Mac is on" (menu-bar app is simpler to debug/trust-prompt via
  normal macOS permission flows; a true background daemon avoids needing to keep a window/
  menu-bar icon around but has its own permission/signing complexities). Given the window-
  anchor requirement just discovered, a menu-bar app (which already has a status-bar presence
  that could potentially serve as anchor context) looks more promising than a windowless
  daemon - revisit once step 4 is underway.
