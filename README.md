# Sony WH-CH720N

Bar widget for controlling Noise Cancelling and the Equalizer on a Sony
WH-CH720N, the same features the Windows/Android "Sony | Headphones Connect"
app exposes. There is no official Linux SDK for Sony's headphones, so this
talks the reverse-engineered "MDR" protocol directly over a raw Bluetooth
RFCOMM socket.

## Install

```
git clone https://github.com/eddygarcas/omarchy-sony-wh-ch720n.git \
  ~/.config/omarchy/plugins/eduard.sony-wh-ch720n
omarchy-shell shell rescanPlugins
omarchy plugin enable eduard.sony-wh-ch720n
```

Requires Python 3 (already on every Omarchy install) and `bluetoothctl`
(BlueZ, also standard). No other dependencies.

## ✅ Status: working, once the headset is on its classic Bluetooth identity

Previously this README documented the control channel as permanently
blocked — RFCOMM channel 18 (correctly resolved via SDP) refused the
connection outright (`SABM` → `DM`, confirmed via `btmon`). That block
turned out to be a symptom, not a firmware wall: the WH-CH720N was
connected under its **LE Audio identity** (`bluetoothctl info` showed
`Name: LE-WH-CH720N`), which doesn't expose the classic SDP/RFCOMM MDR
control service at all — only the classic BR/EDR identity (`Name:
WH-CH720N`) does.

The LE Audio identity was in use because of an unrelated Linux-side bug: a
local WirePlumber override restricted `bluez5.auto-connect` to A2DP-only
roles, which also affected which Bluetooth identity/profile set the OS
negotiated with the headset. Fixing that (see "Fix Call/Mic Audio" below)
made the headset come up under its classic identity, and the MDR control
channel opened immediately — no missing authentication step, no need for a
packet capture from the official app.

Confirmed against a real WH-CH720N (2026-08-31), once on the classic
identity:

- **Noise Control**: fully working. Reading and setting Off / Noise
  Cancelling / Ambient Sound + Voice Focus all produce real, verified state
  changes on the device.
- **Equalizer — reading**: fully working. The reply layout matches
  libmdr's `mdr_packet_eqebb_ret_param_t` (`inquired_type, preset_id,
  num_levels, levels[]`), except this unit only answers `inquired_type =
  0x00` (not the 0x01/0x02/0x03 values libmdr documents for newer devices —
  an older/undocumented dialect). It has **6 EQ bands**, not 5.
- **Equalizer — Custom band levels**: fully working and verified with a
  real read-modify-readback cycle. Explicit band levels always land as the
  `custom` preset on readback, regardless of which preset ID was sent
  alongside them.
- **Equalizer — named genre presets** (Rock, Jazz, Bass, ...): **not
  confirmed working on this unit**. Selecting `off` (flat/no EQ) works and
  gets acknowledged; selecting e.g. `rock` with no explicit band levels
  gets **no acknowledgment from the device at all** — most likely this
  model's real supported preset list is just Off + Custom, and the other
  15 preset IDs in this plugin (inherited from other Sony models'
  documentation) aren't actually implemented in its firmware. `set-eq`
  verifies the device actually applied a named preset before reporting
  success, so picking an unsupported one now surfaces a clear error instead
  of silently doing nothing.

**RFCOMM concurrency**: this device's control channel only tolerates one
open connection at a time -- a second, concurrent `connect()` fails
immediately with `[Errno 16] Device or resource busy` (confirmed by
opening 4 sockets to the same channel at once: one succeeds, the other
three get `EBUSY` instantly). Since the panel's periodic status poll and
any button action are each a separate `sony_wh_ctl.py` process opening its
own connection, two landing at the same moment used to collide and surface
"Could not reach the headset over Bluetooth" even though the headset was
working fine. Fixed with a cross-process file lock
(`~/.local/state/omarchy-sony-wh-ch720n/rfcomm.lock`) serializing every
RFCOMM open across all `sony_wh_ctl.py` invocations, plus a short (250ms)
cooldown held *before* releasing that lock -- measured 100% failure with a
0s gap between `close()` and the next `connect()`, 100% success at 0.1s;
the kernel keeps the channel reserved briefly after `close()` returns while
it finishes tearing down with the remote device, so the lock has to outlast
that, not just the local socket lifetime. Verified with concurrent test
processes hammering `status`/`set-nc` simultaneously: 12/12 and 9/9 clean
runs after the fix, 2/4 failures before it.

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

## Removal

```
omarchy plugin remove eduard.sony-wh-ch720n
```

This removes the plugin's files and its bar entry. It does not touch your
Bluetooth pairing or any WirePlumber config the "Fix Call/Mic Audio" button
may have edited (that fix is a legitimate system-level correction meant to
outlive the plugin, backed up alongside the edit under
`~/.config/wireplumber/wireplumber.conf.d/*.bak.*`). To fully clean up,
also remove:

```
rm -rf ~/.local/state/omarchy-sony-wh-ch720n
```

## What's implemented

- **Volume**: works normally. This is plain PipeWire/PulseAudio sink
  control (`pactl`), not the Sony proprietary protocol, so it's unaffected
  by the blocker above — every Bluetooth headphone exposes this the same
  way. First tab, shown by default.
- **Noise Control**: fully working (Off / Noise Cancelling / Ambient Sound,
  plus a Voice Focus toggle) — see Status above.
- **Equalizer**: reading and Custom EQ (6-band, -10..+10 dB per band) are
  fully working. The 16 named genre presets are implemented but only `off`
  is confirmed to actually apply on this unit — see Status above.
- **Fix Call/Mic Audio**: a footer button (`fix-mic-profile`) for a common
  symptom on this class of Bluetooth headset — playback works fine but the
  microphone (and often call audio) never shows up in video calls. This
  happens when a WirePlumber override under `~/.config/wireplumber/wireplumber.conf.d/`
  restricts `bluez5.auto-connect` to A2DP roles only, dropping the HFP/HSP
  roles WirePlumber needs to switch the headset into its call profile. The
  fix backs up the offending file, restores the missing roles, and restarts
  WirePlumber. If no such override exists, it reports that nothing needed
  fixing rather than touching anything.

## Permissions & dependencies

- Requires Python 3 and `bluetoothctl` (BlueZ) on `PATH` — both standard on
  any Omarchy install. No other runtime dependencies.
- Talks raw Bluetooth directly: `AF_BLUETOOTH`/`BTPROTO_RFCOMM` sockets for
  the Sony MDR control channel, and an `L2CAP` SDP query to resolve it —
  lower-level than a typical audio plugin, since there's no standard API
  for vendor NC/EQ protocols. Volume/mute instead use plain `pactl`
  (PipeWire/PulseAudio), the same as any other audio widget.
- **Fix Call/Mic Audio** reads `~/.config/wireplumber/wireplumber.conf.d/*.conf`
  and writes only to a file it already found there with a `bluez5.auto-connect`
  override missing the HFP/HSP call-profile roles — never touches a file
  without that exact match, never touches anything under `/etc` or
  `/usr/share`. Every file it touches is re-validated (still the same
  regular file it was scanned as, not a symlink swapped in since) right
  before it's used, backed up EXCLUSIVELY (`<name>.bak.<epoch>.<random>`,
  refusing rather than overwriting if that exact name is somehow already
  taken) before editing, and the whole batch of files is staged and
  atomically committed as one operation — if any single file in the batch
  fails, every file already committed in that same run is rolled back to
  its own backup, so a partial failure never leaves some files fixed and
  others not. Runs `systemctl --user restart wireplumber` afterward, and
  only reports overall success if BOTH the file changes AND that restart
  succeeded. Reports "nothing needed fixing" and changes nothing if no such
  override exists.
- State lives under `~/.local/state/omarchy-sony-wh-ch720n/` (created at
  mode `0700`, self-healed back to it if looser and still owned by you,
  refused outright if it's a symlink or owned by someone else): the
  detected MAC/RFCOMM channel/protocol dialect (`state.json`), written via
  a private temp file that's atomically renamed into place (never a direct
  in-place write), and a lock file (`rfcomm.lock`, opened with `O_NOFOLLOW`
  so a planted symlink at that exact path is refused rather than followed)
  used only to serialize concurrent RFCOMM opens against itself — never
  touched by any other process.
- No network access at all.
- The Bluetooth frame reader and every subprocess call (`bluetoothctl`,
  `pactl`, `systemctl`) are byte-capped while ingesting, not just
  afterward — a misbehaving or hostile producer (including, for
  `bluetoothctl`, a nearby device's own crafted advertised name) can't grow
  this process's memory past a small fixed limit. The device name (the one
  piece of this plugin's data that's genuinely attacker-influenceable) is
  also length-capped and stripped of control characters before it's ever
  returned, and every dynamic `Text` item in the panel is pinned to
  `Text.PlainText` so it can't be misread as rich text either.
- Like every Quickshell plugin, `Panel.qml` runs unsandboxed inside the
  shared `omarchy-shell` process — review it before installing.

## Files

- `sony_wh_ctl.py` — volume control (`pactl`), Sony MDR protocol
  implementation (frame codec, RFCOMM transport, SDP channel resolution,
  channel/dialect detection, NC/EQ get & set), the WirePlumber call/mic
  profile fix, and CLI (`status`, `detect`, `set-volume`, `toggle-mute`,
  `set-nc`, `set-eq`, `forget`, `fix-mic-profile`).
- `Panel.qml` / `Model.js` — bar icon + popup UI, following the same
  Process-per-action pattern as other Omarchy device-control plugins.

## Credits

Protocol details reverse-engineered by the community, not Sony:

- https://github.com/AndreasOlofsson/mdr-protocol (command ID tables)
- https://github.com/AndreasOlofsson/libmdr (NC/EQ payload structs, GPL-3.0 — consulted as reference only, no code copied)
- https://github.com/Leonard013/sony-ult-ctl (MIT — working Python frame codec this plugin's codec is based on)

Inspired by GM's [AirPods](https://github.com/thisisgm/omarchy-pods) plugin
(`io.github.thisisgm.omapods`) — the first Omarchy bar widget to bring
Bluetooth headphone listening-mode controls (ANC, ambient, ear detection)
into the shell for AirPods. This plugin follows the same idea for Sony's
WH-CH720N, over the very different MDR protocol Sony's own headsets speak
instead of Apple's.
