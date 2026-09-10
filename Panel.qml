import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Pure display. Everything shown here was put on disk by bin/omarchy-espn-update;
// this file reads that record, watches it for changes, and draws it.
Panel {
  id: root
  moduleName: "espn.fantasy"
  ipcTarget: "espn.fantasy"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Hover mode is a passive overlay: no focus grab, so the pointer can cross
  // from the icon to the card. Pinning it with a click switches to a real
  // grab so that clicking anywhere outside dismisses it again.
  readonly property bool pinned: hostWidget ? hostWidget.pinned === true : false
  readonly property bool contentHovered: card.containsMouse

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "")
  readonly property int refreshIntervalSec: {
    var v = root.settings ? root.settings.refreshIntervalSec : undefined
    return v === undefined ? 60 : Math.max(30, Number(v))
  }

  property var record: ({})
  readonly property var matchups: record && record.matchups ? record.matchups : []
  readonly property var league: record && record.league ? record.league : null
  readonly property string errorText: record && record.error ? String(record.error) : ""
  readonly property string leagueUrl: league && league.url ? league.url : "https://fantasy.espn.com/football/"
  property double nowMs: Date.now()

  function open() { root.controller.show(); root.refresh() }
  function openFromHotkey() { root.controller.show(); root.refresh() }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function refresh() { if (!updateProc.running) updateProc.running = true }

  // Not bar.run(): that concatenates into `bash -lc <string>`, and a box score
  // URL is nothing but ampersands — bash splits the command at the first one,
  // launches the browser with the query truncated to ?leagueId=..., and
  // backgrounds the rest as gibberish. That is what sent clicks to the wrong
  // matchup. execArgv passes argv through positional parameters, so the URL
  // arrives intact and unre-tokenized.
  function openUrl(url) {
    if (url) Util.execArgv(["omarchy-launch-browser", String(url)])
    if (root.hostWidget) root.hostWidget.close()
  }

  function fmt(n, digits) {
    var v = Number(n)
    if (!isFinite(v)) return "—"
    return v.toFixed(digits === undefined ? 1 : digits)
  }

  function pct(p) {
    if (p === null || p === undefined) return ""
    return Math.round(Number(p) * 100) + "%"
  }

  // 497 minutes is true but unreadable at a glance; 8h17m is the same fact
  // in the units people actually think in.
  function clock(minutes) {
    var m = Math.max(0, Math.round(Number(minutes) || 0))
    if (m === 0) return "final"
    if (m < 60) return m + "m"
    return Math.floor(m / 60) + "h" + (m % 60 > 0 ? (m % 60) + "m" : "")
  }

  function ago(iso) {
    if (!iso) return ""
    var t = Date.parse(iso)
    if (isNaN(t)) return ""
    var s = Math.max(0, Math.round((root.nowMs - t) / 1000))
    if (s < 60) return s + "s ago"
    if (s < 3600) return Math.floor(s / 60) + "m ago"
    return Math.floor(s / 3600) + "h ago"
  }

  FileView {
    id: stateFile
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/espn/scoreboard.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.record = JSON.parse(text()) }
      catch (e) { root.record = { error: "unreadable state file" } }
    }
    onLoadFailed: root.record = { error: "no data yet — run bin/omarchy-espn-update" }
  }

  Process {
    id: updateProc
    running: false
    command: [root.pluginDir + "bin/omarchy-espn-update"]
    // The collector writes the state file; the FileView watch above is what
    // actually repaints, so there is nothing to do on exit but let it go.
  }

  // Poll while the panel is closed too: the whole point of a bar widget is
  // that the number is already right when you look at it.
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Keeps "updated 40s ago" honest while the card sits open.
  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  PopupCard {
    id: card
    anchorItem: root.anchorItem
    bar: root.bar
    owner: root.barIdentity
    open: root.opened
    triggerMode: root.pinned ? "click" : "hover"
    contentWidth: card.fittedContentWidth(Style.space(400))
    contentHeight: card.fittedContentHeight(body.implicitHeight, Style.space(620))

    Column {
      id: body
      width: parent.width
      spacing: Style.space(10)

      // ------------------------------------------------------------ header
      Item {
        width: parent.width
        implicitHeight: Math.max(titleCol.implicitHeight, updatedLabel.implicitHeight)

        Column {
          id: titleCol
          anchors.left: parent.left
          spacing: Style.space(2)

          Text {
            text: root.league ? root.league.name : "ESPN Fantasy"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.space(15)
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            width: Math.min(implicitWidth, body.width - Style.space(90))
          }
          Text {
            visible: !!root.league
            text: root.league ? ("Season " + root.league.season + " · Week " + root.league.week) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
          }
        }

        Text {
          id: updatedLabel
          anchors.right: parent.right
          anchors.top: parent.top
          text: root.record && root.record.updatedAt ? root.ago(root.record.updatedAt) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.space(11)
        }
      }

      PanelSeparator { width: parent.width }

      // ------------------------------------------------------------- error
      Text {
        visible: root.errorText !== ""
        width: parent.width
        text: root.errorText
        color: root.urgent
        wrapMode: Text.WordWrap
        font.family: root.fontFamily
        font.pixelSize: Style.space(12)
      }

      Text {
        visible: root.errorText === "" && root.matchups.length === 0
        width: parent.width
        text: "No matchups this week."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.space(12)
      }

      // --------------------------------------------------------- scoreboard
      Repeater {
        model: root.matchups

        delegate: Rectangle {
          id: game
          required property var modelData
          readonly property var away: modelData.away
          readonly property var home: modelData.home
          // Once a side is mathematically ahead with the clock gone, the win
          // bar stops being a forecast and starts being a result.
          readonly property bool live: (away.playing + home.playing) > 0

          width: body.width
          implicitHeight: rows.implicitHeight + Style.space(16)
          radius: Style.space(6)
          color: gameHover.hovered ? Style.selectedFillFor(root.foreground, Color.accent)
                                   : (modelData.mine ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
                                                     : "transparent")
          border.width: modelData.mine ? 1 : 0
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

          HoverHandler { id: gameHover }
          TapHandler { onTapped: root.openUrl(modelData.url) }

          Column {
            id: rows
            anchors.centerIn: parent
            width: parent.width - Style.space(16)
            spacing: Style.space(4)

            Repeater {
              model: [game.away, game.home]

              delegate: Item {
                required property var modelData
                readonly property bool leading: modelData.points > 0
                  && modelData.points >= Math.max(game.away.points, game.home.points)

                width: rows.width
                implicitHeight: Style.space(18)

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(120)
                  text: modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(13)
                  font.weight: parent.leading ? Font.DemiBold : Font.Normal
                  elide: Text.ElideRight
                }

                Text {
                  anchors.right: winPct.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.fmt(modelData.points)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(13)
                  font.weight: parent.leading ? Font.DemiBold : Font.Normal
                }

                Text {
                  id: winPct
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(38)
                  horizontalAlignment: Text.AlignRight
                  text: root.pct(modelData.winProbability)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(11)
                }
              }
            }

            // ESPN's own win probability, drawn as one bar split between the
            // two teams: the top row owns the left, the bottom row the right.
            // Two tones rather than a fill on an empty track, so it reads as a
            // division of a whole instead of a progress meter.
            Item {
              visible: game.away.winProbability !== null && game.away.winProbability !== undefined
              width: rows.width
              height: Style.space(4)

              readonly property real awayShare:
                Math.max(0, Math.min(1, Number(game.away.winProbability) || 0))

              Rectangle {
                width: parent.width * parent.awayShare
                height: parent.height
                radius: height / 2
                color: Color.accent
              }

              Rectangle {
                anchors.right: parent.right
                width: parent.width * (1 - parent.awayShare)
                height: parent.height
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)
              }
            }

            Text {
              width: rows.width
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(11)
              elide: Text.ElideRight
              // Terse on purpose: the long form ("3 on the field · 15 yet to
              // play · 8h32m of clock left") overruns the card and elides.
              text: {
                var playing = game.away.playing + game.home.playing
                var pre = game.away.yetToPlay + game.home.yetToPlay
                var parts = []
                if (playing > 0) parts.push(playing + " playing")
                if (pre > 0) parts.push(pre + " to play")
                var left = Math.max(game.away.minutesLeft, game.home.minutesLeft)
                parts.push(left > 0 ? root.clock(left) + " left" : "final")
                return parts.join("  ·  ")
              }
            }
          }
        }
      }

      PanelSeparator { width: parent.width; visible: root.matchups.length > 0 }

      // ------------------------------------------------------------ footer
      Item {
        width: parent.width
        implicitHeight: Style.space(20)

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Open FantasyCast"
          color: castHover.hovered ? Color.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.space(12)
          font.underline: castHover.hovered

          HoverHandler { id: castHover }
          TapHandler { onTapped: root.openUrl(root.leagueUrl) }
        }

        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "click a matchup for its box score"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.space(10)
        }
      }
    }
  }
}
