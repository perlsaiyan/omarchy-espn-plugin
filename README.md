# ESPN Fantasy for Omarchy

A football in the Omarchy bar. Hover it for every matchup in your league:
score, ESPN's own win probability, how many players are on the field right
now, and how much game clock is left before the week is decided. Click a
matchup for its box score, or the footer for FantasyCast.

Optionally it notifies you when your own matchup moves.

Built for Omarchy 4.x (Quattro shell plugins).

## Install

```bash
git clone <this-repo> ~/git/omarchy-espn-plugin
ln -s ~/git/omarchy-espn-plugin ~/.config/omarchy/plugins/espn.fantasy

install -m 600 ~/git/omarchy-espn-plugin/example.env ~/.config/omarchy/espn-fantasy.env
$EDITOR ~/.config/omarchy/espn-fantasy.env      # set LEAGUE_ID and TEAM_ID

omarchy plugin enable espn.fantasy --section right
```

Note that the shell watches `~/.config/omarchy/plugins/` for changes, but it
does not follow the symlink out to the repo — after editing the QML, use
`omarchy restart shell` rather than waiting for a hot reload.

## Configuration

Everything lives in `~/.config/omarchy/espn-fantasy.env`:

| Variable | Required | Meaning |
|---|---|---|
| `LEAGUE_ID` | yes | The number in your league URL |
| `TEAM_ID` | for notifications | Your team, so it can be highlighted and watched |
| `SEASON` | no | Defaults to the current season (rolls over in March) |
| `ESPN_S2`, `SWID` | private leagues only | Auth cookies |
| `NOTIFY` | no | `0` disables desktop notifications |
| `NOTIFY_MIN_DELTA` | no | Points a score must move to notify (default `0.1`) |

Widget settings — refresh interval, hover behaviour — are in the manifest and
adjustable through the Omarchy settings panel.

### Public vs. private leagues

A public league needs no credentials at all, and the plugin deliberately sends
no cookies when `ESPN_S2`/`SWID` are empty. Check yours:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/2026/segments/0/leagues/1234567?view=mSettings"
```

`200` is public. `401`/`403` is private: open a logged-in espn.com tab,
DevTools → Application → Cookies, and copy `espn_s2` and `SWID` into the env
file. They expire roughly annually — when the widget starts showing an `auth`
error, that is what happened.

## Finding your `TEAM_ID`

```bash
curl -s "https://lm-api-reads.fantasy.espn.com/apis/v3/games/ffl/seasons/2026/segments/0/leagues/1234567?view=mTeam" \
  | jq -r '.teams[] | "\(.id)\t\(.name)"'
```

## How it works

The QML is a pure display. All the network and parsing lives in a shell
script, which means you can test and debug the whole data path without
touching the shell:

```
bin/omarchy-espn-update     fetches, folds, writes the record, notifies
lib/scoreboard.jq           ESPN payload + NFL clocks -> the record
lib/notify.jq               diffs consecutive records -> notifications
BarWidget.qml               the bar slot; draws the football, owns hover
Panel.qml                   reads the record, draws the scoreboard
```

The record lands in `~/.local/state/omarchy/espn/scoreboard.json`, with the
previous one kept alongside it for diffing. `Panel.qml` watches that file, so
anything that writes it repaints the panel — run the collector by hand and the
bar updates:

```bash
./bin/omarchy-espn-update
```

Two ESPN endpoints feed it. The league itself comes from the undocumented
fantasy v3 API (`lm-api-reads.fantasy.espn.com`), which carries scores,
projections and `winProbability`. Live game state — quarter, clock, whether a
player's real-life game has kicked off — comes from the public NFL scoreboard
(`site.api.espn.com`), joined on the pro team abbreviation. If that second
call fails the plugin degrades to treating every game as not-yet-started
rather than failing the refresh.

"Minutes left" is the sum of regulation clock remaining across a roster's
starters, which is why a full slate reads as 9h rather than 60 minutes: nine
starters with untouched games are nine separate hours of football.

## Notifications

With `TEAM_ID` set, each refresh diffs against the previous record and sends at
most one notification:

- **Lead change** in your matchup — urgency `critical`, its own notification.
- **Score change** otherwise — urgency `low`, coalesced onto a single
  replaceable notification so a busy Sunday does not bury the desktop.

Clicking either opens your box score. The first run after a restart never
notifies; with nothing to compare against it would announce the whole week as
though it had just happened.

## Caveats

- The fantasy API is undocumented and unversioned. It has changed before and
  can change again.
- "Yet to play" infers kickoff from whether ESPN has published an actual
  (non-projected) stat line for the player, which flips shortly after their
  game starts rather than exactly at kickoff.
- Overtime is counted as zero remaining clock.

## License

MIT
