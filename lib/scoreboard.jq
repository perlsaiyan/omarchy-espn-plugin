# Folds ESPN's fantasy league payload and the NFL pro scoreboard into the one
# flat record the QML panel draws.
#
# Inputs:  the league mScoreboard payload on stdin
# Args:    $nfl (site.api NFL scoreboard), $leagueId, $week, $myTeamId

def proTeams: {
  "1":"ATL","2":"BUF","3":"CHI","4":"CIN","5":"CLE","6":"DAL","7":"DEN","8":"DET",
  "9":"GB","10":"TEN","11":"IND","12":"KC","13":"LV","14":"LAR","15":"MIA","16":"MIN",
  "17":"NE","18":"NO","19":"NYG","20":"NYJ","21":"PHI","22":"ARI","23":"PIT","24":"LAC",
  "25":"SF","26":"SEA","27":"TB","28":"WSH","29":"CAR","30":"JAX","33":"BAL","34":"HOU"
};

# Bench (20) and IR (21) do not score. Everything else is a starter.
def isStarter: (.lineupSlotId != 20 and .lineupSlotId != 21);

# ESPN keeps a week's running score in totalPointsLive and only moves it into
# totalPoints once the week is finalized — mid-week, totalPoints reads 0.0
# while the team is plainly scoring. Prefer whichever field is actually
# carrying the number, so live and final weeks both come out right.
def livePoints($s; $week):
  ($s.totalPointsLive // 0) as $live
  | ((($s.pointsByScoringPeriod // {})[$week | tostring]) // 0) as $byPeriod
  | ($s.totalPoints // 0) as $total
  | if $live != 0 then $live
    elif $byPeriod != 0 then $byPeriod
    else $total end;

# One entry per pro team: what its NFL game is doing right now.
#   state: "pre" | "in" | "post"
#   left:  minutes of game clock still to be played
def gameStates:
  reduce ($nfl[0].events[]? ) as $e ({};
    ($e.status.type.state // "pre") as $state
    | ($e.status.period // 0) as $period
    | (($e.status.displayClock // "15:00")
        | split(":") | (( .[0] // "0" |tonumber) + ((.[1] // "0"|tonumber) / 60))) as $clock
    | (if $state == "post" then 0
       elif $state == "pre" then 60
       # Regulation only: OT is a rounding error against a 60-minute baseline.
       else (([4 - $period, 0] | max) * 15) + $clock end) as $left
    | reduce ($e.competitions[0].competitors[]?) as $c (.;
        .[$c.team.abbreviation // ""] = {
          state: $state,
          left: $left,
          detail: ($e.status.type.shortDetail // ""),
          opponent: ($e.shortName // "")
        })
  );

gameStates as $games

# Team metadata, keyed by id, so each matchup side can be named and ranked.
| (reduce (.teams[]?) as $t ({};
    .[$t.id|tostring] = {
      name: ($t.name // ((($t.location // "") + " " + ($t.nickname // ""))|ltrimstr(" "))),
      abbrev: ($t.abbrev // ""),
      logo: ($t.logo // ""),
      wins: ($t.record.overall.wins // 0),
      losses: ($t.record.overall.losses // 0),
      ties: ($t.record.overall.ties // 0)
    })) as $teams

| (.settings.name // "Fantasy League") as $leagueName
| (.seasonId // 0) as $season

# Roll one side of a matchup up from its starters.
| def side($s):
    ($s.teamId // 0) as $id
    | ($teams[$id|tostring] // {name:"Team \($id)", abbrev:"", logo:"", wins:0, losses:0, ties:0}) as $meta
    | [ $s.rosterForCurrentScoringPeriod.entries[]? | select(isStarter) ] as $starters
    | [ $starters[]
        | (proTeams[(.playerPoolEntry.player.proTeamId // 0)|tostring] // "") as $abbr
        | ($games[$abbr] // {state:"pre", left:60, detail:"", opponent:""}) as $g
        | {
            name: (.playerPoolEntry.player.fullName // "?"),
            proTeam: $abbr,
            state: $g.state,
            left: $g.left,
            # statSourceId 0 is what actually happened, 1 is the projection.
            points: ([ .playerPoolEntry.player.stats[]?
                       | select(.statSourceId == 0 and .scoringPeriodId == $week)
                       | .appliedTotal ] | first // 0)
          } ] as $players
    | {
        teamId: $id,
        name: $meta.name,
        abbrev: $meta.abbrev,
        logo: $meta.logo,
        record: "\($meta.wins)-\($meta.losses)" + (if $meta.ties > 0 then "-\($meta.ties)" else "" end),
        points: livePoints($s; $week),
        projected: ($s.totalProjectedPointsLive // $s.totalPoints // 0),
        winProbability: ($s.winProbability // null),
        playing: ([ $players[] | select(.state == "in") ] | length),
        yetToPlay: ([ $players[] | select(.state == "pre") ] | length),
        done: ([ $players[] | select(.state == "post") ] | length),
        # Minutes of real football still standing between this roster and a
        # final score. It is the honest version of "how much time is left".
        minutesLeft: ([ $players[] | .left ] | add // 0 | round)
      };

{
  schemaVersion: 1,
  updatedAt: (now | todate),
  league: {
    id: $leagueId,
    name: $leagueName,
    season: $season,
    week: $week,
    url: "https://fantasy.espn.com/football/fantasycast?leagueId=\($leagueId)"
  },
  myTeamId: (if $myTeamId == 0 then null else $myTeamId end),
  matchups: [
    .schedule[]?
    | select((.matchupPeriodId // 0) == $week)
    | side(.home) as $home
    | side(.away) as $away
    | {
        id: (.id // 0),
        winner: (.winner // "UNDECIDED"),
        home: $home,
        away: $away,
        mine: (($home.teamId == $myTeamId) or ($away.teamId == $myTeamId)),
        # ESPN opens the box score from one side's point of view, so point it
        # at your own team when this is your matchup.
        url: (if ($home.teamId == $myTeamId) or ($away.teamId == $myTeamId)
              then "https://fantasy.espn.com/football/boxscore?leagueId=\($leagueId)&matchupPeriodId=\($week)&scoringPeriodId=\($week)&teamId=\($myTeamId)"
              else "https://fantasy.espn.com/football/boxscore?leagueId=\($leagueId)&matchupPeriodId=\($week)&scoringPeriodId=\($week)&teamId=\($home.teamId)"
              end)
      }
  ]
  # Your own matchup sorts to the top; the rest keep ESPN's order.
  | sort_by(if .mine then 0 else 1 end)
}
