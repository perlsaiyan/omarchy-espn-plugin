import QtQuick
import qs.Commons
import qs.Ui

// The bar slot: a football, drawn rather than shipped as an asset so it takes
// the bar's foreground colour and follows the theme with no light/dark twin.
BarWidget {
  id: root
  moduleName: "espn.fantasy"

  readonly property bool hoverToOpen: {
    var v = root.settings ? root.settings.hoverToOpen : undefined
    return v === undefined ? true : v === true
  }
  readonly property int hoverDelayMs: {
    var v = root.settings ? root.settings.hoverDelayMs : undefined
    return v === undefined ? 220 : Number(v)
  }

  // A hover-opened panel that closed the moment the pointer left the icon
  // would be unusable: every matchup in it is a click target, and the pointer
  // has to cross open air to reach them. So hover opens it, the pointer being
  // anywhere over icon *or* panel keeps it open, and a click pins it until
  // clicked again.
  property bool pinned: false
  readonly property bool panelHovered: panelLoader.item ? panelLoader.item.contentHovered === true : false
  readonly property bool anyHovered: button.tooltipHovered || panelHovered

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (!panelLoader.item) return
    if (root.opened && root.pinned) {
      root.pinned = false
      panelLoader.item.close()
    } else {
      root.pinned = true
      panelLoader.item.openFromHotkey()
    }
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    root.pinned = false
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() {
    root.pinned = false
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  onAnyHoveredChanged: {
    if (!root.hoverToOpen) return
    if (root.anyHovered) {
      closeTimer.stop()
      if (!root.opened) openTimer.restart()
    } else {
      openTimer.stop()
      if (root.opened && !root.pinned) closeTimer.restart()
    }
  }

  Timer {
    id: openTimer
    interval: root.hoverDelayMs
    onTriggered: {
      if (root.anyHovered && panelLoader.item) panelLoader.item.open()
    }
  }

  // Long enough to cross the gap between the icon and the panel without the
  // scoreboard evaporating mid-reach.
  Timer {
    id: closeTimer
    interval: 400
    onTriggered: {
      if (!root.anyHovered && !root.pinned && panelLoader.item) panelLoader.item.close()
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    slotSize: Style.bar.statusSlot
    tooltipText: ""

    iconComponent: Component {
      Canvas {
        id: ball
        implicitWidth: Style.bar.iconCanvas
        implicitHeight: Style.bar.iconCanvas
        readonly property color ink: root.bar ? root.bar.foreground : Color.foreground
        onInkChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.reset()
          var w = width, h = height
          var cx = w / 2, cy = h / 2
          var rx = w * 0.45, ry = h * 0.32

          // A filled prolate spheroid. Outlined, it reads as an eye at bar
          // size — the solid shape is what makes it a football.
          ctx.beginPath()
          ctx.moveTo(cx - rx, cy)
          ctx.quadraticCurveTo(cx, cy - ry * 2.0, cx + rx, cy)
          ctx.quadraticCurveTo(cx, cy + ry * 2.0, cx - rx, cy)
          ctx.closePath()
          ctx.fillStyle = ball.ink
          ctx.fill()

          // Laces are erased rather than painted, so they read as gaps in the
          // ball on any theme background instead of needing to know its colour.
          ctx.globalCompositeOperation = "destination-out"
          ctx.lineCap = "butt"

          var stroke = Math.max(1, Math.round(w * 0.075))
          ctx.lineWidth = stroke

          ctx.beginPath()
          ctx.moveTo(cx - rx * 0.42, cy)
          ctx.lineTo(cx + rx * 0.42, cy)
          ctx.stroke()

          // Crossbars only once there is room for them to read as separate
          // laces. At the default 16px bar canvas they would erase most of
          // the ball's middle and turn it back into a blob, so below that the
          // spine alone is the more honest football.
          if (w >= 22) {
            var spacing = stroke * 2.5
            for (var i = -1; i <= 1; i++) {
              var x = cx + i * spacing
              ctx.beginPath()
              ctx.moveTo(x, cy - ry * 0.36)
              ctx.lineTo(x, cy + ry * 0.36)
              ctx.stroke()
            }
          }

          ctx.globalCompositeOperation = "source-over"
        }
      }
    }

    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.refresh()
      // Through the panel's openUrl, which passes argv rather than a shell
      // string — this URL has one parameter today, but it is the same trap.
      else if (b === Qt.MiddleButton && panelLoader.item) panelLoader.item.openUrl(panelLoader.item.leagueUrl)
      else root.togglePanel()
    }
  }
}
