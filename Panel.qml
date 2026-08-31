import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "eduard.sony-wh-ch720n"
  ipcTarget: "eduard.sony-wh-ch720n"
  manageIpc: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var status: ({
    detected: false,
    bt_connected: false,
    connected: false,
    name: "Sony WH-CH720N",
    battery: null,
    volume: null,
    nc: { mode: "off", voice_focus: false },
    eq: { preset: "off", bands: [0, 0, 0, 0, 0, 0] },
    error: null
  })

  property string activeTab: "volume" // "volume" | "noise" | "eq"
  property bool isDetecting: false
  property bool isFixingMic: false
  property string lastActionNote: ""
  property string pendingNcMode: ""

  onStatusChanged: {
    // Keep the spinner up until the readback actually confirms the new
    // mode, not just until the set-nc call returns -- the RFCOMM round
    // trip means "success" and "status reflects it" land at different times.
    if (root.pendingNcMode && root.status.nc && root.status.nc.mode === root.pendingNcMode) {
      root.pendingNcMode = ""
    }
  }

  Timer {
    id: pendingNcTimeoutTimer
    interval: 6000
    onTriggered: root.pendingNcMode = ""
  }

  function scriptPath() {
    return Qt.resolvedUrl("sony_wh_ctl.py").toString().replace(/^file:\/\//, "")
  }

  function fetchStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function updateVolumeOptimistic(patch) {
    // PanelSlider snaps its knob back to the bound `value` the instant you
    // release it (see its onReleased), before our async pactl call resolves
    // -- update local state immediately so that binding already matches
    // the target, instead of visibly snapping back then forward once the
    // real status refresh lands (which is also slow here since it re-queries
    // NC/EQ over Bluetooth even though volume/mute never touch RFCOMM).
    var current = root.status.volume || {percent: 0, muted: false}
    var next = Object.assign({}, root.status)
    next.volume = Object.assign({}, current, patch)
    root.status = next
  }

  function setVolume(percent) {
    var rounded = Math.round(percent)
    updateVolumeOptimistic({percent: rounded})
    volumeProc.command = ["python3", root.scriptPath(), "set-volume", "--percent", String(rounded)]
    if (!volumeProc.running) volumeProc.running = true
  }

  function toggleMute() {
    updateVolumeOptimistic({muted: !(root.status.volume && root.status.volume.muted)})
    if (!muteProc.running) muteProc.running = true
  }

  function setNcMode(mode) {
    var voiceFocus = root.status.nc ? root.status.nc.voice_focus : false
    var args = [Quickshell.env("PYTHON") || "python3", root.scriptPath(), "set-nc", "--mode", mode]
    if (voiceFocus) args.push("--voice-focus")
    ncProc.command = args
    root.pendingNcMode = mode
    pendingNcTimeoutTimer.restart()
    if (!ncProc.running) ncProc.running = true
  }

  function toggleVoiceFocus() {
    var mode = root.status.nc ? root.status.nc.mode : "off"
    var nextFocus = !(root.status.nc && root.status.nc.voice_focus)
    var args = ["python3", root.scriptPath(), "set-nc", "--mode", mode]
    if (nextFocus) args.push("--voice-focus")
    ncProc.command = args
    if (!ncProc.running) ncProc.running = true
  }

  function setEqPreset(preset) {
    eqProc.command = ["python3", root.scriptPath(), "set-eq", "--preset", preset]
    if (!eqProc.running) eqProc.running = true
  }

  function setEqBands(bands) {
    eqProc.command = ["python3", root.scriptPath(), "set-eq", "--preset", "custom", "--bands", bands.join(",")]
    if (!eqProc.running) eqProc.running = true
  }

  function detectDevice() {
    root.isDetecting = true
    if (!detectProc.running) detectProc.running = true
  }

  function forgetDevice() {
    if (!forgetProc.running) forgetProc.running = true
  }

  function fixMicProfile() {
    root.isFixingMic = true
    if (!fixMicProc.running) fixMicProc.running = true
  }

  Timer {
    interval: 6000
    running: true
    repeat: true
    onTriggered: root.fetchStatus()
  }

  IpcHandler {
    enabled: true
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  Process {
    id: statusProc
    running: true
    command: ["python3", root.scriptPath(), "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.status = JSON.parse(text || "{}")
        } catch (e) {
          // transient parse error; keep last known status
        }
      }
    }
  }

  Process {
    id: volumeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.fetchStatus()
    }
  }

  Process {
    id: muteProc
    command: ["python3", root.scriptPath(), "toggle-mute"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.fetchStatus()
    }
  }

  Process {
    id: ncProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var ok = false
        try { ok = JSON.parse(text || "{}").success } catch (e) {}
        root.lastActionNote = ok ? "Saved" : "Error"
        clearNoteTimer.restart()
        if (!ok) { root.pendingNcMode = ""; pendingNcTimeoutTimer.stop() }
        root.fetchStatus()
      }
    }
  }

  Process {
    id: eqProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var ok = false
        try { ok = JSON.parse(text || "{}").success } catch (e) {}
        root.lastActionNote = ok ? "Saved" : "Error"
        clearNoteTimer.restart()
        root.fetchStatus()
      }
    }
  }

  Process {
    id: detectProc
    command: ["python3", root.scriptPath(), "detect"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.isDetecting = false
        var ok = false
        try { ok = JSON.parse(text || "{}").success } catch (e) {}
        root.lastActionNote = ok ? "Detected" : "Not found"
        clearNoteTimer.restart()
        root.fetchStatus()
      }
    }
  }

  Process {
    id: forgetProc
    command: ["python3", root.scriptPath(), "forget"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.fetchStatus()
    }
  }

  Process {
    id: fixMicProc
    command: ["python3", root.scriptPath(), "fix-mic-profile"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.isFixingMic = false
        var result = {}
        try { result = JSON.parse(text || "{}") } catch (e) {}
        if (!result.success) root.lastActionNote = "Error"
        else if (result.action === "fixed") root.lastActionNote = "Mic profile fixed"
        else root.lastActionNote = "No fix needed"
        clearNoteTimer.restart()
      }
    }
  }

  Timer {
    id: clearNoteTimer
    interval: 2000
    onTriggered: root.lastActionNote = ""
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰋍"
    tooltipText: Model.getTooltipText(root.status)
    active: !!(root.status && root.status.nc && root.status.nc.mode !== "off")
    onPressed: function(buttonCode) { root.toggle() }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    contentWidth: Style.space(380)
    contentHeight: Style.space(560)

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.space(12)

      // Header
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(14)

        Text {
          text: "󰋍"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.space(32)
          Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          spacing: Style.space(2)

          Text {
            text: root.status.name || "Sony WH-CH720N"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            text: {
              if (!root.status.bt_connected) return "Not connected"
              if (root.status.connected) return "Control active" + Model.formatBattery(root.status.battery)
              return "Bluetooth connected" + Model.formatBattery(root.status.battery)
            }
            textFormat: Text.PlainText
            color: root.status.bt_connected ? Color.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            Layout.fillWidth: true
          }
        }
      }

      // Error / hint banner
      Text {
        visible: !!root.status.error
        Layout.fillWidth: true
        text: root.status.error || ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      PanelSeparator { Layout.fillWidth: true }

      // Tabs
      BorderSurface {
        Layout.fillWidth: true
        implicitHeight: Style.space(36)
        radius: Style.space(14)
        color: Style.normalFillFor(root.foreground, root.accent)

        RowLayout {
          anchors.fill: parent
          spacing: Style.space(2)

          Repeater {
            model: [
              { key: "volume", label: "Volume" },
              { key: "noise", label: "Noise Control" },
              { key: "eq", label: "Equalizer" }
            ]

            delegate: BorderSurface {
              required property var modelData
              Layout.fillWidth: true
              Layout.fillHeight: true
              radius: Style.space(14)
              color: root.activeTab === modelData.key ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"

              Text {
                anchors.centerIn: parent
                text: modelData.label
                color: root.activeTab === modelData.key ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.activeTab === modelData.key
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.activeTab = modelData.key
              }
            }
          }
        }
      }

      PanelSeparator { Layout.fillWidth: true }

      // Tab content
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

        // TAB: Volume
        ColumnLayout {
          anchors.fill: parent
          visible: root.activeTab === "volume"
          spacing: Style.space(14)

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            RowLayout {
              Layout.fillWidth: true
              Text {
                text: "Volume"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
              Item { Layout.fillWidth: true }
              Text {
                text: root.status.volume ? Math.round(root.status.volume.percent) + "%" : "--"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Text { text: "🔈"; font.pixelSize: Style.font.body; Layout.alignment: Qt.AlignVCenter }

              PanelSlider {
                Layout.fillWidth: true
                bar: root.bar
                minimum: 0
                maximum: 100
                step: 1
                integer: true
                value: root.status.volume ? root.status.volume.percent : 0
                onReleased: function(v) { root.setVolume(v) }
              }

              Text { text: "🔊"; font.pixelSize: Style.font.body; Layout.alignment: Qt.AlignVCenter }
            }
          }

          Toggle {
            Layout.fillWidth: true
            label: "Mute"
            description: "Silence the headphones without changing volume level"
            checked: !!(root.status.volume && root.status.volume.muted)
            onClicked: root.toggleMute()
          }

          Text {
            visible: !root.status.volume
            Layout.fillWidth: true
            text: "No active audio sink for this headset yet -- play something or check it's the selected output device."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Item { Layout.fillHeight: true }
        }

        // TAB: Noise Control
        ColumnLayout {
          anchors.fill: parent
          visible: root.activeTab === "noise"
          spacing: Style.space(10)

          Repeater {
            model: Model.ncModeOptions()

            delegate: BorderSurface {
              Layout.fillWidth: true
              implicitHeight: Style.space(56)
              radius: Style.space(14)
              readonly property bool pending: modelData.value === root.pendingNcMode
              readonly property bool selected: !!(root.status.nc && root.status.nc.mode === modelData.value) || pending
              color: selected ? Style.selectedFillFor(root.foreground, root.accent) : Style.normalFillFor(root.foreground, root.accent)
              borderSpec: Border.controlSpec(selected ? "selected" : "normal", root.foreground, root.accent)

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(10)

                Text {
                  id: ncTileIcon
                  text: pending ? "󰑐" : modelData.icon
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  horizontalAlignment: Text.AlignHCenter
                  Layout.preferredWidth: Style.space(28)

                  RotationAnimation {
                    target: ncTileIcon
                    property: "rotation"
                    from: 0
                    to: 360
                    duration: 900
                    loops: Animation.Infinite
                    running: pending
                    onRunningChanged: if (!running) ncTileIcon.rotation = 0
                  }
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 2
                  Text {
                    text: modelData.label
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    text: modelData.hint
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(9)
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setNcMode(modelData.value)
              }
            }
          }

          Toggle {
            Layout.fillWidth: true
            label: "Voice Focus"
            description: "Prioritize voices while noise control is active"
            checked: root.status.nc ? root.status.nc.voice_focus : false
            onClicked: root.toggleVoiceFocus()
          }

          Item { Layout.fillHeight: true }
        }

        // TAB: Equalizer
        ColumnLayout {
          anchors.fill: parent
          visible: root.activeTab === "eq"
          spacing: Style.space(10)

          Dropdown {
            Layout.fillWidth: true
            label: "Preset"
            value: root.status.eq ? root.status.eq.preset : "off"
            options: Model.eqPresetOptions()
            onChanged: function(val) { root.setEqPreset(val) }
          }

          ColumnLayout {
            Layout.fillWidth: true
            visible: !!(root.status.eq && root.status.eq.preset === "custom")
            spacing: Style.space(8)

            Text {
              text: "Custom Bands (dB)"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Repeater {
              model: Model.bandLabels()

              delegate: RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)
                required property int index
                required property string modelData

                Text {
                  text: modelData
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  Layout.preferredWidth: Style.space(70)
                }

                PanelSlider {
                  Layout.fillWidth: true
                  bar: root.bar
                  minimum: -10
                  maximum: 10
                  step: 1
                  integer: true
                  value: (root.status.eq && root.status.eq.bands && root.status.eq.bands[index] !== undefined) ? root.status.eq.bands[index] : 0
                  onReleased: function(v) {
                    var bands = (root.status.eq && root.status.eq.bands) ? root.status.eq.bands.slice() : [0, 0, 0, 0, 0, 0]
                    bands[index] = Math.round(v)
                    root.setEqBands(bands)
                  }
                }

                Text {
                  text: Math.round((root.status.eq && root.status.eq.bands && root.status.eq.bands[index] !== undefined) ? root.status.eq.bands[index] : 0)
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.preferredWidth: Style.space(24)
                }
              }
            }
          }

          Item { Layout.fillHeight: true }
        }
      }

      PanelSeparator { Layout.fillWidth: true }

      // Footer
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        BorderSurface {
          implicitHeight: Style.space(28)
          implicitWidth: Style.space(140)
          radius: Style.space(14)
          color: detectHover.hovered ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
          Layout.alignment: Qt.AlignVCenter

          RowLayout {
            anchors.centerIn: parent
            spacing: 4
            Text {
              id: detectIcon
              text: root.isDetecting ? "󰑐" : "󰂯"
              color: root.foreground
              font.family: root.fontFamily
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(16)

              RotationAnimation {
                target: detectIcon
                property: "rotation"
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
                running: root.isDetecting
                onRunningChanged: if (!running) detectIcon.rotation = 0
              }
            }
            Text {
              text: root.isDetecting ? "Detecting…" : "Detect Device"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: detectHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.detectDevice()
          }
        }

        BorderSurface {
          implicitHeight: Style.space(28)
          implicitWidth: Style.space(160)
          radius: Style.space(14)
          color: fixMicHover.hovered ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"
          borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
          Layout.alignment: Qt.AlignVCenter

          RowLayout {
            anchors.centerIn: parent
            spacing: 4
            Text {
              id: fixMicIcon
              text: root.isFixingMic ? "󰑐" : "🎤"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(16)

              RotationAnimation {
                target: fixMicIcon
                property: "rotation"
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
                running: root.isFixingMic
                onRunningChanged: if (!running) fixMicIcon.rotation = 0
              }
            }
            Text {
              text: root.isFixingMic ? "Fixing…" : "Fix Call/Mic Audio"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: fixMicHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.fixMicProfile()
          }
        }

        Item { Layout.fillWidth: true }
      }

      // On its own row (not sharing space with the fixed-width footer
      // buttons above) so it never overflows and never changes their
      // layout when it appears/disappears -- Text reserves its line
      // height even when empty, so this row's height is stable too.
      Text {
        Layout.fillWidth: true
        text: root.lastActionNote ? "✓ " + root.lastActionNote : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
      }

      Text {
        Layout.fillWidth: true
        text: "\"Fix Call/Mic Audio\" repairs a WirePlumber config that lets sound play but blocks the headset's mic in calls (Meet, Zoom, ...)."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.space(9)
        wrapMode: Text.WordWrap
      }
    }
  }
}
