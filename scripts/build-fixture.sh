#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_fixture="$PWD/build/WorkspaceTabsFixture.app"
rtk proxy mkdir -p "$task_fixture/Contents/MacOS"
task_arch="$(rtk proxy uname -m)"
rtk proxy swiftc scripts/Fixture.swift -target "$task_arch-apple-macosx14.0" -o "$task_fixture/Contents/MacOS/WorkspaceTabsFixture" -framework AppKit
rtk proxy python3 - "$task_fixture" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1])/'Contents/Info.plist'
p.write_bytes(plistlib.dumps({'CFBundleName':'WorkspaceTabsFixture','CFBundleIdentifier':'com.ssuzuki.WorkspaceTabsFixture','CFBundleExecutable':'WorkspaceTabsFixture','CFBundlePackageType':'APPL','LSUIElement':False}))
PY
rtk proxy codesign --force --sign - "$task_fixture"
