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
    connected: false,
    name: "Sony WH-CH720N",
    battery: null,
    nc: { mode: "off", voice_focus: false },
    eq: { preset: "off", bands: [0, 0, 0, 0, 0] },
    error: null
  })

  property string activeTab: "noise" // "noise" | "eq"
  property bool isDetecting: false
  property string lastActionNote: ""

  function scriptPath() {
    return Qt.resolvedUrl("sony_wh_ctl.py").toString().replace(/^file:\/\//, "")
  }

  function fetchStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function setNcMode(mode) {
    var voiceFocus = root.status.nc ? root.status.nc.voice_focus : false
    var args = [Quickshell.env("PYTHON") || "python3", root.scriptPath(), "set-nc", "--mode", mode]
    if (voiceFocus) args.push("--voice-focus")
    ncProc.command = args
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
    id: ncProc
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

  Timer {
    id: clearNoteTimer
    interval: 2000
    onTriggered: root.lastActionNote = ""
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰋋"
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
          text: "󰋋"
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
              if (!root.status.detected) return "Not detected"
              if (!root.status.connected) return "Not connected"
              return "Connected" + Model.formatBattery(root.status.battery)
            }
            textFormat: Text.PlainText
            color: root.status.connected ? Color.accent : root.dim
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

          BorderSurface {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Style.space(14)
            color: root.activeTab === "noise" ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"

            Text {
              anchors.centerIn: parent
              text: "Noise Control"
              color: root.activeTab === "noise" ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: root.activeTab === "noise"
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activeTab = "noise"
            }
          }

          BorderSurface {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Style.space(14)
            color: root.activeTab === "eq" ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"

            Text {
              anchors.centerIn: parent
              text: "Equalizer"
              color: root.activeTab === "eq" ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: root.activeTab === "eq"
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.activeTab = "eq"
            }
          }
        }
      }

      PanelSeparator { Layout.fillWidth: true }

      // Tab content
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

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
              readonly property bool selected: !!(root.status.nc && root.status.nc.mode === modelData.value)
              color: selected ? Style.selectedFillFor(root.foreground, root.accent) : Style.normalFillFor(root.foreground, root.accent)
              borderSpec: Border.controlSpec(selected ? "selected" : "normal", root.foreground, root.accent)

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(10)

                Text {
                  text: modelData.icon
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
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
                    var bands = (root.status.eq && root.status.eq.bands) ? root.status.eq.bands.slice() : [0, 0, 0, 0, 0]
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
            Text { text: "󰂯"; color: root.foreground; font.family: root.fontFamily }
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

        Item { Layout.fillWidth: true }

        Text {
          text: root.lastActionNote ? "✓ " + root.lastActionNote : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignVCenter
        }
      }
    }
  }
}
