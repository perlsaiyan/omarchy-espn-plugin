# Diffs the freshly written scoreboard against the previous one and emits the
# notifications worth interrupting someone for. Silence is the default: a
# refresh that changed nothing prints nothing.
#
# Input: the new record.  Args: $prev (previous record), $teamId, $minDelta

def sideOf($m; $id): if $m.home.teamId == $id then $m.home else $m.away end;
def foeOf($m; $id):  if $m.home.teamId == $id then $m.away else $m.home end;

($prev[0] // {}) as $old

| [ .matchups[]? | select(.home.teamId == $teamId or .away.teamId == $teamId) ] as $now
| (if ($now | length) == 0 then empty else $now[0] end) as $m
| [ ($old.matchups // [])[] | select(.home.teamId == $teamId or .away.teamId == $teamId) ] as $was
| (if ($was | length) == 0 then null else $was[0] end) as $p

# Nothing to compare against on the very first run: say nothing rather than
# announcing the whole scoreboard as though it had just happened.
| if $p == null then empty else

  sideOf($m; $teamId) as $me
  | foeOf($m; $teamId) as $foe
  | sideOf($p; $teamId) as $meWas
  | foeOf($p; $teamId) as $foeWas

  | ($me.points - $meWas.points) as $myDelta
  | ($foe.points - $foeWas.points) as $foeDelta
  | ($meWas.points > $foeWas.points) as $wasAhead
  | ($me.points > $foe.points) as $isAhead

  | "\($me.name) \($me.points | . * 10 | round / 10) — \($foe.points | . * 10 | round / 10) \($foe.name)" as $line
  | (if $me.playing + $foe.playing > 0
     then "  ·  \($me.playing + $foe.playing) on the field"
     else "" end) as $tail

  | (($wasAhead != $isAhead) and (($myDelta | fabs) + ($foeDelta | fabs)) > 0) as $leadChanged

  | [
      # A lead change is the only thing that reliably matters, so it gets its
      # own notification rather than replacing the running ticker.
      (if $leadChanged
       then {
         id: 90101,
         urgency: "critical",
         headline: (if $isAhead then "You took the lead" else "You lost the lead" end),
         body: ($line + $tail),
         url: $m.url
       }
       else empty end),

      # Otherwise a quiet running score, coalesced onto one replaceable
      # notification so a busy Sunday does not bury the rest of the desktop.
      # Skipped when the lead just changed, which already said it louder.
      (if ($leadChanged | not) and ($myDelta >= $minDelta or $foeDelta >= $minDelta)
       then {
         id: 90102,
         urgency: "low",
         headline: (if $myDelta >= $minDelta
                    then "\($me.name) +\($myDelta | . * 10 | round / 10)"
                    else "\($foe.name) +\($foeDelta | . * 10 | round / 10)" end),
         body: ($line + $tail),
         url: $m.url
       }
       else empty end)
    ]
  | .[]
end
