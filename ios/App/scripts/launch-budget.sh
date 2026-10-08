#!/bin/zsh
# The chat's launch budgets (design §6) on an iPhone simulator: builds the
# app, launches the long demo conversation (nothing streaming) a few times and prints, per
# launch, how long after the process started the conversation was laid out
# and the memory footprint 5 s later, then the medians.
#
#   ios/App/scripts/launch-budget.sh [simulator name] [launches] [extra app arguments]
#
# One simulator and one build at a time; the simulator is shut down after.
set -u
here=${0:A:h}
sim=${1:-iPhone 17}
runs=${2:-5}
extra=(${=3:-})
dd=${DERIVED_DATA:-${TMPDIR:-/tmp}/paloally-stress-dd}
udid=$(xcrun simctl list devices available | grep -F "    $sim (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$udid" ] || { echo "no simulator named $sim"; exit 1; }

xcodebuild build -project "$here/../PaloAlly.xcodeproj" -scheme PaloAlly \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$dd" -quiet 2>&1 | grep -E "error:" | head -5
app="$dd/Build/Products/Debug-iphonesimulator/PaloAlly.app"
[ -d "$app" ] || { echo "no app at $app"; exit 1; }

xcrun simctl boot "$udid" 2>/dev/null
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
launches=() mems=()
for i in $(seq 1 $runs); do
  xcrun simctl terminate "$udid" com.novashang.paloally 2>/dev/null
  sleep 2
  xcrun simctl launch "$udid" com.novashang.paloally -demo YES -demoState long -demoStreamDelay 600 $extra >/dev/null
  sleep 9
  log="$(xcrun simctl get_app_container "$udid" com.novashang.paloally data)/Documents/debug.log"
  l=$(grep -F '[launch]' "$log" | tail -1)
  m=$(grep -F '[mem] footprint' "$log" | tail -1)
  echo "run $i: ${l#*\] \[*\] } | ${m#*\] \[*\] }"
  launches+=$(echo "$l" | sed -nE 's/.*laid out ([0-9]+) ms.*/\1/p')
  mems+=$(echo "$m" | sed -nE 's/.*footprint ([0-9]+) MB.*/\1/p')
done
xcrun simctl terminate "$udid" com.novashang.paloally 2>/dev/null
median() { print -l "$@" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}' }
echo "median: conversation laid out $(median $launches) ms after start, footprint $(median $mems) MB"
xcrun simctl shutdown "$udid"
