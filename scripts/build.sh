#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_scratch="${WORKSPACE_TABS_BUILD_DIR:-/tmp/workspace-tabs-build}"
swift build -c release --scratch-path "$task_scratch"
task_bin="$(swift build -c release --scratch-path "$task_scratch" --show-bin-path)"
task_app="$PWD/build/Workspace Tabs.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
if [ "${WORKSPACE_TABS_UNIVERSAL:-0}" = 1 ]; then
    task_x86_scratch="${WORKSPACE_TABS_X86_BUILD_DIR:-/tmp/workspace-tabs-build-x86}"
    swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path "$task_x86_scratch"
    task_x86_bin="$(swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path "$task_x86_scratch" --show-bin-path)"
    lipo -create "$task_bin/WorkspaceTabs" "$task_x86_bin/WorkspaceTabs" -output "$task_app/Contents/MacOS/WorkspaceTabs"
else
    cp "$task_bin/WorkspaceTabs" "$task_app/Contents/MacOS/WorkspaceTabs"
fi
python3 scripts/make_bundle.py "$task_app"
if [ ! -f "$task_app/Contents/Resources/AppIcon.icns" ] || [ ! -f "$task_app/Contents/Resources/AppMark.pdf" ] || [ scripts/make_icon.swift -nt "$task_app/Contents/Resources/AppIcon.icns" ]; then
    swift scripts/make_icon.swift "$task_app/Contents/Resources"
fi
task_sign="${WORKSPACE_TABS_SIGN_IDENTITY:-}"
if [ -z "$task_sign" ]; then
    task_sign="$(python3 -c 'import subprocess,re; s=subprocess.check_output(["security","find-identity","-v","-p","codesigning"],text=True); m=re.search(r"([0-9A-F]{40}) \"Apple Development:",s); print(m.group(1) if m else "-")')"
fi
if [ "${WORKSPACE_TABS_RELEASE:-0}" = 1 ]; then
    case "$task_sign" in
        "Developer ID Application:"*) ;;
        *) echo "Release signing requires a Developer ID Application identity" >&2; exit 1 ;;
    esac
    codesign --force --options runtime --timestamp --entitlements Resources/WorkspaceTabs.entitlements --sign "$task_sign" --identifier com.ssuzuki.WorkspaceTabs "$task_app"
else
    codesign --force --entitlements Resources/WorkspaceTabs.entitlements --sign "$task_sign" --identifier com.ssuzuki.WorkspaceTabs "$task_app"
fi
codesign --verify --deep --strict "$task_app"
sh -c 'printf "Built: %s\n" "$1"' _ "$task_app"
if [ "${1:-}" = "--install" ]; then
    python3 scripts/install_app.py "$task_app" "/Applications/Workspace Tabs.app"
fi
