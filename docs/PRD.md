# PRD: AirDrop↔Android Bridge (Mac-relay architecture)

## Why this exists

Direct AirDrop protocol compatibility on Android was tested and confirmed blocked: AirDrop
requires AWDL (a Wi-Fi-layer protocol tied to Apple's own Broadcom Wi-Fi firmware) for actual
discovery/transfer, with Bluetooth only as a wake-up gate — confirmed independently by our own
live hardware test (zero discovery with Bluetooth off) and by a 2026 academic paper doing fresh
analysis of current macOS/iOS (`sharingd`). No AWDL-compatible implementation exists for
non-Broadcom (e.g. Qualcomm, used in the Fold 6) hardware, by anyone. See
`../android-app/docs/` for that investigation's full record — not deleted, kept as reference.

This is a **different architecture**: instead of making the Fold 6 look like an AirDrop peer,
a small agent on a Mac you already own relays between real AirDrop and the Fold 6 over your
own plain LAN connection, using a protocol we fully control. No Apple protocol compatibility,
no reverse engineering, no AWDL/BLE spoofing required anywhere in this design.

## Architecture (one sentence)

Mac receives/sends via real native AirDrop ↔ small Mac agent ↔ our own LAN protocol ↔ Android
app ↔ you.

## Goals

- **G1 Apple→Android:** an Apple device AirDrops a file to your Mac (normal AirDrop, no
  changes). A Mac-side agent detects the new file and pushes it to the Fold 6 over the LAN
  automatically (no further steps on the Mac after the file lands, once paired).
- **G2 Android→Apple:** you share a file from the Fold 6 to the bridge app. It uploads to the
  Mac agent over the LAN. The Mac agent invokes macOS's standard `NSSharingService` AirDrop
  send picker (the normal native UI) so you pick the destination Apple device, same as any
  AirDrop send — this one step stays manual, matching how AirDrop sending always works (the
  sender always picks the destination from a list).
- **G3 Pairing:** one-time setup pairs the Fold 6 and the Mac agent (shared secret, so transfers
  are authenticated — this moves personal files over a network, treat it accordingly).

## Non-goals

- No attempt to make the Fold 6 discoverable as a native AirDrop target. Confirmed blocked —
  not revisited here.
- No support for Apple devices the Mac doesn't already have a real AirDrop relationship with —
  this only bridges *through* a Mac you control, not arbitrary third-party iPhones.
- Not "always on" the way real device-to-device AirDrop is — requires the Mac to be powered on
  and reachable on the same LAN (or a VPN back to it) at transfer time.

## Success criteria
- [x] SC1 (macOS half only - Fold 6 relay not built yet): AirDrop a file from the iPad to the
      Mac; the agent's FSEvents watcher detects it in `~/Downloads` within ~1s, confirmed with
      real hardware 2026-10-19. Remaining: actually relay it on to the Fold 6 (Phase 3).
- [x] SC2 (macOS half only): the Mac's native AirDrop picker opens for a chosen file via the
      agent's status-bar menu, and a real send to the iPad completes successfully, confirmed
      with real hardware 2026-10-19 (after fixing an `NSSharingService` retention bug - see
      `ARCHITECTURE.md`). Remaining: trigger this from an upload coming from the Fold 6, not a
      local file picker (Phase 3).
- [x] Android app installed and run on the real Fold 6 (`SM_F956B`) via `adb`, 2026-10-19: no
      crash, correctly bound its mDNS browser to the device's real Wi-Fi interface (`wlan0`),
      correctly showed "(none found yet)" since the Mac agent doesn't advertise yet (Phase 3
      scope). Confirms the Android skeleton itself is sound on real hardware, not just
      "builds clean" in the abstract.
- [ ] SC3: Pairing survives Mac reboot and Wi-Fi reconnects without re-pairing.
- [ ] SC4: Multiple files / a reasonably large file (≥500MB) transfer correctly end to end.
