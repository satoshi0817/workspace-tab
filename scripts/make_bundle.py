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
    "CFBundleShortVersionString": "1.0.2",
    "CFBundleVersion": "8",
    "CFBundleDevelopmentRegion": "en",
    "CFBundleLocalizations": ["ja", "en", "ko"],
    "CFBundleURLTypes": [{"CFBundleURLName": "Workspace Tabs Launcher", "CFBundleURLSchemes": ["workspacetabs"]}, {"CFBundleURLName": "Web Links", "CFBundleTypeRole": "Viewer", "CFBundleURLSchemes": ["http", "https"]}],
    "CFBundleIconFile": "AppIcon",
    "LSMinimumSystemVersion": "14.0",
    "NSHighResolutionCapable": True,
    "NSMicrophoneUsageDescription": "NotionのAIミーティングノートなど、ページ上で開始した音声入力にマイクを使用します。",
    "NSCameraUsageDescription": "ページ上で開始したビデオ通話などにカメラを使用します。",
    "NSPrincipalClass": "NSApplication",
    "NSHumanReadableCopyright": "Copyright © 2026 Satoshi Suzuki. MIT License.",
}
(bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))

shutil.copyfile(pathlib.Path(__file__).resolve().parent.parent / "Resources" / "NotionLogo.png", bundle / "Contents" / "Resources" / "NotionLogo.png")

for notice in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
    shutil.copyfile(pathlib.Path(__file__).resolve().parent.parent / notice, bundle / "Contents" / "Resources" / notice)

shutil.copytree(pathlib.Path(__file__).resolve().parent.parent / "Resources" / "NotionIcons", bundle / "Contents" / "Resources" / "NotionIcons", dirs_exist_ok=True)

# Keep localization inside the app; never depend on SwiftPM's build directory.
shutil.copyfile(pathlib.Path(__file__).resolve().parent.parent / "Sources" / "WorkspaceCore" / "Resources" / "Localizations.json", bundle / "Contents" / "Resources" / "Localizations.json")
for language, description in {
    "ja": "NotionのAIミーティングノートなど、ページ上で開始した音声入力にマイクを使用します。",
    "en": "The microphone is used for audio input you start on a page, such as Notion AI meeting notes.",
    "ko": "Notion AI 회의록 등 페이지에서 직접 시작한 음성 입력에 마이크를 사용합니다.",
}.items():
    folder = bundle / "Contents" / "Resources" / (language + ".lproj")
    folder.mkdir(exist_ok=True)
    (folder / "InfoPlist.strings").write_text('"NSMicrophoneUsageDescription" = "' + description + '";\n')
    camera = {
        "ja": "ページ上で開始したビデオ通話などにカメラを使用します。",
        "en": "The camera is used for video calls and other camera input you start on a page.",
        "ko": "페이지에서 직접 시작한 영상 통화 등 카메라 입력에 카메라를 사용합니다.",
    }[language]
    with (folder / "InfoPlist.strings").open("a") as output:
        output.write('"NSCameraUsageDescription" = "' + camera + '";\n')
