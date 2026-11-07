import { Action, ActionPanel, Icon, List, Toast, closeMainWindow, open, showToast } from "@raycast/api";
import { useEffect, useState } from "react";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

type Entry = { id: string; title: string; subtitle: string; emoji: string; workspaceID?: string };
type Index = { version: number; token: string; favorites: Entry[]; tabs: Entry[]; workspaces: Entry[]; commands: Entry[] };
type Kind = "favorites" | "tabs" | "workspaces" | "commands";
const path = join(homedir(), "Library/Application Support/WorkspaceTabs/raycast-index.json");
const kinds = { favorites: "favorite", tabs: "tab", workspaces: "workspace", commands: "command" };
export default function Launcher({ kind }: { kind: Kind }) {
  const [index, setIndex] = useState<Index>();
  const [error, setError] = useState<string>();
  const [target, setTarget] = useState("");
  useEffect(() => {
    let active = true;
    async function load() {
      try {
        const value: Index = JSON.parse(await readFile(path, "utf8"));
        if (value.version !== 1 || !value.token || !Array.isArray(value[kind])) throw new Error("Unsupported index");
        if (active) { setIndex(value); setError(undefined); }
      } catch { if (active) setError("Workspace Tabsを起動すると一覧が読み込まれます。更新版が必要です。"); }
    }
    void load(); const timer = setInterval(load, 2000);
    return () => { active = false; clearInterval(timer); };
  }, [kind]);
  async function launch(entry: Entry) {
    if (!index) return;
    try {
      const params = new URLSearchParams({ token: index.token, kind: kinds[kind], id: entry.id });
      const workspace = kind === "commands" ? target : entry.workspaceID;
      if (workspace) params.set("workspace", workspace);
      await closeMainWindow();
      await open(`workspacetabs://launch?${params.toString()}`, "com.ssuzuki.WorkspaceTabs");
    } catch { await showToast({ style: Toast.Style.Failure, title: "Workspace Tabsを開けませんでした", message: "アプリが/Applicationsにあるか確認してください" }); }
  }
  return <List isLoading={!index && !error} searchBarPlaceholder="名前・アプリタブを検索" searchBarAccessory={kind === "commands" && index ? <List.Dropdown tooltip="実行先" value={target} onChange={setTarget}><List.Dropdown.Item value="" title="最後に操作したタブ" />{index.workspaces.map(w => <List.Dropdown.Item key={w.id} value={w.id} title={w.title} />)}</List.Dropdown> : undefined}>
    {error ? <List.EmptyView icon={Icon.AppWindow} title="Workspace Tabsとの接続待ち" description={error} actions={<ActionPanel><Action title="Workspace Tabsを開く" onAction={() => open("/Applications/Workspace Tabs.app")} /></ActionPanel>} /> : index?.[kind].map(entry => <List.Item key={entry.id} title={entry.title} subtitle={entry.subtitle} keywords={[entry.subtitle]} icon={entry.emoji ? { source: `data:image/svg+xml,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><text x="32" y="48" font-size="48" text-anchor="middle">${entry.emoji.replace(/[<>&]/g, "")}</text></svg>`)}` } : Icon.AppWindow} actions={<ActionPanel><Action title={kind === "commands" ? "実行" : "開く"} onAction={() => launch(entry)} /></ActionPanel>} />)}
  </List>;
}
