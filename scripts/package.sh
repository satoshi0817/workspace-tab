#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

task_app="$PWD/build/Workspace Tabs.app"
if [ ! -d "$task_app" ]; then
    echo "Build the app first: bash scripts/build.sh" >&2
    exit 1
fi
codesign --verify --deep --strict "$task_app"
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_app/Contents/Info.plist")"
task_archs="$(lipo -archs "$task_app/Contents/MacOS/WorkspaceTabs")"
case "$task_archs" in
    arm64) task_platform="arm64" ;;
    x86_64) task_platform="x86_64" ;;
    *arm64*x86_64*|*x86_64*arm64*) task_platform="universal" ;;
    *) echo "Unsupported architectures: $task_archs" >&2; exit 1 ;;
esac
task_output="$PWD/build/release"
task_name="Workspace-Tabs-$task_version-$task_platform.dmg"
task_stage="$(mktemp -d "${TMPDIR:-/tmp}/workspace-tabs-package.XXXXXX")"
trap 'rm -rf "$task_stage"' EXIT
mkdir -p "$task_output"
ditto "$task_app" "$task_stage/Workspace Tabs.app"
ln -s /Applications "$task_stage/Applications"
cp LICENSE THIRD_PARTY_NOTICES.md "$task_stage/"
hdiutil create -volname "Workspace Tabs" -srcfolder "$task_stage" -format UDZO -ov "$task_output/$task_name"
(cd "$task_output" && shasum -a 256 "$task_name" > "$task_name.sha256")
printf 'Packaged: %s\n' "$task_output/$task_name"
