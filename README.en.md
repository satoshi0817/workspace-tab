# Workspace Tabs

[日本語](README.md)

Workspace Tabs is a macOS browser that keeps work, personal, and other sign-in environments separate in one window.

## Features

- **Separate environments** — Assign a sign-in environment to each app tab and identify it by name, color, and icon.
- **Organize tabs** — Group, reorder, and pin tabs.
- **Recognize tabs at a glance** — Use your own images or search among 885 preset icons for groups, tabs, and favorites.
- **View two pages together** — Split pages from different app tabs horizontally or vertically and save the layout.
- **Move quickly** — Search tabs, favorites, files, and commands together; use keyboard shortcuts or Raycast.
- **Resume work** — Restore open tabs and the selected tab when you relaunch the app.
- **Open downloaded files** — Open files or reveal them in Finder from the download history in the sidebar.
- **Choose a language** — The interface supports Japanese, English, and Korean.

New environments start with a gray color. Choose a left sidebar or top tab bar, icon-only tabs, or a sidebar that expands when you move the pointer to the left edge. Light, dark, and system appearance are supported.

## Install

**Workspace Tabs v1.0.3 (build 9)** supports Apple Silicon and Intel Macs running macOS 14 or later. The Universal app is signed with Developer ID and notarized by Apple. To build from source, use the `main` branch or the `v1.0.3` tag.

1. Download `Workspace-Tabs-1.0.3-universal.dmg` from the [release page](https://github.com/satoshi0817/workspace-tab/releases/tag/v1.0.3) under **Assets**.
2. Double-click the DMG to open it.
3. Drag **Workspace Tabs.app** to the **Applications** folder beside it.
4. Open **Workspace Tabs** from Applications.

You do not need Terminal, Xcode, Python, Homebrew, or other tools to install and use the app. When updating, quit Workspace Tabs before replacing it. If the repository is private, sign in to a GitHub account with access to download the release.

See [Build from source](#build-from-source) if you want to build the app yourself.

## Get started

1. In the first-run guide, choose the display language, environment name, home URL, and layout.
2. Sign in to sites in the built-in browser.
3. Use **＋** in the sidebar to add app tabs for work, personal use, or other contexts. Select the same environment for tabs that should share a login.
4. Press **⌘T** to choose a new tab. Under **→ URL or Search**, enter a URL to open a site or keywords to search Google.
5. Right-click a tab to change its name, icon, pinned state, or group.

Use **Settings → Link routing** to route links by domain, and the “…” menu at the right end of the tab bar to set site-specific zoom and permissions. If the app has trouble starting, hold Option while launching it or set safe mode for the next launch in **Settings → Diagnostics**.

Open **?** in the sidebar for searchable help and an option to show the introduction again.

Choose the display language in the first-run guide or under **Settings → Appearance → Language**. Switching among **System / 日本語 / English / 한국어** takes effect immediately and persists after relaunch. It does not change website languages, login data, or names you have entered. macOS permission dialogs follow the system language.

## Change icons

- For a group, click its name at the left end of the tab bar and choose **Edit group…**.
- For an app tab or browser tab, right-click it.
- For a favorite, open its edit screen.

Choose **Presets…** to search by name or category, or **Image…** to select a PNG, JPEG, or HEIC file. The chosen icon is stored on this Mac and remains available if you move the original image. Monochrome presets use the same color as text.

## Common shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘T / ⌘W / ⌘⇧T | Add / close / restore a tab |
| ⌃⌥1–9 | Switch to an app tab by number |
| ⌘⌥← / → | Previous / next app tab |
| ⌃⌥Space | Search all tabs |
| ⌃Tab | Switch to a recent tab |
| ⌘⇧L | Open a favorite |
| ⌘⇧P | Search commands |
| ⌘L | Show the URL bar |
| ⌘⇧N | Show the Notion creation menu |
| ⌘⇧C | Copy the current URL |
| ⌘, | Open Settings |

Hold **⌘ or the app-tab switching modifier for about 0.5 seconds** to show the corresponding keys on app tabs. The hints stay visible while you use the modifier and number keys, and disappear when you release the modifier. The assigned shortcuts do not change.

In the creation menu, select an item with ↑↓ and Return, keys 1–5, or a click. Press Esc or click outside to close it.

These are the default shortcuts. Use **Settings → Shortcuts** to record a key combination or sequence, change an action, or reset it.

## Use with Raycast

You need Raycast, Node.js 22.22.2 or later, and npm. From the repository root, run:

```sh
cd raycast
npm ci
npm run dev
```

This registers a development extension. Keep Workspace Tabs running too.

- **Search Favorites** — Find and open favorites.
- **Search All Tabs** — Search browser tabs across app tabs.
- **Switch App Tab** — Switch app tabs.
- **Open Notion Link** — Open a Notion link in a matching app tab.
- **Run Command** — Choose an action and its destination.

You can assign Hotkeys and Aliases in Raycast settings. See the [Raycast guide](raycast/README.en.md).

## More details

<details>
<summary>Tabs, sign-in environments, and saved state</summary>

- Each app tab contains browser tabs. Different sign-in environments keep cookies and site data separate; app tabs assigned to the same environment share them.
- Switch tab groups with the selector at the left end of the tab bar or by scrolling vertically over the tab bar. The visible page does not change until you click a tab.
- You can pin tabs as icons, temporarily detach a tab into another window, and save work sets.
- Ordinary tab switching does not reload pages. While a page reloads, the app shows a shimmer and status message. It does not capture or save page screenshots.
- When you pin a tab you can check or change the URL it reopens; after restarting the app, the pinned tab opens that page.
- Tabs that have not been shown for a while (30 minutes by default) are rested to free memory and load again when opened. Change the time or turn it off in **Settings → Work → Memory saving**. Resting a tab discards unsubmitted input. Tabs that are visible, in Split View, pinned, loading, or using the microphone or camera are never rested.
- Closing the current tab switches to the tab on its left. Site settings, the URL bar, and Split View actions are in the “…” menu at the right end of the tab bar.
- Drag a tab or an app tab onto the page to start Split View with that page on the side where you drop it (drop near the bottom edge for a top-and-bottom split).
- Incoming Notion links open in the only app tab for that environment (for example the dev site); otherwise the app checks which workspace owns the page and opens the matching app tab. If the Notion desktop app opens first, turn off “Open links in desktop app” in the Notion app’s settings.
- The signed-in Notion account (user name and profile photo, or an initial) is shown at the top right of each tab; click it to check again when it is unverified. The @ button next to it shows the email address over the page per browser tab; the default for an app tab, plus position, text size, and opacity, are set in the app tab edit screen. Names, email addresses, and photos are kept in memory only.
- In an app tab with several sign-in environments, or signed in to Notion with several accounts, choosing Notion for a new tab lets you pick the account with a number key or ↑↓ and Return.
- On relaunch, saved tab URLs are restored. Unsubmitted form input and temporary state inside a page are not restored.
- Settings are stored in `~/Library/Application Support/WorkspaceTabs/`; site data lives in persistent WebKit profiles. Current state saves automatically when it changes. Layout snapshots for recovery are normally kept every five minutes and before loading or restoring. You can restore from the 20 most recent snapshots.
- The app does not import login sessions from other browsers or install browser extensions.
- Global modifier-key sequences require macOS Accessibility permission.
- Liquid Glass is used on macOS 26 or later. Site and authentication compatibility also depends on the macOS WebKit version.

See [storage, recovery, and performance details](docs/FEATURES.md) (Japanese).

</details>

<details>
<summary>Service-specific features and optional sync</summary>

For Notion, the app provides a home URL, workspace ID routing, sidebar colors, and a creation menu. Press **⌘⇧N** to open the menu near the pointer and choose a new page, AI chat, meeting notes, database, or custom page in a new tab. Availability depends on your Notion features and permissions.

For AI meeting-note transcription, allow microphone access in both macOS and the site. Check permission status under **Settings → Diagnostics → Microphone and meeting notes**. The app uses microphone input from the web page; it does not directly capture system audio from other apps such as Zoom.

Enabling **Settings → Link routing** makes Workspace Tabs the default browser on this Mac. Supported Notion web links open in this app; other links go to the previous browser. Turning the setting off restores the previous browser. The initial setting does not change OS defaults. Links that target another native app directly may not be covered.

Favorites are stored locally by default. Optionally, you can sync them with a Notion database about once an hour and use it to back up tab layouts. Connection credentials are stored in Keychain.

See [service integration, sync, and workspace routing](docs/FEATURES.md#notion保存と振り分け) (Japanese).

</details>

## Build from source

Developers need a macOS 26 or later SDK and a Swift 6 toolchain (Xcode 26 or later, or equivalent Command Line Tools), plus Python 3. Complete the development-tool setup before your first build.

```sh
git clone https://github.com/satoshi0817/workspace-tab.git
cd workspace-tab
bash scripts/build.sh
```

This creates `build/Workspace Tabs.app`. Open the `build` folder in Finder and drag the app to Applications to launch it.

You can also package a distribution DMG using standard macOS tools:

```sh
bash scripts/package.sh
```

The script writes an architecture-specific DMG and SHA-256 checksum to `build/release/`. Packaging alone does not notarize the app. For a public release, configure a Developer ID signing identity and a `notarytool` Keychain profile, then run `scripts/release.sh`. It builds both CPU architectures, signs the app, notarizes the app and DMG, staples their tickets, and checks Gatekeeper acceptance.

## Development and verification

With the app already built, run these from the repository root:

```sh
swift run --scratch-path /tmp/workspace-tabs-build WorkspaceCoreChecks
python3 scripts/browser_checks.py
```

The browser checks use local test pages and an isolated temporary login environment. In `raycast/`, run `npm run typecheck` and `npm run build` to check the Raycast extension.

To test first launch, this command creates an environment without settings or cookies and checks that Notion loads five times. It does not use your existing tabs or logins. Internet access is required; HTTP errors such as 504 produce a nonzero exit code.

```sh
"build/Workspace Tabs.app/Contents/MacOS/WorkspaceTabs" --startup-checks
```

See [first-launch troubleshooting](docs/FIRST_LAUNCH_CHECKS.md) (Japanese) for failures such as 504.

If an Apple Development certificate is available, the build uses it; otherwise it uses an ad hoc signature. Set `WORKSPACE_TABS_SIGN_IDENTITY` to choose a signing identity or `WORKSPACE_TABS_BUILD_DIR` to choose a build directory. Distribution requires separate notarization.

| Path | Contents |
| --- | --- |
| `Sources/WorkspaceTabs/` | macOS app, WebKit, and external integrations |
| `Sources/WorkspaceCore/` | Shared models and routing logic |
| `Tests/WorkspaceCoreTests/` | Shared logic checks |
| `raycast/` | Raycast extension |
| `scripts/` | Build and verification scripts |
| `docs/` | Detailed specifications and research notes |

The [performance audit](docs/PERFORMANCE_AUDIT.md) and legacy window-management notes in `docs/` are kept as project history (Japanese).

## License

This project is available under the [MIT License](LICENSE). You may use, modify, and redistribute it commercially while retaining the copyright and license notice. It comes without warranty.

Third-party logos, images, and dependencies have their own terms. See [third-party materials and libraries](THIRD_PARTY_NOTICES.md).
