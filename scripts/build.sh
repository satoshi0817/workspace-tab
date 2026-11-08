#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_scratch="${WORKSPACE_TABS_BUILD_DIR:-/tmp/workspace-tabs-build}"
rtk proxy swift build -c release --scratch-path "$task_scratch"
task_bin="$(rtk proxy swift build -c release --scratch-path "$task_scratch" --show-bin-path)"
task_app="$PWD/build/Workspace Tabs.app"
rtk proxy mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
rtk proxy cp "$task_bin/WorkspaceTabs" "$task_app/Contents/MacOS/WorkspaceTabs"
rtk proxy python3 scripts/make_bundle.py "$task_app"
if [ ! -f "$task_app/Contents/Resources/AppIcon.icns" ] || [ ! -f "$task_app/Contents/Resources/AppMark.pdf" ] || [ scripts/make_icon.swift -nt "$task_app/Contents/Resources/AppIcon.icns" ]; then
    rtk proxy swift scripts/make_icon.swift "$task_app/Contents/Resources"
fi
task_sign="${WORKSPACE_TABS_SIGN_IDENTITY:-}"
if [ -z "$task_sign" ]; then
    task_sign="$(rtk proxy python3 -c 'import subprocess,re; s=subprocess.check_output(["security","find-identity","-v","-p","codesigning"],text=True); m=re.search(r"([0-9A-F]{40}) \"Apple Development:",s); print(m.group(1) if m else "-")')"
fi
rtk proxy codesign --force --sign "$task_sign" --identifier com.ssuzuki.WorkspaceTabs "$task_app"
rtk proxy codesign --verify --deep --strict "$task_app"
rtk proxy sh -c 'printf "Built: %s\n" "$1"' _ "$task_app"
if [ "${1:-}" = "--install" ]; then
    if [ -d "/Applications/Workspace Tabs.app" ]; then
        task_backup="/tmp/Workspace-Tabs-previous-$(date +%Y%m%d-%H%M%S).app"
        rtk proxy ditto "/Applications/Workspace Tabs.app" "$task_backup"
    fi
    rtk proxy ditto "$task_app" "/Applications/Workspace Tabs.app"
    rtk proxy codesign --verify --deep --strict "/Applications/Workspace Tabs.app"
fi
