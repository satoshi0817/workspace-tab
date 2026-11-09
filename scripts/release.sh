#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${WORKSPACE_TABS_SIGN_IDENTITY:?Set WORKSPACE_TABS_SIGN_IDENTITY to a Developer ID Application identity}"
: "${WORKSPACE_TABS_NOTARY_PROFILE:?Set WORKSPACE_TABS_NOTARY_PROFILE to a notarytool keychain profile}"

WORKSPACE_TABS_RELEASE=1 WORKSPACE_TABS_UNIVERSAL=1 bash scripts/build.sh
task_app="$PWD/build/Workspace Tabs.app"
task_dir="$(mktemp -d "${TMPDIR:-/tmp}/workspace-tabs-notary.XXXXXX")"
task_zip="$task_dir/Workspace-Tabs.zip"
trap 'rm -f "$task_zip"; rmdir "$task_dir"' EXIT
ditto -c -k --keepParent "$task_app" "$task_zip"
xcrun notarytool submit "$task_zip" --keychain-profile "$WORKSPACE_TABS_NOTARY_PROFILE" --wait
xcrun stapler staple "$task_app"
xcrun stapler validate "$task_app"

bash scripts/package.sh
task_dmg="$PWD/build/release/Workspace-Tabs-1.0.0-universal.dmg"
xcrun notarytool submit "$task_dmg" --keychain-profile "$WORKSPACE_TABS_NOTARY_PROFILE" --wait
xcrun stapler staple "$task_dmg"
xcrun stapler validate "$task_dmg"
spctl --assess --type execute --verbose "$task_app"
task_output="$(dirname "$task_dmg")"
task_name="$(basename "$task_dmg")"
(cd "$task_output" && shasum -a 256 "$task_name" > "$task_name.sha256")
printf 'Ready for GitHub Release: %s\n' "$task_dmg"
