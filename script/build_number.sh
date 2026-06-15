#!/usr/bin/env bash
# Monotonic CFBundleVersion from a semver string: major*1_000_000 + minor*1_000 + patch.
#
# The old `tr -d '.'` scheme was non-monotonic: 2.0 → 20 but 1.10 → 110, so Sparkle
# (which compares CFBundleVersion numerically) thought 1.10 was newer than 2.0 and
# offered it as a "downgrade update". This formula keeps build numbers strictly
# increasing with semantic version, and every value (>= 1_000_000) is larger than
# anything the old scheme produced, so the transition is forward-safe.
#
# Usage: build_number.sh 1.10   → 1010000
set -euo pipefail
IFS=. read -r maj min pat <<< "${1:-0}"
echo $(( ${maj:-0} * 1000000 + ${min:-0} * 1000 + ${pat:-0} ))
