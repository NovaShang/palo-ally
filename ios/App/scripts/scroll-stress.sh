#!/bin/zsh
# Flings the conversation on an iPhone simulator while replies stream in and
# catch-ups insert messages (ScrollStressUITests against `-demoState stress`),
# then prints the app's stall and jump lines from its debug.log.
#
#   ios/App/scripts/scroll-stress.sh [simulator name] [extra app arguments]
#   ios/App/scripts/scroll-stress.sh "iPhone 17" "-readingAnchor NO"   # without the reading anchor
#
# One simulator and one build at a time; the simulator is shut down after.
set -u
here=${0:A:h}
sim=${1:-iPhone 17}
extra=${2:-}
dd=${DERIVED_DATA:-${TMPDIR:-/tmp}/paloally-stress-dd}
udid=$(xcrun simctl list devices available | grep -F "    $sim (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$udid" ] || { echo "no simulator named $sim"; exit 1; }

xcrun simctl boot "$udid" 2>/dev/null
xcrun simctl bootstatus "$udid" -b >/dev/null
TEST_RUNNER_STRESS_ARGS="-stallThresholdMs 250 $extra" \
  xcodebuild test -project "$here/../PaloAlly.xcodeproj" -scheme PaloAlly \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$dd" \
    -only-testing:PaloAllyUITests/ScrollStressUITests -quiet 2>&1 | tail -25
result=${pipestatus[1]}

data=$(xcrun simctl get_app_container "$udid" com.novashang.paloally data 2>/dev/null)
echo "--- debug.log: stalls and jumps"
grep -E '\[stall\]|\[jump\]' "$data/Documents/debug.log" | tail -60
xcrun simctl shutdown "$udid"
exit $result
