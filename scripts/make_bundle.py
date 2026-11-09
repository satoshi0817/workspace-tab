import pathlib
import plistlib
import sys
import shutil

bundle = pathlib.Path(sys.argv[1])
info = {
    "CFBundleName": "Workspace Tabs",
    "CFBundleDisplayName": "Workspace Tabs",
    "CFBundleIdentifier": "com.ssuzuki.WorkspaceTabs",
    "CFBundleExecutable": "WorkspaceTabs",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0.0",
    "CFBundleVersion": "6",
    "CFBundleURLTypes": [{"CFBundleURLName": "Workspace Tabs Launcher", "CFBundleURLSchemes": ["workspacetabs"]}, {"CFBundleURLName": "Web Links", "CFBundleTypeRole": "Viewer", "CFBundleURLSchemes": ["http", "https"]}],
    "CFBundleIconFile": "AppIcon",
    "LSMinimumSystemVersion": "14.0",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "NSHumanReadableCopyright": "Copyright © 2026 Satoshi Suzuki. MIT License.",
}
(bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))

shutil.copyfile(pathlib.Path(__file__).resolve().parent.parent / "Resources" / "NotionLogo.png", bundle / "Contents" / "Resources" / "NotionLogo.png")

for notice in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
    shutil.copyfile(pathlib.Path(__file__).resolve().parent.parent / notice, bundle / "Contents" / "Resources" / notice)

shutil.copytree(pathlib.Path(__file__).resolve().parent.parent / "Resources" / "NotionIcons", bundle / "Contents" / "Resources" / "NotionIcons", dirs_exist_ok=True)
