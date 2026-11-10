# Workspace Tabs for Raycast

[日本語](README.md)

Search local Workspace Tabs lists and run actions through its URL scheme. The extension does not read Notion tokens or cookies.

## Install

Start Workspace Tabs, then run `npm ci` and `npm run dev` in this directory. You can assign a Hotkey or Alias to each command in Raycast's Extensions settings.

- **Search Favorites** — Open favorites using their existing Category and Workspace ID routing.
- **Search All Tabs** — Jump to browser tabs across all app tabs.
- **Switch App Tab** — Switch between app tabs.
- **Open Notion Link** — Open a Notion HTTPS link in a matching app tab.
- **Run Command** — Run an action in the last active tab or in an app tab selected at the upper right.

Workspace Tabs updates its index when it saves (normally after 0.4 seconds, at most about 5 seconds); Raycast reloads it every 2 seconds. While the app is closed, the extension shows the last saved state and launches the app when you choose an action. Notion creation commands depend on Notion's current interface, your sign-in state, and permissions.

Only the file owner can read or write `~/Library/Application Support/WorkspaceTabs/raycast-index.json`. Its URLs contain a local integration token; do not share them. The extension rejects arbitrary URLs and JavaScript execution.

Favorites are grouped by category. Categories follow their Order field; links within each category are sorted by pinned state, link Order, and name. Uncategorized links appear last. Use ⌘← / ⌘→ to switch categories. The left and right arrow keys in the search field move the text cursor. Chosen images and preset icons take priority; otherwise the extension shows emoji. Monochrome presets use Raycast's text color.

Save a work set in **Workspace Tabs → Settings → Work** to show it in Run Command. Restoring a set keeps your current tabs open.

Open Notion Link accepts a Notion URL and opens it in a matching environment. If the app cannot choose an environment, it asks you to select one.

Configure how the OS sends Notion web links under **Workspace Tabs → Settings → Link routing**. The Raycast Open Notion Link command works without changing your default browser.
