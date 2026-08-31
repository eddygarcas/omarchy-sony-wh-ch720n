# Sony WH-CH720N

Bar widget for controlling Noise Cancelling and the Equalizer on a Sony
WH-CH720N, the same features the Windows/Android "Sony | Headphones Connect"
app exposes. There is no official Linux SDK for Sony's headphones, so this
talks the reverse-engineered "MDR" protocol directly over a raw Bluetooth
RFCOMM socket.

## ⚠️ Status: blocked on this unit

Tested against a real WH-CH720N (2026-08-29). Findings:

- The headset advertises the Sony "v2" MDR service UUID
  (`956c7b26-d49a-4ba8-b03f-b17d393cb6e2`) over SDP, confirming it speaks the
  same protocol family as the ULT WEAR.
- SDP correctly resolves that UUID to **RFCOMM channel 18**.
- Opening that channel is **actively refused** — confirmed at the RFCOMM
  frame level via a `btmon` capture: the headset responds to our `SABM`
  (channel-open request) with a `DM` (Disconnected Mode) frame, RFCOMM's
  explicit "no". This is deliberate firmware behavior, not a timeout, a
  missing service, or a bug in this plugin's codec.
- A full sweep of all 30 possible RFCOMM channels found only channel 2
  accepts a connection at all, and it doesn't speak the Sony protocol.

So the control channel is gated behind something the official Sony app does
that a bare RFCOMM open doesn't satisfy — most likely an app-level
authentication step, since classic Bluetooth pairing/encryption is already
in place and doesn't explain the rejection. **This can't be resolved without
a capture of the official app's actual traffic**, which this Linux host
cannot see on its own (its Bluetooth adapter has no visibility into a
phone's separate Bluetooth link to the headset). To move this forward:

1. On an Android phone with the official Sony | Headphones Connect app,
   enable Developer Options → **Bluetooth HCI snoop log**.
2. Connect to the headset and toggle NC / EQ in the app to generate traffic.
3. Pull `/sdcard/btsnoop_hci.log` off the phone and diff it against what
   `sony_wh_ctl.py` sends — look for what precedes the app's successful
   RFCOMM open on channel 18 (or whatever channel it resolves to for that
   phone's Android Bluetooth stack).

The frame codec, SDP client, and command payload construction below are
implemented and exercised against this exact device (SDP resolution and the
channel-scan fallback both work correctly) — only the final "open the
channel" step is blocked, so no rewrite should be needed if the missing
prerequisite step is found.

## Setup

1. Pair the WH-CH720N normally (Omarchy's Bluetooth bar widget, or
   `bluetoothctl pair <MAC>`).
2. Open this widget and click **Detect Device**. It scans RFCOMM channels
   1–30 looking for one that answers the Sony protocol handshake, and caches
   the working channel + protocol dialect (`~/.local/state/omarchy-sony-wh-ch720n/state.json`).
3. Once detected, Noise Control and Equalizer changes apply live over
   Bluetooth. No re-detection needed until the cache is cleared or the
   headset's channel changes (uncommon, but a firmware update could do it —
   just run Detect again).

## What's implemented

- **Volume**: works normally. This is plain PipeWire/PulseAudio sink
  control (`pactl`), not the Sony proprietary protocol, so it's unaffected
  by the blocker above — every Bluetooth headphone exposes this the same
  way. First tab, shown by default.
- **Noise Control**: implemented (Off / Noise Cancelling / Ambient Sound,
  plus a Voice Focus toggle), but **not functional on the WH-CH720N** — see
  Status above.
- **Equalizer**: implemented (16 built-in presets plus a 5-band Custom EQ,
  -10..+10 dB per band), same blocker as Noise Control.
- **Fix Call/Mic Audio**: a footer button (`fix-mic-profile`) for a common
  symptom on this class of Bluetooth headset — playback works fine but the
  microphone (and often call audio) never shows up in video calls. This
  happens when a WirePlumber override under `~/.config/wireplumber/wireplumber.conf.d/`
  restricts `bluez5.auto-connect` to A2DP roles only, dropping the HFP/HSP
  roles WirePlumber needs to switch the headset into its call profile. The
  fix backs up the offending file, restores the missing roles, and restarts
  WirePlumber. If no such override exists, it reports that nothing needed
  fixing rather than touching anything.

## Files

- `sony_wh_ctl.py` — volume control (`pactl`), Sony MDR protocol
  implementation (frame codec, RFCOMM transport, SDP channel resolution,
  channel/dialect detection, NC/EQ get & set), the WirePlumber call/mic
  profile fix, and CLI (`status`, `detect`, `set-volume`, `toggle-mute`,
  `set-nc`, `set-eq`, `forget`, `fix-mic-profile`).
- `Panel.qml` / `Model.js` — bar icon + popup UI, following the same
  Process-per-action pattern as other Omarchy device-control plugins.

## References

Protocol details reverse-engineered by the community, not Sony:

- https://github.com/AndreasOlofsson/mdr-protocol (command ID tables)
- https://github.com/AndreasOlofsson/libmdr (NC/EQ payload structs, GPL-3.0 — consulted as reference only, no code copied)
- https://github.com/Leonard013/sony-ult-ctl (MIT — working Python frame codec this plugin's codec is based on)
