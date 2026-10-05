#!/bin/zsh
# Renders the app icons (Resources/Assets.xcassets) from the avatar's own
# shader and motion model: AppIcon is the default theme (洋红), AppIcon-<key>
# the alternate icons that follow 设置 → 主题色. Keep the colors in sync with
# AppTheme (theme color : partner color).
#
#   ios/App/scripts/make_icons.sh
set -e
here=${0:A:h}
src=$here/../Sources/Support
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
xcrun -sdk macosx metal -DTWODROPS_OFFLINE -O2 -c $src/TwoDrops.metal -o $tmp/td.air
xcrun -sdk macosx metallib $tmp/td.air -o $tmp/td.metallib
swiftc -O $here/icons/main.swift $src/TwoDropsState.swift -o $tmp/icons
$tmp/icons $tmp/td.metallib $here/../Resources/Assets.xcassets \
  AppIcon:#D156A7:#8B6BFF \
  AppIcon-orchid:#A84FD0:#F0609E \
  AppIcon-rose:#DE4A7C:#FFB547 \
  AppIcon-berry:#A3307F:#FF7A5C \
  AppIcon-blue:#2F6FE0:#2FD3C6 \
  AppIcon-violet:#6E4BD8:#FF6FB5 \
  AppIcon-teal:#0F8F84:#C6E04A \
  AppIcon-orange:#EC7355:#FFC93D \
  AppIcon-graphite:#4A5260:#8EC5FF
