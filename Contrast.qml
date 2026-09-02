import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Contrast.js" as Contrast

// Contrast checker overlay, in the spirit of MDS's "Contrast" macOS app:
// pick a foreground and background, get WCAG 2 + APCA verdicts instantly.
//
//   omarchy-shell shell toggle loamstudios.contrast
//
// Keyboard: Esc closes, Tab moves between hex fields, Ctrl+F / Ctrl+B run
// the eyedropper for foreground / background, Shift+X swaps.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool picking: false
  property string pickTarget: "fg"

  property string fgHex: "#000000"
  property string bgHex: "#ffffff"
  property var fgRgb: Contrast.parseHex(fgHex)
  property var bgRgb: Contrast.parseHex(bgHex)
  property var result: Contrast.report(fgRgb, bgRgb)
  property color fgColor: fgHex
  property color bgColor: bgHex

  // Surface tokens shared with the menu so themes style us for free.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color accent: Color.menu.selectedText
  property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int mainWidth: Style.space(560)
  property int drawerWidth: Style.space(300)
  readonly property bool drawerOpen: root.pickerTarget !== ""

  // ---------- shell contract ----------

  readonly property string helperPath: {
    var u = String(Qt.resolvedUrl("scripts/run-capped.sh"))
    return u.indexOf("file://") === 0 ? u.slice(7) : u
  }

  function trustedCommand(deadlineSecs, maxOut, maxErr, tool, args) {
    var cmd = [
      "/usr/bin/timeout", "--kill-after=2s", String(deadlineSecs) + "s",
      "/usr/bin/bash", root.helperPath,
      String(maxOut), String(maxErr), tool
    ]
    for (var i = 0; i < args.length; i++) cmd.push(args[i])
    return cmd
  }

  function stopProc(proc, killTimer) {
    if (killTimer) killTimer.stop()
    if (!proc.running) return
    proc.running = false
    if (killTimer) killTimer.restart()
  }

  function forceKill(proc) {
    if (proc.running) proc.signal(9)
  }

  function stopAllTools() {
    pickSettle.stop()
    pickWatchdog.stop()
    copyWatchdog.stop()
    notifyWatchdog.stop()
    root.stopProc(pickProc, pickKillGrace)
    root.stopProc(copyProc, copyKillGrace)
    root.stopProc(notifyProc, notifyKillGrace)
  }

  function open(payloadJson) {
    var parsed = Contrast.parseOpenPayload(payloadJson)
    if (parsed.ok) {
      if (parsed.fg) setFg(parsed.fg)
      if (parsed.bg) setBg(parsed.bg)
    }
    root.opened = true
    Qt.callLater(function() { fgField.forceActiveFocus(); fgField.selectAll() })
  }

  function close() {
    root.picking = false
    root.stopAllTools()
    root.opened = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "loamstudios.contrast")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---------- state ----------

  function setFg(hex) {
    var c = Contrast.parseHex(hex)
    if (!c) return
    root.fgHex = Contrast.toHex(c)
    root.fgRgb = c
    root.fgColor = root.fgHex
    recompute()
    if (fgField.text.toLowerCase() !== root.fgHex && !fgField.activeFocus) fgField.text = root.fgHex
    if (root.pickerTarget === "fg" && !root.pickerDriving) syncPickerFromColor()
  }

  function setBg(hex) {
    var c = Contrast.parseHex(hex)
    if (!c) return
    root.bgHex = Contrast.toHex(c)
    root.bgRgb = c
    root.bgColor = root.bgHex
    recompute()
    if (bgField.text.toLowerCase() !== root.bgHex && !bgField.activeFocus) bgField.text = root.bgHex
    if (root.pickerTarget === "bg" && !root.pickerDriving) syncPickerFromColor()
  }

  function recompute() {
    root.result = Contrast.report(root.fgRgb, root.bgRgb)
  }

  // Wording follows Contrast's single conformance level per pair.
  readonly property string ratingText: {
    var r = root.result.ratio
    if (r >= 7)   return "Valid for all font sizes and weights"
    if (r >= 4.5) return "Valid for all text · AAA for large text only"
    if (r >= 3)   return "Valid for large text only (18pt+, or 14pt+ bold)"
    return "Not valid for text at any size"
  }

  // Lighten/darken (HSV value) a colour by `amount` (0..1), as Contrast's arrows do.
  function nudge(target, amount) {
    var c = target === "bg" ? root.bgRgb : root.fgRgb
    var hsv = Contrast.rgbToHsv(c)
    var v = Contrast.clamp01(hsv.v + amount)
    var out = Contrast.hsvToRgb(hsv.s > 0.001 ? hsv.h : root.pickH, hsv.s, v)
    var hex = Contrast.toHex(out)
    if (target === "bg") { bgField.text = hex; setBg(hex) } else { fgField.text = hex; setFg(hex) }
  }

  // Which colour the ↑/↓ steppers act on: the focused hex field, else the foreground.
  function nudgeTarget() { return bgField.activeFocus ? "bg" : "fg" }

  function swap() {
    var f = root.fgHex, b = root.bgHex
    fgField.text = b
    bgField.text = f
    setFg(b)
    setBg(f)
  }

  function copyHex(hex) {
    var c = Contrast.parseHex(hex)
    if (!c) return
    var h = Contrast.toHex(c)
    root.stopProc(copyProc, copyKillGrace)
    copyProc.command = root.trustedCommand(
      Contrast.TOOL_DEADLINE_SECS, Contrast.MAX_TOOL_BYTES, Contrast.MAX_TOOL_BYTES,
      "wl-copy", ["--", h]
    )
    copyWatchdog.restart()
    copyProc.running = true
    root.stopProc(notifyProc, notifyKillGrace)
    notifyProc.command = root.trustedCommand(
      Contrast.TOOL_DEADLINE_SECS, Contrast.MAX_TOOL_BYTES, Contrast.MAX_TOOL_BYTES,
      "notify-send", ["-a", "Contrast", "-t", "1500", "Copied " + h]
    )
    notifyWatchdog.restart()
    notifyProc.running = true
  }

  // ---------- inline picker ----------

  property string pickerTarget: ""      // "", "fg" or "bg"
  property real pickH: 0                // degrees
  property real pickS: 0                // 0..1
  property real pickV: 1                // 0..1
  property bool pickerDriving: false    // true while the picker writes the colour

  function setPickerMode(mode) {
    if (!root.pickerModes[mode]) return
    root.pickerMode = mode
    Qt.callLater(root.syncPickerFields)
  }

  function openPicker(target) {
    if (root.pickerTarget === target) { root.pickerTarget = ""; return }
    root.pickerTarget = target
    syncPickerFromColor()
  }

  function pickerRgb() {
    return root.pickerTarget === "bg" ? root.bgRgb : root.fgRgb
  }

  function syncPickerFromColor() {
    if (!root.pickerTarget) return
    var hsv = Contrast.rgbToHsv(pickerRgb())
    if (hsv.s > 0.001 && hsv.v > 0.001) root.pickH = hsv.h
    root.pickS = hsv.s
    root.pickV = hsv.v
    syncPickerFields()
  }

  property string pickerMode: "rgb"     // rgb | hsl | oklch | grey
  readonly property var pickerModes: ({
    hsl:   [{ key: "h",  label: "H", max: 360 }, { key: "s",  label: "S", max: 100 }, { key: "l",  label: "L", max: 100 }],
    rgb:   [{ key: "r",  label: "R", max: 255 }, { key: "g",  label: "G", max: 255 }, { key: "b",  label: "B", max: 255 }],
    grey:  [{ key: "k",  label: "K", max: 255 }],
    oklch: [{ key: "ol", label: "L", max: 100 }, { key: "oc", label: "C", max: 0.4 }, { key: "oh", label: "H", max: 360 }]
  })

  // Colour obtained by setting one channel (key) to `val` while keeping the rest.
  function colorWithKey(key, val, c) {
    if (key === "r" || key === "g" || key === "b") { var o = { r: c.r, g: c.g, b: c.b }; o[key] = val; return o }
    if (key === "k") return { r: val, g: val, b: val }
    if (key === "h" || key === "s" || key === "l") {
      var hsl = Contrast.rgbToHsl(c)
      var h = hsl.s > 0.001 ? hsl.h : root.pickH, sat = hsl.s, l = hsl.l
      if (key === "h") h = val; else if (key === "s") sat = val / 100; else l = val / 100
      return Contrast.hslToRgb(h, sat, l)
    }
    var ok = Contrast.rgbToOklch(c)
    var L = ok.L, C = ok.C, H = ok.C > 0.002 ? ok.h : root.pickH
    if (key === "ol") L = val / 100; else if (key === "oc") C = val; else H = val
    return Contrast.oklchToRgb(L, C, H)
  }

  // Seven gradient stops for a slider, sampled through the real conversion.
  function sliderStopsFor(key, max, hex, pickH) {
    var c = Contrast.parseHex(hex)
    var out = []
    for (var i = 0; i <= 6; i++) out.push(Contrast.toHex(colorWithKey(key, max * i / 6, c)))
    return out
  }

  function sliderValueFor(key, max, hex, pickH) {
    return Math.max(0, Math.min(1, parseFloat(pickerFieldValue(key)) / max))
  }

  function pickerFieldValue(key) {
    var c = pickerRgb()
    if (key === "hex") return Contrast.toHex(c)
    if (key === "r") return c.r
    if (key === "g") return c.g
    if (key === "b") return c.b
    if (key === "k") return Math.round((c.r + c.g + c.b) / 3)
    if (key === "bh") return Math.round(root.pickH)
    if (key === "bs") return Math.round(root.pickS * 100)
    if (key === "bv") return Math.round(root.pickV * 100)
    if (key === "ol" || key === "oc" || key === "oh") {
      var ok = Contrast.rgbToOklch(c)
      if (key === "ol") return (ok.L * 100).toFixed(1)
      if (key === "oc") return ok.C.toFixed(3)
      return ok.C > 0.002 ? Math.round(ok.h) : Math.round(root.pickH)   // hue is meaningless at zero chroma
    }
    var hsl = Contrast.rgbToHsl(c)
    if (key === "h") return Math.round(hsl.s > 0.001 ? hsl.h : root.pickH)
    if (key === "s") return Math.round(hsl.s * 100)
    return Math.round(hsl.l * 100)
  }

  function syncPickerFields() {
    for (var i = 0; i < sliderRepeater.count; i++) {
      var item = sliderRepeater.itemAt(i)
      if (!item || !item.field || item.field.activeFocus) continue
      item.field.text = String(pickerFieldValue(item.key))
    }
  }

  // Write a colour produced by the picker into the active target.
  function pickerCommit(rgb, fromHsv) {
    var hex = Contrast.toHex(rgb)
    root.pickerDriving = true
    if (root.pickerTarget === "bg") { bgField.text = hex; setBg(hex) }
    else { fgField.text = hex; setFg(hex) }
    root.pickerDriving = false
    if (fromHsv) syncPickerFields()
    else syncPickerFromColor()
  }

  function pickerSetSV(sv, vv) {
    root.pickS = Contrast.clamp01(sv)
    root.pickV = Contrast.clamp01(vv)
    pickerCommit(Contrast.hsvToRgb(root.pickH, root.pickS, root.pickV), true)
  }

  // Hue/lightness map: set H and HSL-L together, keeping saturation.
  function pickerSetHL(h, l) {
    var c = pickerRgb()
    var hsl = Contrast.rgbToHsl(c)
    h = Math.max(0, Math.min(359.999, h))
    l = Contrast.clamp01(l)
    root.pickH = h
    pickerCommit(Contrast.hslToRgb(h, hsl.s, l), false)
    root.pickH = h
    syncPickerFields()
  }

  function pickerSetH(h) {
    root.pickH = Math.max(0, Math.min(359.999, h))
    pickerCommit(Contrast.hsvToRgb(root.pickH, root.pickS, root.pickV), true)
  }

  function pickerFieldEdited(key, text) {
    if (key === "hex") {
      var hc = Contrast.parseHex(text)
      if (hc) pickerCommit(hc, false); else syncPickerFields()
      return
    }
    var c = pickerRgb()
    if (key === "ol" || key === "oc" || key === "oh") {
      var fv = parseFloat(text)
      if (isNaN(fv)) { syncPickerFields(); return }
      var ok = Contrast.rgbToOklch(c)
      var L = ok.L, C = ok.C, H = ok.C > 0.002 ? ok.h : root.pickH
      if (key === "ol") L = Math.max(0, Math.min(100, fv)) / 100
      else if (key === "oc") C = Math.max(0, Math.min(0.5, fv))
      else H = ((fv % 360) + 360) % 360
      pickerCommit(Contrast.oklchToRgb(L, C, H), false)
      return
    }
    var v = (key === "h" || key === "s" || key === "l") ? parseFloat(text) : parseInt(text, 10)
    if (isNaN(v)) { syncPickerFields(); return }
    if (key === "k") { var kv = Math.max(0, Math.min(255, v)); pickerCommit({ r: kv, g: kv, b: kv }, false); return }
    if (key === "r" || key === "g" || key === "b") {
      var rgb = { r: c.r, g: c.g, b: c.b }
      rgb[key] = Math.max(0, Math.min(255, v))
      pickerCommit(rgb, false)
      return
    }
    if (key === "bh" || key === "bs" || key === "bv") {
      if (key === "bh") root.pickH = ((v % 360) + 360) % 360
      else if (key === "bs") root.pickS = Math.max(0, Math.min(100, v)) / 100
      else root.pickV = Math.max(0, Math.min(100, v)) / 100
      pickerCommit(Contrast.hsvToRgb(root.pickH, root.pickS, root.pickV), true)
      return
    }
    var hsl = Contrast.rgbToHsl(c)
    var h = hsl.s > 0.001 ? hsl.h : root.pickH, sat = hsl.s, l = hsl.l
    if (key === "h") h = ((v % 360) + 360) % 360
    else if (key === "s") sat = Math.max(0, Math.min(100, v)) / 100
    else l = Math.max(0, Math.min(100, v)) / 100
    root.pickH = h
    pickerCommit(Contrast.hslToRgb(h, sat, l), false)
    root.pickH = h   // keep the typed hue even when s/l collapse it
    syncPickerFields()
  }

  // ---------- eyedropper ----------

  function pick(target) {
    if (root.picking || pickProc.running) return
    root.pickTarget = target
    root.pickCaptured = ""
    // The card stays put; only the scrim and the keyboard grab are released so
    // hyprpicker can freeze the desktop and take input.
    root.picking = true
    pickProc.command = root.trustedCommand(
      Contrast.PICK_DEADLINE_SECS, Contrast.MAX_PICK_BYTES, Contrast.MAX_PICK_ERR_BYTES,
      "hyprpicker", ["--format=hex", "--lowercase-hex", "--no-fancy"]
    )
    pickWatchdog.restart()
    pickProc.running = true
  }

  property string pickCaptured: ""

  function reopenAfterPick() {
    pickWatchdog.stop()
    pickKillGrace.stop()
    root.picking = false
    Qt.callLater(function() {
      if (!root.opened) return
      (root.pickTarget === "fg" ? fgField : bgField).forceActiveFocus()
    })
  }

  function abortPick() {
    pickWatchdog.stop()
    pickSettle.stop()
    root.stopProc(pickProc, pickKillGrace)
    if (root.picking) root.reopenAfterPick()
  }

  function applyCapturedPick() {
    if (!root.picking) return
    var h = Contrast.parsePickedColor(root.pickCaptured)
    if (h) {
      if (root.pickTarget === "fg") { fgField.text = h; setFg(h) }
      else { bgField.text = h; setBg(h) }
    }
    root.reopenAfterPick()
  }

  Process {
    id: pickProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        if (text.length > Contrast.MAX_PICK_BYTES) root.abortPick()
      }
      onStreamFinished: root.pickCaptured = text
    }
    stderr: StdioCollector {
      waitForEnd: false
      onDataChanged: {
        if (text.length > Contrast.MAX_PICK_ERR_BYTES) root.abortPick()
      }
    }
    onExited: {
      pickWatchdog.stop()
      pickKillGrace.stop()
      if (!root.picking) return
      pickSettle.restart()
    }
  }

  Timer {
    id: pickSettle
    interval: 50
    repeat: false
    onTriggered: root.applyCapturedPick()
  }

  Timer {
    id: pickWatchdog
    interval: (Contrast.PICK_DEADLINE_SECS + 3) * 1000
    repeat: false
    onTriggered: root.abortPick()
  }
  Timer {
    id: pickKillGrace
    interval: 2000
    repeat: false
    onTriggered: root.forceKill(pickProc)
  }

  Process {
    id: copyProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: { if (text.length > Contrast.MAX_TOOL_BYTES) root.stopProc(copyProc, copyKillGrace) }
    }
    stderr: StdioCollector {
      waitForEnd: false
      onDataChanged: { if (text.length > Contrast.MAX_TOOL_BYTES) root.stopProc(copyProc, copyKillGrace) }
    }
    onExited: { copyWatchdog.stop(); copyKillGrace.stop() }
  }
  Timer {
    id: copyWatchdog
    interval: (Contrast.TOOL_DEADLINE_SECS + 3) * 1000
    repeat: false
    onTriggered: root.stopProc(copyProc, copyKillGrace)
  }
  Timer {
    id: copyKillGrace
    interval: 2000
    repeat: false
    onTriggered: root.forceKill(copyProc)
  }

  Process {
    id: notifyProc
    stdout: StdioCollector {
      waitForEnd: false
      onDataChanged: { if (text.length > Contrast.MAX_TOOL_BYTES) root.stopProc(notifyProc, notifyKillGrace) }
    }
    stderr: StdioCollector {
      waitForEnd: false
      onDataChanged: { if (text.length > Contrast.MAX_TOOL_BYTES) root.stopProc(notifyProc, notifyKillGrace) }
    }
    onExited: { notifyWatchdog.stop(); notifyKillGrace.stop() }
  }
  Timer {
    id: notifyWatchdog
    interval: (Contrast.TOOL_DEADLINE_SECS + 3) * 1000
    repeat: false
    onTriggered: root.stopProc(notifyProc, notifyKillGrace)
  }
  Timer {
    id: notifyKillGrace
    interval: 2000
    repeat: false
    onTriggered: root.forceKill(notifyProc)
  }

  // ---------- UI ----------

  readonly property int badgeWidth: Style.space(72)

  component Badge: Rectangle {
    property bool pass: false
    property string label: ""
    implicitWidth: root.badgeWidth
    Layout.preferredWidth: root.badgeWidth
    Layout.minimumWidth: root.badgeWidth
    implicitHeight: badgeText.implicitHeight + Style.spacing.xs * 2
    radius: root.cornerRadius
    color: Util.alpha(pass ? root.accent : root.urgent, 0.18)
    border.width: 1
    border.color: Util.alpha(pass ? root.accent : root.urgent, 0.6)
    Text {
      id: badgeText
      anchors.centerIn: parent
      text: (parent.pass ? "✓ " : "✗ ") + parent.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component Swatch: RowLayout {
    id: swatch
    property string title: ""
    property alias field: input
    property color colorValue: "black"
    property string target: "fg"
    signal committed(string hex)
    spacing: Style.spacing.sm

    Rectangle {
      width: Style.space(30); height: Style.space(30)
      radius: root.cornerRadius
      color: swatch.colorValue
      border.width: root.pickerTarget === swatch.target ? 2 : 1
      border.color: root.pickerTarget === swatch.target ? root.accent : Util.alpha(root.foreground, 0.35)
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openPicker(swatch.target)
      }
      PanelToolTip { visible: swatchHover.hovered; text: swatch.title + " · click to open picker" }
      HoverHandler { id: swatchHover }
    }

    TextField {
      id: input
      Layout.fillWidth: true
      Layout.minimumWidth: Style.space(90)
      placeholderText: "#rrggbb"
      font.family: Style.font.resolvedFamily
      onTextChanged: if (Contrast.parseHex(text)) swatch.committed(text)
      onEditingFinished: { var c = Contrast.parseHex(text); if (c) text = Contrast.toHex(c) }
    }

    Button {
      iconText: "󰆏"
      tooltipText: "Copy Hex"
      onClicked: root.copyHex(String(swatch.colorValue))
    }

  }

  // Gradient slider: 7 sampled stops, full-width track, white pill thumb.
  component GradSlider: Item {
    id: gs
    property real value: 0            // 0..1
    property var stops: ["#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#ffffff"]
    property real trackHeight: Style.space(14)
    signal moved(real v)
    Layout.fillWidth: true
    height: trackHeight + Style.space(6)
    readonly property real thumbW: Style.space(8)
    readonly property real usable: width - thumbW

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width; height: gs.trackHeight
      radius: root.cornerRadius
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0 / 6; color: gs.stops[0] }
        GradientStop { position: 1 / 6; color: gs.stops[1] }
        GradientStop { position: 2 / 6; color: gs.stops[2] }
        GradientStop { position: 3 / 6; color: gs.stops[3] }
        GradientStop { position: 4 / 6; color: gs.stops[4] }
        GradientStop { position: 5 / 6; color: gs.stops[5] }
        GradientStop { position: 6 / 6; color: gs.stops[6] }
      }
    }
    Rectangle {
      x: gs.value * gs.usable
      width: gs.thumbW; height: gs.height; radius: Style.space(3)
      color: "#ffffff"
      border.width: 1; border.color: "#66000000"
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      function setFrom(mx) { gs.moved(Math.max(0, Math.min(1, (mx - gs.thumbW / 2) / gs.usable))) }
      onPressed: function(mouse) { setFrom(mouse.x) }
      onPositionChanged: function(mouse) { if (pressed) setFrom(mouse.x) }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-contrast"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.picking ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.picking ? "transparent" : root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: root.mainWidth + card.contentLeftInset + card.contentRightInset
             + (root.drawerOpen ? root.drawerWidth + row.spacing * 2 + 1 : 0)
      height: Math.max(body.implicitHeight, root.drawerOpen ? drawer.implicitHeight : 0)
              + card.contentTopInset + card.contentBottomInset
      Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      // Key events bubble up from the focused TextField to here.
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          if (root.pickerTarget) root.pickerTarget = ""
          else root.dismiss()
          event.accepted = true
          return
        }
        if ((event.modifiers & Qt.ShiftModifier) && event.key === Qt.Key_X) { root.swap(); event.accepted = true; return }
        if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
          var step = (event.modifiers & Qt.ShiftModifier) ? 0.1 : 0.01
          root.nudge(root.nudgeTarget(), event.key === Qt.Key_Up ? step : -step)
          event.accepted = true
          return
        }
        if (event.modifiers & Qt.ControlModifier) {
          if (event.key === Qt.Key_F) { root.pick("fg"); event.accepted = true }
          else if (event.key === Qt.Key_B) { root.pick("bg"); event.accepted = true }
        }
      }

      RowLayout {
        id: row
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: card.contentLeftInset
        anchors.topMargin: card.contentTopInset
        spacing: Style.spacing.xl
        clip: true

      ColumnLayout {
        id: body
        Layout.preferredWidth: root.mainWidth
        Layout.maximumWidth: root.mainWidth
        Layout.alignment: Qt.AlignTop
        spacing: Style.spacing.lg

        // Header
        RowLayout {
          Layout.fillWidth: true
          Text {
            text: "Contrast"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Item { Layout.fillWidth: true }
        }

        // Preview: big "Aa" on the background colour
        Rectangle {
          Layout.fillWidth: true
          height: Style.space(150)
          radius: root.cornerRadius
          color: root.bgColor
          border.width: 1
          border.color: Util.alpha(root.foreground, 0.2)
          Text {
            anchors.centerIn: parent
            text: "Aa"
            color: root.fgColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge * 2.2
          }
        }

        // Colours: [fg] ⇄ [bg]
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md
          Swatch {
            id: fgSwatch
            Layout.fillWidth: true
            title: "Foreground"
            target: "fg"
            colorValue: root.fgColor
            onCommitted: function(hex) { root.setFg(hex) }
          }
          Button {
            iconText: "󰓡"
            iconSize: Style.font.iconLarge
            tooltipText: "Swap (Shift+X)"
            onClicked: root.swap()
          }
          Swatch {
            id: bgSwatch
            Layout.fillWidth: true
            title: "Background"
            target: "bg"
            colorValue: root.bgColor
            onCommitted: function(hex) { root.setBg(hex) }
          }
        }

        // Rating bar: level · ratio · ↑↓ steppers
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm
          Rectangle {
            Layout.fillWidth: true
            height: Style.spacing.controlHeight
            radius: root.cornerRadius
            color: Util.alpha(root.foreground, 0.06)
            border.width: 1
            border.color: Util.alpha(root.result.ratio >= 4.5 ? root.accent : root.urgent, 0.5)
            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.rightMargin: Style.spacing.controlPaddingX
              Text {
                text: root.result.grade
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Item { Layout.fillWidth: true }
              Text {
                text: root.result.ratio.toFixed(2)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }
          }
          Button { iconText: "󰅃"; tooltipText: "Lighten 1% (↑, Shift for 10%)"; bordered: true; onClicked: root.nudge(root.nudgeTarget(), 0.01) }
          Button { iconText: "󰅀"; tooltipText: "Darken 1% (↓, Shift for 10%)"; bordered: true; onClicked: root.nudge(root.nudgeTarget(), -0.01) }
        }

        Text {
          Layout.fillWidth: true
          text: root.ratingText
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      // Divider
      Rectangle {
        visible: root.drawerOpen
        Layout.fillHeight: true
        Layout.preferredWidth: 1
        color: Util.alpha(root.foreground, 0.15)
      }

      // Picker drawer: mode · sliders · hue/lightness map
      ColumnLayout {
        id: drawer
        visible: root.drawerOpen
        Layout.preferredWidth: root.drawerWidth
        Layout.maximumWidth: root.drawerWidth
        Layout.alignment: Qt.AlignTop
        spacing: Style.spacing.lg

        readonly property string currentHex: root.pickerTarget === "bg" ? root.bgHex : root.fgHex

        // Row 1: eyedropper · close
        RowLayout {
          Layout.fillWidth: true
          Button {
            iconText: "󰈊"
            iconSize: Style.font.iconLarge
            tooltipText: "Eyedropper (" + (root.pickerTarget === "bg" ? "Ctrl+B" : "Ctrl+F") + ")"
            onClicked: root.pick(root.pickerTarget)
          }
          Item { Layout.fillWidth: true }
          Button { text: "✕"; tooltipText: "Close (Esc)"; onClicked: root.pickerTarget = "" }
        }

        // Row 2: colour system
        Dropdown {
          Layout.fillWidth: true
          Layout.minimumWidth: 0
          showLabel: false
          options: [
            { value: "rgb", label: "RGB" }, { value: "hsl", label: "HSL" },
            { value: "oklch", label: "OKLCH" }, { value: "grey", label: "Greyscale" }
          ]
          value: root.pickerMode
          onChanged: function(v) { root.setPickerMode(v) }
        }

        // Row 3: sliders for the mode (label · slider · value)
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md

          Repeater {
            id: sliderRepeater
            model: root.pickerModes[root.pickerMode]
            delegate: RowLayout {
              required property var modelData
              readonly property string key: modelData.key
              readonly property var field: valueField
              Layout.fillWidth: true
              spacing: Style.spacing.md

              Text {
                Layout.preferredWidth: Style.space(14)
                text: modelData.label
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              GradSlider {
                stops: root.sliderStopsFor(modelData.key, modelData.max, drawer.currentHex, root.pickH)
                value: root.sliderValueFor(modelData.key, modelData.max, drawer.currentHex, root.pickH)
                onMoved: function(v) {
                  var val = v * modelData.max
                  var txt = modelData.max < 1 ? val.toFixed(3)
                          : (modelData.max === 255 ? String(Math.round(val)) : val.toFixed(1))
                  root.pickerFieldEdited(modelData.key, txt)
                }
              }
              TextField {
                id: valueField
                Layout.preferredWidth: Style.space(60)
                Layout.minimumWidth: Style.space(60)
                Layout.maximumWidth: Style.space(60)
                horizontalAlignment: TextInput.AlignHCenter
                font.family: Style.font.resolvedFamily
                onEditingFinished: root.pickerFieldEdited(modelData.key, text)
                onActiveFocusChanged: if (activeFocus) selectAll()
                Component.onCompleted: text = String(root.pickerFieldValue(modelData.key))
              }
            }
          }
        }

        // Row 4: hue × lightness map (x = hue, y = lightness) at full saturation.
        // In Greyscale mode it becomes a half-height black→white ramp (x = K).
        Item {
          id: hlMap
          Layout.fillWidth: true
          readonly property bool grey: root.pickerMode === "grey"
          height: grey ? Style.space(42) : Style.space(85)
          Behavior on height { NumberAnimation { duration: 120 } }
          readonly property real thumb: Style.space(16)
          readonly property var hsl: Contrast.rgbToHsl(Contrast.parseHex(drawer.currentHex))
          readonly property real sat: hsl.s
          readonly property real light: hsl.l
          readonly property real k: parseFloat(root.pickerFieldValue("k")) / 255

          // Rainbow across (colour) / black→white ramp (grey)
          Rectangle {
            anchors.fill: parent; radius: root.cornerRadius
            visible: !hlMap.grey
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0.000; color: "#ff0000" }
              GradientStop { position: 0.167; color: "#ffff00" }
              GradientStop { position: 0.333; color: "#00ff00" }
              GradientStop { position: 0.500; color: "#00ffff" }
              GradientStop { position: 0.667; color: "#0000ff" }
              GradientStop { position: 0.833; color: "#ff00ff" }
              GradientStop { position: 1.000; color: "#ff0000" }
            }
          }
          Rectangle {
            anchors.fill: parent; radius: root.cornerRadius
            visible: hlMap.grey
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0; color: "#000000" }
              GradientStop { position: 1; color: "#ffffff" }
            }
          }
          // White at top → clear in the middle → black at bottom (HSL lightness)
          Rectangle {
            anchors.fill: parent; radius: root.cornerRadius
            visible: !hlMap.grey
            gradient: Gradient {
              GradientStop { position: 0.0; color: "#ffffffff" }
              GradientStop { position: 0.5; color: "#00ffffff" }
              GradientStop { position: 0.5; color: "#00000000" }
              GradientStop { position: 1.0; color: "#ff000000" }
            }
          }
          Rectangle {
            width: hlMap.thumb; height: width; radius: width / 2
            x: (hlMap.grey ? hlMap.k : root.pickH / 360) * hlMap.width - width / 2
            y: (hlMap.grey ? 0.5 : 1 - hlMap.light) * hlMap.height - height / 2
            color: "transparent"
            border.width: 2; border.color: "#ffffff"
            Rectangle { anchors.fill: parent; anchors.margins: -1; radius: width / 2; color: "transparent"; border.width: 1; border.color: "#40000000" }
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.CrossCursor
            function setFrom(mx, my) {
              if (hlMap.grey) root.pickerFieldEdited("k", String(Math.round(Math.max(0, Math.min(1, mx / width)) * 255)))
              else root.pickerSetHL(mx / width * 360, 1 - my / height)
            }
            onPressed: function(mouse) { setFrom(mouse.x, mouse.y) }
            onPositionChanged: function(mouse) { if (pressed) setFrom(mouse.x, mouse.y) }
          }
        }
      }
      }
    }
  }

  readonly property var fgField: fgSwatch.field
  readonly property var bgField: bgSwatch.field

  Component.onCompleted: {
    fgField.text = root.fgHex
    bgField.text = root.bgHex
  }

  Component.onDestruction: root.stopAllTools()
}
