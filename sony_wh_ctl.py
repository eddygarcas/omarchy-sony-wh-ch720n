#!/usr/bin/env python3
"""
Sony WH-CH720N control backend.

Speaks Sony's proprietary "MDR" accessory protocol over a raw Bluetooth
RFCOMM socket -- the same protocol the Windows/Android "Sony | Headphones
Connect" app uses. There is no official Linux SDK for this; the framing,
checksum, and command IDs below come from community reverse-engineering
(AndreasOlofsson/mdr-protocol, AndreasOlofsson/libmdr, Leonard013/sony-ult-ctl).

The WH-CH720N itself has not been directly documented by any of those
projects, so this implementation probes the device rather than assuming a
fixed RFCOMM channel or command dialect: `detect` scans channels and tries
both a newer ("v2", seen on ULT WEAR) and an older ("legacy", seen on
XM3-era headsets) command layout, then caches whichever one answers. If
readings look wrong on your unit, the OFFSETS are the place to adjust --
see README.md.
"""

import argparse
import json
import re
import socket
import subprocess
import sys
import time
import uuid as uuid_mod
from pathlib import Path

STATE_PATH = Path.home() / ".local" / "state" / "omarchy-sony-wh-ch720n" / "state.json"

SOF = 0x3E
EOF = 0x3C
ESC = 0x3D

DT_DATA_MDR = 0x0C
DT_ACK = 0x01

CMD_NC_GET, CMD_NC_RET, CMD_NC_SET = 0x66, 0x67, 0x68
CMD_EQ_GET, CMD_EQ_RET, CMD_EQ_SET = 0x56, 0x57, 0x58

EQ_PRESETS = {
    "off": 0x00, "rock": 0x01, "pop": 0x02, "jazz": 0x03, "dance": 0x04,
    "edm": 0x05, "rnb": 0x06, "acoustic": 0x07,
    "bright": 0x10, "excited": 0x11, "mellow": 0x12, "relaxed": 0x13,
    "vocal": 0x14, "treble": 0x15, "bass": 0x16, "speech": 0x17,
    "custom": 0xA0,
}
EQ_PRESET_NAMES = {v: k for k, v in EQ_PRESETS.items()}
EQ_BAND_COUNT = 5

CHANNEL_SCAN_RANGE = range(1, 31)
DEFAULT_TIMEOUT = 2.0

# Candidate SPP-family service UUIDs Sony accessories advertise for the MDR
# protocol (community reverse-engineering; both seen in the wild). BlueZ
# reports the "v2" one directly in `bluetoothctl info` for the WH-CH720N.
SONY_SERVICE_UUIDS = [
    "956c7b26-d49a-4ba8-b03f-b17d393cb6e2",
    "96cc203e-5068-46ad-b32d-e316f5e069ba",
]
SDP_PSM = 0x0001


# ---------------------------------------------------------------------------
# Frame codec: SOF(1) escaped[ dtype(1) seq(1) len(4 BE) payload(N) csum(1) ] EOF(1)
# Escaping maps a literal SOF/EOF/ESC byte inside the inner stream to
# ESC + (byte & 0xEF), so a raw SOF/EOF only ever appears as a real frame
# boundary and scanning for them byte-by-byte is safe.
# ---------------------------------------------------------------------------

def checksum(data: bytes) -> int:
    return sum(data) & 0xFF


def escape(data: bytes) -> bytes:
    out = bytearray()
    for b in data:
        if b in (SOF, EOF, ESC):
            out.append(ESC)
            out.append(b & 0xEF)
        else:
            out.append(b)
    return bytes(out)


def unescape(data: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        if b == ESC:
            i += 1
            out.append(data[i] | 0x10)
        else:
            out.append(b)
        i += 1
    return bytes(out)


def build_frame(data_type: int, seq: int, payload: bytes) -> bytes:
    inner = bytes([data_type, seq & 0xFF]) + len(payload).to_bytes(4, "big") + payload
    inner += bytes([checksum(inner)])
    return bytes([SOF]) + escape(inner) + bytes([EOF])


def read_frame(sock, timeout=DEFAULT_TIMEOUT):
    sock.settimeout(timeout)
    buf = bytearray()
    started = False
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            chunk = sock.recv(1)
        except socket.timeout:
            return None
        if not chunk:
            return None
        b = chunk[0]
        if not started:
            if b == SOF:
                started = True
            continue
        if b == EOF:
            raw = unescape(bytes(buf))
            if len(raw) < 7:
                return None
            data_type, seq = raw[0], raw[1]
            length = int.from_bytes(raw[2:6], "big")
            if len(raw) < 6 + length + 1:
                return None
            payload = raw[6:6 + length]
            if checksum(raw[:6 + length]) != raw[6 + length]:
                return None
            return {"data_type": data_type, "seq": seq, "payload": payload}
        buf.append(b)
    return None


# ---------------------------------------------------------------------------
# SDP client: looks up the RFCOMM channel a service UUID is actually bound to,
# instead of guessing. Minimal by design -- only the DataElement shapes SDP
# responses for this query actually use.
# ---------------------------------------------------------------------------

def sdp_parse_element(data: bytes, offset: int):
    header = data[offset]
    etype = header >> 3
    size_desc = header & 0x07
    offset += 1
    if etype == 0:
        return {"type": "nil", "value": None}, offset
    if size_desc <= 4:
        length = [1, 2, 4, 8, 16][size_desc]
    else:
        len_bytes = [1, 2, 4][size_desc - 5]
        length = int.from_bytes(data[offset:offset + len_bytes], "big")
        offset += len_bytes
    raw = data[offset:offset + length]
    offset += length
    if etype in (6, 7):  # Sequence, Alternative
        items = []
        pos = 0
        while pos < len(raw):
            item, pos = sdp_parse_element(raw, pos)
            items.append(item)
        return {"type": "seq", "value": items}, offset
    if etype == 3:
        return {"type": "uuid", "value": raw}, offset
    if etype == 1:
        return {"type": "uint", "value": int.from_bytes(raw, "big")}, offset
    if etype == 2:
        return {"type": "int", "value": int.from_bytes(raw, "big", signed=True)}, offset
    return {"type": "raw", "value": raw}, offset


def sdp_wrap_sequence(inner: bytes) -> bytes:
    if len(inner) <= 255:
        return bytes([0x35, len(inner)]) + inner
    return bytes([0x36]) + len(inner).to_bytes(2, "big") + inner


def sdp_build_service_search_attribute_request(uuid128: bytes, attribute_id: int, txn_id: int) -> bytes:
    uuid_elem = bytes([0x1C]) + uuid128
    service_search_pattern = sdp_wrap_sequence(uuid_elem)
    max_attr_bytes = (0xFFFF).to_bytes(2, "big")
    attr_elem = bytes([0x09]) + attribute_id.to_bytes(2, "big")
    attribute_id_list = sdp_wrap_sequence(attr_elem)
    continuation = bytes([0x00])
    params = service_search_pattern + max_attr_bytes + attribute_id_list + continuation
    return bytes([0x06]) + txn_id.to_bytes(2, "big") + len(params).to_bytes(2, "big") + params


def sdp_find_rfcomm_channel(mac: str, service_uuid: str, timeout=5.0):
    """Query the device's SDP server for the RFCOMM channel bound to
    `service_uuid`'s ProtocolDescriptorList (attribute 0x0004). Returns the
    channel number, or None if the service isn't found / SDP is unreachable."""
    uuid128 = uuid_mod.UUID(service_uuid).bytes
    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
    sock.settimeout(timeout)
    try:
        sock.connect((mac, SDP_PSM))
        sock.send(sdp_build_service_search_attribute_request(uuid128, 0x0004, 0x1234))
        resp = sock.recv(65535)
    except OSError:
        return None
    finally:
        try:
            sock.close()
        except Exception:
            pass

    if len(resp) < 7 or resp[0] != 0x07:
        return None
    attr_list_byte_count = int.from_bytes(resp[5:7], "big")
    data = resp[7:7 + attr_list_byte_count]

    try:
        top, _ = sdp_parse_element(data, 0)
    except (IndexError, ValueError):
        return None
    if top["type"] != "seq":
        return None

    for record in top["value"]:
        if record["type"] != "seq":
            continue
        items = record["value"]
        for i in range(0, len(items) - 1, 2):
            if items[i]["type"] == "uint" and items[i]["value"] == 0x0004:
                for proto_seq in items[i + 1].get("value", []):
                    if proto_seq["type"] != "seq" or not proto_seq["value"]:
                        continue
                    first = proto_seq["value"][0]
                    is_rfcomm = first["type"] == "uuid" and first["value"] in (b"\x00\x03", b"\x00\x00\x00\x03")
                    if is_rfcomm and len(proto_seq["value"]) > 1 and proto_seq["value"][1]["type"] == "uint":
                        return proto_seq["value"][1]["value"]
    return None


class SonyLink:
    """One RFCOMM session. Not reused across CLI invocations."""

    def __init__(self, sock):
        self.sock = sock
        self.seq = 0

    def send_command(self, payload: bytes, expect_opcode=None, timeout=DEFAULT_TIMEOUT):
        seq = self.seq
        self.seq ^= 1
        self.sock.sendall(build_frame(DT_DATA_MDR, seq, payload))

        deadline = time.monotonic() + timeout
        reply_payload = None
        while time.monotonic() < deadline:
            frame = read_frame(self.sock, timeout=max(0.1, deadline - time.monotonic()))
            if frame is None:
                break
            if frame["data_type"] == DT_ACK:
                continue
            if frame["data_type"] == DT_DATA_MDR:
                # Every DATA_MDR we receive must be ACKed, regardless of
                # whether it is the reply we are waiting for.
                self.sock.sendall(build_frame(DT_ACK, 1 - frame["seq"], b""))
                p = frame["payload"]
                if expect_opcode is None or (p and p[0] == expect_opcode):
                    reply_payload = p
                    break
        return reply_payload


# ---------------------------------------------------------------------------
# Bluetooth device discovery (bluetoothctl -- no pybluez dependency)
# ---------------------------------------------------------------------------

def run(cmd, timeout=10):
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        return res.returncode, res.stdout, res.stderr
    except Exception as e:
        return 1, "", str(e)


def find_paired_devices():
    """[(mac, name), ...] for every paired Bluetooth device."""
    code, out, _ = run(["bluetoothctl", "devices", "Paired"])
    devices = []
    if code != 0:
        return devices
    for line in out.splitlines():
        m = re.match(r"Device\s+([0-9A-Fa-f:]{17})\s+(.*)", line.strip())
        if m:
            devices.append((m.group(1), m.group(2)))
    return devices


def guess_sony_mac(devices):
    for mac, name in devices:
        if "wh-ch720n" in name.lower():
            return mac
    for mac, name in devices:
        if "sony" in name.lower() or re.search(r"\bwh-\w+\b", name.lower()):
            return mac
    return None


def is_device_connected(mac):
    code, out, _ = run(["bluetoothctl", "info", mac])
    if code != 0:
        return False
    return re.search(r"^\s*Connected:\s*yes", out, re.MULTILINE) is not None


def device_name(mac):
    code, out, _ = run(["bluetoothctl", "info", mac])
    if code != 0:
        return None
    m = re.search(r"^\s*Name:\s*(.+)$", out, re.MULTILINE)
    return m.group(1).strip() if m else None


def battery_percent(mac):
    """Read the headset's own reported battery via BlueZ's Battery1 (org.bluez), if exposed."""
    code, out, _ = run(["bluetoothctl", "info", mac])
    if code != 0:
        return None
    m = re.search(r"Battery Percentage:\s*0x([0-9A-Fa-f]+)", out)
    if m:
        return int(m.group(1), 16)
    return None


# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------

def load_state():
    if not STATE_PATH.exists():
        return {}
    try:
        return json.loads(STATE_PATH.read_text())
    except Exception:
        return {}


def save_state(state):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, indent=2))


# ---------------------------------------------------------------------------
# RFCOMM connection + protocol dialect probing
# ---------------------------------------------------------------------------

def connect_rfcomm(mac, channel, timeout=3.0):
    sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
    sock.settimeout(timeout)
    sock.connect((mac, channel))
    return sock


def probe_scheme(link):
    """Try the v2 (0x17 sub-id) NC dialect first, then the XM3-era legacy one."""
    reply = link.send_command(bytes([CMD_NC_GET, 0x17]), expect_opcode=CMD_NC_RET, timeout=1.2)
    if reply is not None:
        return "v2"
    reply = link.send_command(bytes([CMD_NC_GET, 0x01]), expect_opcode=CMD_NC_RET, timeout=1.2)
    if reply is not None:
        return "legacy"
    return None


def try_channel(mac, channel, timeout=1.2):
    """Open the channel, probe the command dialect, and always close.
    Returns (connected, scheme): connected is True if the RFCOMM socket
    opened at all (even if the protocol probe got no reply), which matters
    for diagnosing a channel SDP points at but that refuses the connection
    outright -- a real failure mode seen on the WH-CH720N."""
    sock = None
    try:
        sock = connect_rfcomm(mac, channel, timeout=timeout)
    except OSError:
        return False, None
    try:
        return True, probe_scheme(SonyLink(sock))
    finally:
        try:
            sock.close()
        except Exception:
            pass


def detect(mac=None):
    devices = find_paired_devices()
    if mac is None:
        mac = guess_sony_mac(devices)
    if mac is None:
        return {"success": False, "error": "No paired Sony headset found. Pair your WH-CH720N in Bluetooth settings first."}

    # SDP knows exactly which channel the Sony service is bound to -- ask it
    # before falling back to a blind scan, which a device can legitimately
    # never answer (some channels accept the RFCOMM connection for an
    # unrelated profile and then just sit there).
    sdp_channel_refused = None
    for service_uuid in SONY_SERVICE_UUIDS:
        channel = sdp_find_rfcomm_channel(mac, service_uuid)
        if channel is None:
            continue
        connected, scheme = try_channel(mac, channel, timeout=2.0)
        if scheme:
            state = load_state()
            state.update({"mac": mac, "channel": channel, "scheme": scheme})
            save_state(state)
            return {"success": True, "mac": mac, "channel": channel, "scheme": scheme, "via": "sdp"}
        if not connected:
            sdp_channel_refused = channel

    for channel in CHANNEL_SCAN_RANGE:
        connected, scheme = try_channel(mac, channel, timeout=1.2)
        if scheme:
            state = load_state()
            state.update({"mac": mac, "channel": channel, "scheme": scheme})
            save_state(state)
            return {"success": True, "mac": mac, "channel": channel, "scheme": scheme, "via": "scan"}

    if sdp_channel_refused is not None:
        return {
            "success": False,
            "mac": mac,
            "error": f"The headset's own SDP database points at RFCOMM channel {sdp_channel_refused} "
                     "for the Sony control service, but connecting to it was refused. The channel is "
                     "registered but not currently accepting connections -- this needs a real packet "
                     "capture of the official Sony app to see what it does differently before this can "
                     "be fixed. See README.md.",
        }

    return {
        "success": False,
        "mac": mac,
        "error": "Paired, but no RFCOMM channel answered the Sony protocol handshake. "
                 "Make sure the headset is powered on and in range, then try again.",
    }


def open_link(state):
    mac = state.get("mac")
    channel = state.get("channel")
    if not mac or not channel:
        return None, "not_detected"
    try:
        sock = connect_rfcomm(mac, channel, timeout=2.5)
    except OSError as e:
        return None, str(e)
    return SonyLink(sock), None


# ---------------------------------------------------------------------------
# Feature queries / commands
# ---------------------------------------------------------------------------

def query_nc(link, scheme):
    if scheme == "v2":
        payload = link.send_command(bytes([CMD_NC_GET, 0x17]), expect_opcode=CMD_NC_RET)
        if payload and len(payload) >= 5:
            enabled, ambient = payload[3], payload[4]
            voice_focus = payload[6] if len(payload) > 6 else 0
            mode = "ambient" if enabled and ambient else ("nc" if enabled else "off")
            return {"mode": mode, "voice_focus": bool(voice_focus)}
    else:
        payload = link.send_command(bytes([CMD_NC_GET, 0x01]), expect_opcode=CMD_NC_RET)
        if payload and len(payload) >= 3:
            effect = payload[2]
            mode = {0: "off", 1: "nc", 2: "ambient"}.get(effect, "off")
            return {"mode": mode, "voice_focus": False}
    return None


def set_nc(link, scheme, mode, voice_focus=False, ambient_level=10):
    enabled = 0 if mode == "off" else 1
    ambient = 1 if mode == "ambient" else 0
    if scheme == "v2":
        payload = bytes([CMD_NC_SET, 0x17, 0x01, enabled, ambient, 0x02, 1 if voice_focus else 0, 0x00])
    else:
        ncasm_effect = {"off": 0x00, "nc": 0x01, "ambient": 0x02}[mode]
        amount = max(0, min(20, ambient_level))
        payload = bytes([CMD_NC_SET, 0x01, ncasm_effect, 0x00, 0x00, 0x01 if mode == "ambient" else 0x00, 0x01, amount])
    link.send_command(payload, expect_opcode=None, timeout=1.5)


def query_eq(link):
    payload = link.send_command(bytes([CMD_EQ_GET, 0x01]), expect_opcode=CMD_EQ_RET)
    if payload and len(payload) >= 3:
        preset_id = payload[1]
        num_levels = payload[2]
        bands = [b - 10 for b in payload[3:3 + num_levels]]
        return {"preset": EQ_PRESET_NAMES.get(preset_id, "custom"), "bands": bands}
    return None


def set_eq(link, preset_name, bands_db=None):
    preset_id = EQ_PRESETS.get(preset_name, 0xA0)
    if bands_db:
        levels = [max(0, min(20, round(b) + 10)) for b in bands_db]
        payload = bytes([CMD_EQ_SET, preset_id, len(levels)]) + bytes(levels)
    else:
        payload = bytes([CMD_EQ_SET, preset_id, 0])
    link.send_command(payload, expect_opcode=None, timeout=1.5)


def notify(title, message):
    run(["notify-send", "-a", "Omarchy", "-i", "audio-headphones", title, message], timeout=3)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def default_status(error=None):
    return {
        "detected": False,
        "mac": None,
        "name": "Sony WH-CH720N",
        "bt_connected": False,
        "connected": False,
        "battery": None,
        "nc": None,
        "eq": None,
        "error": error,
    }


def cmd_status():
    state = load_state()
    mac = state.get("mac")
    devices = find_paired_devices()

    if not mac:
        mac = guess_sony_mac(devices)

    if not mac:
        print(json.dumps(default_status("No paired Sony headset found. Pair your WH-CH720N first.")))
        return

    result = default_status()
    result.update({
        "detected": bool(state.get("channel")),
        "mac": mac,
        "name": device_name(mac) or "Sony WH-CH720N",
        "bt_connected": is_device_connected(mac),
        "battery": battery_percent(mac),
    })

    if not state.get("channel"):
        result["error"] = "Not yet detected. Run Detect Device once."
        print(json.dumps(result))
        return

    link, err = open_link(state)
    if link is None:
        result["error"] = "Could not reach the headset over Bluetooth (is it on and in range?)"
        print(json.dumps(result))
        return

    result["connected"] = True
    try:
        result["nc"] = query_nc(link, state.get("scheme", "v2"))
        result["eq"] = query_eq(link)
    finally:
        try:
            link.sock.close()
        except Exception:
            pass

    print(json.dumps(result))


def cmd_detect(args):
    result = detect(mac=args.mac)
    if result.get("success"):
        notify("Sony WH-CH720N", "Headset detected and ready to control.")
    print(json.dumps(result))


def cmd_forget():
    if STATE_PATH.exists():
        STATE_PATH.unlink()
    print(json.dumps({"success": True}))


def cmd_set_nc(args):
    state = load_state()
    link, err = open_link(state)
    if link is None:
        print(json.dumps({"success": False, "error": "Headset not reachable"}))
        return
    try:
        set_nc(link, state.get("scheme", "v2"), args.mode, voice_focus=args.voice_focus, ambient_level=args.ambient_level)
        notify("Sony WH-CH720N", {"off": "Noise Cancelling off", "nc": "Noise Cancelling on", "ambient": "Ambient Sound on"}[args.mode])
        print(json.dumps({"success": True, "mode": args.mode}))
    except OSError as e:
        print(json.dumps({"success": False, "error": str(e)}))
    finally:
        try:
            link.sock.close()
        except Exception:
            pass


def cmd_set_eq(args):
    state = load_state()
    link, err = open_link(state)
    if link is None:
        print(json.dumps({"success": False, "error": "Headset not reachable"}))
        return
    bands = None
    if args.bands:
        try:
            bands = [int(x) for x in args.bands.split(",")]
        except ValueError:
            print(json.dumps({"success": False, "error": "Bad --bands value"}))
            return
    try:
        set_eq(link, args.preset, bands_db=bands)
        notify("Sony WH-CH720N", f"Equalizer set to {args.preset}")
        print(json.dumps({"success": True, "preset": args.preset, "bands": bands}))
    except OSError as e:
        print(json.dumps({"success": False, "error": str(e)}))
    finally:
        try:
            link.sock.close()
        except Exception:
            pass


def main():
    parser = argparse.ArgumentParser(description="Sony WH-CH720N control helper")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("status")
    sub.add_parser("forget")

    p_detect = sub.add_parser("detect")
    p_detect.add_argument("--mac", default=None)

    p_nc = sub.add_parser("set-nc")
    p_nc.add_argument("--mode", required=True, choices=["off", "nc", "ambient"])
    p_nc.add_argument("--voice-focus", action="store_true")
    p_nc.add_argument("--ambient-level", type=int, default=10)

    p_eq = sub.add_parser("set-eq")
    p_eq.add_argument("--preset", required=True, choices=list(EQ_PRESETS.keys()))
    p_eq.add_argument("--bands", default=None, help="comma separated dB values, e.g. -4,-2,0,2,4")

    args = parser.parse_args()

    if args.command == "status" or not args.command:
        cmd_status()
    elif args.command == "detect":
        cmd_detect(args)
    elif args.command == "forget":
        cmd_forget()
    elif args.command == "set-nc":
        cmd_set_nc(args)
    elif args.command == "set-eq":
        cmd_set_eq(args)


if __name__ == "__main__":
    main()
