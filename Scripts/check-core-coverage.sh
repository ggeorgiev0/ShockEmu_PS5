#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
SHOCKEMU_CORE_COVERAGE=1 swift test --enable-code-coverage -q
bin="$(swift build --show-bin-path)"
test_binary="$bin/ShockEmuPackageTests.xctest/Contents/MacOS/ShockEmuPackageTests"
profile="$bin/codecov/default.profdata"
report="$(xcrun llvm-cov report "$test_binary" \
  -instr-profile="$profile" \
  Sources/ShockEmuCore/SEProfile.m \
  Sources/ShockEmuCore/SEInputEngine.m \
  Sources/ShockEmuCore/SEModifierState.m \
  Sources/ShockEmuCore/SEReports.m)"
print -r -- "$report"
line_coverage="$(print -r -- "$report" | /usr/bin/awk '/^TOTAL/ {gsub(/%/, "", $10); print $10}')"
if ! /usr/bin/awk -v coverage="$line_coverage" 'BEGIN { exit !(coverage >= 80) }'; then
  print -u2 -- "ShockEmuCore line coverage is ${line_coverage}%; expected at least 80%."
  exit 1
fi
