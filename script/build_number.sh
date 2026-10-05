#!/usr/bin/env bash
# Monotonic CFBundleVersion from a semver string, pre-releases included.
#
#   major * 100_000_000 + minor * 100_000 + patch * 1_000
#
# and a pre-release sits just UNDER the final it leads to: final - 1000 + N.
# That ordering is what makes two release tracks work at once:
#
#   2.23          202_300_000   what a stable user has
#   2.24          202_400_000   what a stable user gets next
#   3.0-beta.1    299_999_001   what a beta user gets
#   3.0-beta.2    299_999_002
#   3.0           300_000_000   where both end up
#
# A beta user is above 2.24, so a stable release can never be offered to them as
# an update; they only move forward, through the betas, into the final. Betas
# run to .999, which the script refuses to exceed rather than silently wrap.
#
# The scale is 1000x the old one (2.23 was 2_023_000), so every number this
# prints is larger than anything the previous scheme produced — Sparkle compares
# CFBundleVersion numerically, and the transition has to be forward-safe.
#
# Versions are major.minor, pre-releases "-beta.N" ("3.0-beta.4"); a third component is accepted
# (the first betas were tagged 3.0.0-beta.N) and gives the same number.
#
# Usage: build_number.sh 1.10        → 101_000_000
#        build_number.sh 3.0-beta.1  → 299_999_001
set -euo pipefail

VERSION="${1:-0}"
BASE="${VERSION%%-*}"
PRE="${VERSION#"$BASE"}"; PRE="${PRE#-}"

IFS=. read -r maj min pat <<< "$BASE"
BUILD=$(( ${maj:-0} * 100000000 + ${min:-0} * 100000 + ${pat:-0} * 1000 ))

if [ -n "$PRE" ]; then
  N="${PRE##*.}"
  case "$N" in
    ''|*[!0-9]*) echo "pre-release must end in a number: $PRE" >&2; exit 1 ;;
  esac
  [ "$N" -ge 1 ] && [ "$N" -lt 1000 ] || { echo "pre-release number out of range: $PRE" >&2; exit 1; }
  BUILD=$(( BUILD - 1000 + N ))
fi

echo "$BUILD"
