# Wire protocol (ours, not Apple's)

Transport: TLS over TCP, port 47835 (arbitrary, not a registered port - fine for a LAN tool).
Self-signed cert generated once per Mac agent install, pinned by the Android app on first
pairing (trust-on-first-use, like an SSH host key) - never validated against a CA, since
there is no CA for a private LAN tool.

Framing: not HTTP. Each message is a single-line JSON header terminated by `\n`, followed by
exactly `bodyLength` raw bytes (0 if no body). Kept deliberately simple - a hand-rolled HTTP
parser would be more code than this for no real benefit here.

```json
{"type": "pair_request", "code": "123456", "listenPort": 47836}
{"type": "pair_response", "ok": true, "token": "<uuid>"}
{"type": "reconnect", "token": "<uuid>"}
{"type": "reconnect_ack", "ok": true}
{"type": "file_push", "token": "<uuid>", "filename": "IMG_1234.HEIC", "bodyLength": 48213}
{"type": "ack", "ok": true}
{"type": "error", "message": "..."}
```

**Final v1 scope decision: one direction only this pass (Mac→Android auto-delivery), to
ship something complete and correct rather than two half-finished directions.** An earlier
draft tried bidirectional messaging over one shared connection (real read/write race between
a background loop and an ad-hoc push awaiting its reply) and then a symmetric
both-sides-run-a-listener redesign (correct, but requires Android to generate and serve its
own TLS identity - real extra scope, likely a Bouncy Castle dependency). Deferred; not yet
implemented. See "Not yet implemented" below.

**What v1 actually does:** only the Mac needs a TLS identity (as the server). Android is
purely a TLS *client*, the entire session:
1. Android connects to the Mac's listener, sends `pair_request` with the code shown on the
   Mac's status-bar menu.
2. Mac validates the code, issues a token, replies `pair_response`. This one-shot pairing
   socket (`PairingClient`) then closes - it only ever exists to exchange the code for a token.
3. **Android's foreground Service (`BridgeConnectionService`) opens its own, separate
   connection** and immediately sends `reconnect` with the stored token. The Mac accepts this
   as an alternate handshake (instead of `pair_request`) and adopts this connection as the
   paired one, replying `reconnect_ack`. This is deliberate, not an oversight: a literal
   "keep the original pairing socket open" design can't actually work, since the Service may
   start well after `PairingClient`'s socket is gone (e.g. the app being relaunched when
   already paired, with no live pairing session to hand a socket off from). A fresh
   `reconnect` handshake handles both "just paired" and "relaunched, already paired"
   identically.
4. Android keeps *this* connection open (surviving backgrounding, since it's a foreground
   Service) and simply reads from it in a loop from then on - it never writes to this
   connection again except `ack` replies.
5. When the Mac's FSEvents watcher detects a new file in `~/Downloads`, it sends a
   `file_push` header + the file's bytes down that same already-open connection. Only the Mac
   ever writes non-reply traffic on this connection, so there is no race: Android's read loop
   is the sole reader, matching "await next message, handle it, reply, loop" in strict
   lock-step with the sole writer.
6. Android receives the `file_push`, saves the file, shows a notification, and replies `ack`
   on the same connection before going back to reading the next message.

## Android → Mac direction (implemented)

`ShareReceiverActivity` ("Send via Mac" in the Android share sheet) reads the shared file
fully into memory, then `FileSendClient` opens its **own, separate, short-lived** connection
to the Mac (reusing the pinned fingerprint and token from pairing) and sends `file_push` +
body, reads one `ack`, closes. This is deliberately not the same connection
`BridgeConnectionService` holds open for receiving - sharing one connection for both
directions would reintroduce the read/write race the original design rejected (see
`ARCHITECTURE.md`). On the Mac, `AgentServer.handleHandshake` accepts `file_push` as a third
valid first-message type (alongside `pair_request`/`reconnect`) on any new connection,
validates the token, and saves the body directly into `~/Downloads` (uniquifying the name on
a collision) - the Mac is the final destination for this direction, by explicit user request,
symmetric with Mac→Android just landing the file in the phone's Downloads with no extra step.
`DownloadsWatcher`'s existing per-path debounce (added for the FSEvents-fires-3x issue) is
reused to suppress the obvious loop this would otherwise cause: saving an Android-pushed file
into the very folder the Mac→Android direction watches would immediately bounce it right back
to the phone it came from. `AgentServer`'s `onFileReceived` callback pre-marks the path in that
debounce dict before the FSEvents watcher can fire for it.

An earlier version of this feature instead handed the received file to
`NSSharingService(.sendViaAirDrop)` to open the native AirDrop picker and forward it onward to
a third Apple device. That's a reasonable feature but not what was actually being asked for
here (Fold 6 ↔ Mac as the two endpoints, not Fold 6 → Mac → some other device) - reverted in
favor of the simpler direct-save behavior. If "forward from Mac via AirDrop" is wanted later,
it fits as an explicit separate action, not something that happens automatically on every
Android→Mac share.

## Not yet implemented (explicit, not forgotten)

- Auto-retry if the Android app's held connection drops mid-session (Mac restart, Wi-Fi blip,
  phone sleep policies killing the socket) - the `reconnect` handshake above means a fresh
  connection attempt (e.g. user reopens the app) recovers cleanly, but v1 does not yet retry
  automatically in the background when the drop happens.

## Pairing

1. Mac agent generates a random 6-digit code at first launch (or on demand via "Re-pair…" in
   the status-bar menu), stored in `~/Library/Application Support/AirBridge/pairing.json`
   alongside the TLS identity.
2. Mac advertises `_airbridge._tcp` via Bonjour with a TXT record: `fp=<cert SHA-256
   fingerprint, hex>`, `pairing=required|paired` (so an already-paired Android app does not
   need to re-show the code-entry screen just because it restarted).
3. Android discovers the agent, connects over TLS (pinning the advertised fingerprint
   immediately - trust-on-first-use happens at the fingerprint-pinning step, before any data
   is exchanged), shows the user a prompt to enter the 6-digit code displayed on the Mac.
4. Android sends `pair_request` with the code. Mac validates it, issues a long-lived random
   token (UUID), and responds `pair_response`. Android stores the token (and the pinned
   fingerprint) in `EncryptedSharedPreferences`.
5. All subsequent `file_push` messages (either direction) include that token. The Mac agent
   rejects any request without a valid token once paired - this is the actual authentication,
   not the one-time code (which only gates the initial pairing step).

## Message types

- `file_push` (either direction): sender streams the header line, then `bodyLength` raw file
  bytes. Receiver responds with `ack` (`ok: true`) once the full body is written to a
  temporary path and (for Android receiving) moved into place / (for Mac receiving) handed to
  `NSSharingService(.sendViaAirDrop)`.
- `error`: either side may send this instead of `ack` if something failed (bad token, disk
  full, etc.) - the connection is closed after.

## Deliberately out of scope for v1

- No resumable/chunked transfer (a dropped connection mid-file means retrying from scratch).
- No concurrent transfers (one `file_push` per TLS connection; a new file opens a new
  connection).
- No re-pairing UI polish beyond "Re-pair…" regenerating the code and invalidating the old
  token.
