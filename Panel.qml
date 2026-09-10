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
  // The drill-down is addressed by matchup id, not by holding the object:
  // a refresh rebuilds `matchups` wholesale, and a stored object would freeze
  // the detail view at the scores it was opened with.
  property int selectedId: -1
  readonly property var selected: {
    if (selectedId < 0) return null
    for (var i = 0; i < matchups.length; i++)
      if (matchups[i].id === selectedId) return matchups[i]
    return null
  }

  function selectMatchup(m) {
    if (!m) return
    root.selectedId = m.id
    // Drilling in is deliberate engagement, so pin the card open rather than
    // letting it evaporate when the pointer drifts off.
    if (root.hostWidget) root.hostWidget.pinned = true
  }

  function back() { root.selectedId = -1 }

  // Starters of both sides zipped into box-score rows. Slot structures match
  // in any sane league, but pair by index and tolerate a ragged edge.
  function starterRows(m) {
    if (!m) return []
    function starters(side) {
      var out = []
      var r = (side && side.roster) ? side.roster : []
      for (var i = 0; i < r.length; i++) if (r[i].starter) out.push(r[i])
      return out
    }
    var a = starters(m.away), h = starters(m.home)
    var rows = []
    for (var i = 0; i < Math.max(a.length, h.length); i++)
      rows.push({ slot: (a[i] || h[i]).slot, away: a[i] || null, home: h[i] || null })
    return rows
  }

  function benchRows(m) {
    if (!m) return []
    function bench(side) {
      var out = []
      var r = (side && side.roster) ? side.roster : []
      for (var i = 0; i < r.length; i++) if (!r[i].starter) out.push(r[i])
      return out
    }
    var a = bench(m.away), h = bench(m.home)
    var rows = []
    for (var i = 0; i < Math.max(a.length, h.length); i++)
      rows.push({ slot: "BE", away: a[i] || null, home: h[i] || null })
    return rows
  }

  // A player's real game, said briefly. ESPN's shortDetail is already terse
  // for live games ("9:11 - 2nd") but verbose pregame ("9/13 - 1:00 PM EDT").
  function gameLabel(p) {
    if (!p) return ""
    var d = String(p.detail || "")
    if (p.state === "post") return "Final"
    if (p.state === "in") return d
    var m = d.match(/([0-9]{1,2}\/[0-9]{1,2}).*?([0-9]{1,2}:[0-9]{2})/)
    if (m) return m[1] + " " + m[2]
    return d
  }

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
    // The box score needs room for two rosters; the league list does not.
    contentWidth: card.fittedContentWidth(root.selected ? Style.space(700) : Style.space(470))
    contentHeight: card.fittedContentHeight(body.implicitHeight, Style.space(640))

    Column {
      id: body
      width: parent.width
      spacing: Style.space(10)

      // ================================================== league list header
      Item {
        visible: !root.selected
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

      // ======================================================= detail header
      Item {
        visible: !!root.selected
        width: parent.width
        implicitHeight: backRow.implicitHeight + Style.space(30)

        Item {
          id: backRow
          width: parent.width
          implicitHeight: Style.space(16)

          Text {
            id: backLink
            anchors.left: parent.left
            text: "‹ Back"
            color: backHover.hovered ? Color.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
            HoverHandler { id: backHover }
            TapHandler { onTapped: root.back() }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.league ? ("Week " + root.league.week) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.space(11)
          }

          Text {
            anchors.right: parent.right
            text: "FantasyCast ›"
            color: castHover2.hovered ? Color.accent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.space(12)
            font.underline: castHover2.hovered
            HoverHandler { id: castHover2 }
            TapHandler { onTapped: root.openUrl(root.leagueUrl) }
          }
        }

        // Both teams and the score, mirrored around the centre so each half
        // reads outward from the matchup the way a box score does.
        Item {
          anchors.top: backRow.bottom
          anchors.topMargin: Style.space(10)
          width: parent.width
          implicitHeight: Style.space(20)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: (parent.width - Style.space(150)) / 2
            text: root.selected ? root.selected.away.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.space(14)
            font.weight: Font.DemiBold
            elide: Text.ElideRight
          }

          Text {
            anchors.centerIn: parent
            width: Style.space(150)
            horizontalAlignment: Text.AlignHCenter
            text: root.selected
              ? root.fmt(root.selected.away.points) + "  —  " + root.fmt(root.selected.home.points)
              : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.space(14)
            font.weight: Font.DemiBold
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: (parent.width - Style.space(150)) / 2
            horizontalAlignment: Text.AlignRight
            text: root.selected ? root.selected.home.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.space(14)
            font.weight: Font.DemiBold
            elide: Text.ElideRight
          }
        }
      }

      PanelSeparator { width: parent.width }

      // =============================================================== error
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

      // ========================================================= league list
      Repeater {
        model: root.selected ? [] : root.matchups

        delegate: Rectangle {
          id: game
          required property var modelData
          readonly property var away: modelData.away
          readonly property var home: modelData.home

          width: body.width
          implicitHeight: rows.implicitHeight + Style.space(16)
          radius: Style.space(6)
          color: gameHover.hovered ? Style.selectedFillFor(root.foreground, Color.accent)
                                   : (modelData.mine ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
                                                     : "transparent")
          border.width: modelData.mine ? 1 : 0
          border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

          HoverHandler { id: gameHover }
          TapHandler { onTapped: root.selectMatchup(game.modelData) }

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
                  id: teamName
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(Style.space(60),
                                  parent.width - Style.space(94) - status.width - Style.space(10))
                  text: modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(13)
                  font.weight: parent.leading ? Font.DemiBold : Font.Normal
                  elide: Text.ElideRight
                }

                // Per team, not per matchup: a combined "3 playing" cannot say
                // whether it is you or your opponent who still has a roster
                // left to come, which is the whole question.
                Text {
                  id: status
                  anchors.left: teamName.right
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(11)
                  text: {
                    var parts = []
                    if (modelData.playing > 0) parts.push(modelData.playing + " playing")
                    if (modelData.yetToPlay > 0) parts.push(modelData.yetToPlay + " to play")
                    if (parts.length === 0) parts.push("all done")
                    return parts.join(" · ")
                  }
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
              text: {
                var left = Math.max(game.away.minutesLeft, game.home.minutesLeft)
                return left > 0 ? root.clock(left) + " of clock left" : "final"
              }
            }
          }
        }
      }

      // ================================================== matchup box score
      Repeater {
        model: root.selected ? root.boxRows(root.selected) : []

        delegate: Item {
          required property var modelData
          readonly property bool isHeader: !!modelData.header

          width: body.width
          implicitHeight: isHeader ? Style.space(22) : Style.space(19)

          // Section break between the starters and the bench.
          Text {
            visible: parent.isHeader
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            text: modelData.header || ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.space(10)
            font.weight: Font.DemiBold
          }

          Rectangle {
            visible: parent.isHeader
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            width: parent.width - Style.space(46)
            height: 1
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          }

          Item {
            visible: !parent.isHeader
            anchors.fill: parent

            // The lineup slot is the spine: both rosters mirror outward from
            // it, so the two numbers being compared sit side by side.
            Text {
              id: slotLabel
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(52)
              horizontalAlignment: Text.AlignHCenter
              text: modelData.slot || ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(10)
            }

            // ---------------------------------------------------- away side
            Text {
              id: awayPts
              anchors.right: slotLabel.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(42)
              horizontalAlignment: Text.AlignRight
              text: modelData.away ? root.fmt(modelData.away.points) : ""
              color: root.playerColor(modelData.away)
              font.family: root.fontFamily
              font.pixelSize: Style.space(12)
              font.weight: modelData.away && modelData.away.state === "in" ? Font.DemiBold : Font.Normal
            }

            Text {
              id: awayProj
              anchors.right: awayPts.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(40)
              horizontalAlignment: Text.AlignRight
              text: modelData.away ? root.fmt(modelData.away.projected) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(10)
            }

            Column {
              anchors.left: parent.left
              anchors.right: awayProj.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                width: parent.width
                text: modelData.away ? modelData.away.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.space(12)
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                text: modelData.away ? root.playerNote(modelData.away) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.space(9)
                elide: Text.ElideRight
              }
            }

            // ---------------------------------------------------- home side
            Text {
              id: homePts
              anchors.left: slotLabel.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(42)
              horizontalAlignment: Text.AlignLeft
              text: modelData.home ? root.fmt(modelData.home.points) : ""
              color: root.playerColor(modelData.home)
              font.family: root.fontFamily
              font.pixelSize: Style.space(12)
              font.weight: modelData.home && modelData.home.state === "in" ? Font.DemiBold : Font.Normal
            }

            Text {
              id: homeProj
              anchors.left: homePts.right
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(40)
              horizontalAlignment: Text.AlignLeft
              text: modelData.home ? root.fmt(modelData.home.projected) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.space(10)
            }

            Column {
              anchors.left: homeProj.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: 0

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: modelData.home ? modelData.home.name : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.space(12)
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: modelData.home ? root.playerNote(modelData.home) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.space(9)
                elide: Text.ElideRight
              }
            }
          }
        }
      }

      PanelSeparator { width: parent.width; visible: root.matchups.length > 0 }

      // ============================================================== footer
      Item {
        width: parent.width
        implicitHeight: Style.space(20)

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          visible: !root.selected
          text: "Open FantasyCast"
          color: castHover.hovered ? Color.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.space(12)
          font.underline: castHover.hovered

          HoverHandler { id: castHover }
          TapHandler { onTapped: root.openUrl(root.leagueUrl) }
        }

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          visible: !!root.selected
          text: "Open box score on ESPN"
          color: boxHover.hovered ? Color.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.space(12)
          font.underline: boxHover.hovered

          HoverHandler { id: boxHover }
          TapHandler { onTapped: root.openUrl(root.selected ? root.selected.url : "") }
        }

        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: root.selected ? (root.record && root.record.updatedAt ? root.ago(root.record.updatedAt) : "")
                              : "click a matchup for its box score"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.space(10)
        }
      }
    }
  }

  // Starters, then a Bench header, then the bench — one flat model so the
  // whole box score is a single Repeater rather than three that have to be
  // kept in step.
  function boxRows(m) {
    var out = []
    var s = starterRows(m)
    for (var i = 0; i < s.length; i++) out.push(s[i])
    var b = benchRows(m)
    if (b.length > 0) {
      out.push({ header: "BENCH" })
      for (var j = 0; j < b.length; j++) out.push(b[j])
    }
    return out
  }

  // Live players carry the accent, finished ones read normally, and anyone
  // yet to kick off stays dim — so a glance down the column says who is
  // still capable of changing the score.
  function playerColor(p) {
    if (!p) return root.dim
    if (p.state === "in") return Color.accent
    if (p.state === "post") return root.foreground
    return root.dim
  }

  function playerNote(p) {
    if (!p) return ""
    var bits = []
    if (p.proTeam) bits.push(p.proTeam)
    var g = root.gameLabel(p)
    if (g) bits.push(g)
    if (p.injury && p.injury !== "ACTIVE" && p.injury !== "NORMAL")
      bits.push(String(p.injury).slice(0, 3))
    return bits.join(" · ")
  }
}
