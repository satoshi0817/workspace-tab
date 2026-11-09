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
    "CFBundleShortVersionString": "0.2.0",
    "CFBundleVersion": "3",
    "CFBundleURLTypes": [{"CFBundleURLName": "Workspace Tabs Launcher", "CFBundleURLSchemes": ["workspacetabs"]}, {"CFBundleURLName": "Web Links", "CFBundleTypeRole": "Viewer", "CFBundleURLSchemes": ["http", "https"]}],
    "CFBundleIconFile": "AppIcon",
    "LSMinimumSystemVersion": "14.0",
    "NSHighResolutionCapable": True,
    "NSPrincipalClass": "NSApplication",
    "NSHumanReadableCopyright": "Workspace Tabs",
}
(bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))

shutil.copyfile(pathlib.Path(__file__).resolve().parent.parent / "Resources" / "NotionLogo.png", bundle / "Contents" / "Resources" / "NotionLogo.png")
