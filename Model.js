// Formatting/label helpers for the Sony WH-CH720N panel.

function ncModeOptions() {
  return [
    { value: "off", label: "Off", icon: "󰟎", hint: "Ambient passthrough, no processing" },
    { value: "nc", label: "Noise Cancelling", icon: "󰂛", hint: "Blocks outside noise" },
    { value: "ambient", label: "Ambient Sound", icon: "󰋋", hint: "Lets outside sound through" }
  ]
}

function eqPresetOptions() {
  return [
    { value: "off", label: "Off" },
    { value: "rock", label: "Rock" },
    { value: "pop", label: "Pop" },
    { value: "jazz", label: "Jazz" },
    { value: "dance", label: "Dance" },
    { value: "edm", label: "EDM" },
    { value: "rnb", label: "R&B" },
    { value: "acoustic", label: "Acoustic" },
    { value: "bright", label: "Bright" },
    { value: "excited", label: "Excited" },
    { value: "mellow", label: "Mellow" },
    { value: "relaxed", label: "Relaxed" },
    { value: "vocal", label: "Vocal" },
    { value: "treble", label: "Treble Boost" },
    { value: "bass", label: "Bass Boost" },
    { value: "speech", label: "Speech" },
    { value: "custom", label: "Custom" }
  ]
}

function bandLabels() {
  return ["Low", "Low-Mid", "Mid", "High-Mid", "High"]
}

function formatBattery(pct) {
  if (pct === null || pct === undefined) return ""
  return " · 🔋 " + Math.round(pct) + "%"
}

function ncLabel(mode) {
  var opts = ncModeOptions()
  for (var i = 0; i < opts.length; i++) if (opts[i].value === mode) return opts[i].label
  return "Unknown"
}

function eqLabel(preset) {
  var opts = eqPresetOptions()
  for (var i = 0; i < opts.length; i++) if (opts[i].value === preset) return opts[i].label
  return preset || "Off"
}

function getTooltipText(status) {
  if (!status || !status.detected) return "Sony WH-CH720N · Not detected"
  if (!status.connected) return "Sony WH-CH720N · Not connected"
  var nc = status.nc ? ncLabel(status.nc.mode) : "Unknown"
  return "Sony WH-CH720N · " + nc + formatBattery(status.battery)
}
