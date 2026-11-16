import Foundation

/// jq helpers shared by Claude Code and Antigravity's generated status lines.
enum StatusLineRendering {
    static let jq = #"""
      def color($percent; $tone):
        if $tone == "green" then "32" elif $tone == "amber" then "33"
        elif $tone == "red" then "31"
        elif $percent >= 40 then "32" elif $percent >= 10 then "33" else "31" end;
      def countdown($reset):
        if $reset == null or $reset <= $now then null else
          (($reset - $now) | ceil) as $s
          | if $s < 3600 then ((($s / 60) | ceil) | tostring) + "m"
            elif $s < 86400 then (($s / 3600 | floor) | tostring) + "h"
              + (if ($s % 3600) >= 60 then ((($s % 3600) / 60 | floor) | tostring) + "m" else "" end)
            else (($s / 86400 | floor) | tostring) + "d"
              + (if ($s % 86400) >= 3600 then ((($s % 86400) / 3600 | floor) | tostring) + "h" else "" end)
            end end;
      def fresh($item):
        $item != null
             and ($item.writtenAt | type) == "number"
             and $item.writtenAt <= $now and $now - $item.writtenAt < 1800
             and ($item.resetAt | type) == "number"
             and (["green", "amber", "red"] | index($item.tone)) != null
             and ($item.idealPercent | type) == "number";
      def pace($key; $reset):
        ($pace | try fromjson catch {}) as $file
        | ($file.windows[$key] // null) as $item
        | if $reset != null and fresh($item)
             and (($item.resetAt - $reset) | fabs) <= 300
          then $item else null end;
      def model_pace($key):
        ($pace | try fromjson catch {}) as $file
        | ($file.windows[$key] // null) as $item
        | if fresh($item) and $item.resetAt > $now
             and ($item.remainingPercent | type) == "number"
             and $item.remainingPercent >= 0 and $item.remainingPercent <= 100
          then $item else null end;
      def ideal($reset; $entry):
        if $entry != null then $entry.idealPercent
        elif $reset != null and $reset > $now and $reset - $now <= 6 * 86400
          then (100 * ($reset - $now) / (7 * 86400))
        else null end;
      def bar($filled; $marker; $color):
        if $marker == null then
          (if $filled > 0 then "\u001b[" + $color + "m" + ("█" * $filled) + "\u001b[0m" else "" end)
          + (if $filled < 10 then "\u001b[2m" + ("░" * (10 - $filled)) + "\u001b[0m" else "" end)
        else
          [range(0; 10) | if . == $marker then "\u001b[1;97m│\u001b[0m"
            elif . < $filled then "\u001b[" + $color + "m█\u001b[0m"
            else "\u001b[2m░\u001b[0m" end] | join("")
        end;
      def plain($mode):
        .label + " " + (if $mode == "percent" then "" else "██████████ " end)
        + (.percent | tostring) + "%"
        + (if $mode == "full" and .countdown != null then " " + .countdown else "" end)
        + (if .note != null then " " + .note else "" end);
      def display($mode):
        . as $w | color(.percent; .tone) as $c
        | .label + " "
          + (if $mode == "percent" then "" else bar(.filled; .marker; $c) + " " end)
          + "\u001b[" + $c + "m" + (.percent | tostring) + "%\u001b[0m"
          + (if $mode == "full" and .countdown != null then " " + .countdown else "" end)
          + (if .note != null then " " + .note else "" end);
      def render($windows; $prefix; $width):
        ($prefix + ([$windows[] | plain("full")] | join("  ·  ")) | length) as $full
        | ($prefix + ([$windows[] | plain("bars")] | join("  ·  ")) | length) as $bars
        | (if $width == null or $width >= $full then "full"
           elif $width >= $bars then "bars" else "percent" end) as $mode
        | $prefix + ([$windows[] | display($mode)] | join("  ·  "));
    """#
}
