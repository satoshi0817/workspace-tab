import { Color, Action, ActionPanel, Icon, List, Toast, closeMainWindow, open, showToast } from "@raycast/api";
import { useEffect, useState } from "react";
import { readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

type Entry = { id: string; title: string; subtitle: string; emoji: string; workspaceID?: string; category?: string; iconPath?: string };
type Index = { version: number; token: string; favorites: Entry[]; tabs: Entry[]; workspaces: Entry[]; commands: Entry[] };
type Kind = "favorites" | "tabs" | "workspaces" | "commands";
const path = join(homedir(), "Library/Application Support/WorkspaceTabs/raycast-index.json");
const kinds = { favorites: "favorite", tabs: "tab", workspaces: "workspace", commands: "command" };
export default function Launcher({ kind }: { kind: Kind }) {
  const [index, setIndex] = useState<Index>();
  const [error, setError] = useState<string>();
  const [target, setTarget] = useState("");
  const [category, setCategory] = useState("");
  const categories = [...new Set((index?.favorites ?? []).map(e => e.category || "未分類"))];
  const currentCategory = categories.includes(category) ? category : "";
  const groups = kind === "favorites" ? categories.filter(c => !currentCategory || c === currentCategory) : [""];
  function cycleCategory(offset: number) {
    const values = ["", ...categories];
    setCategory(values[(values.indexOf(currentCategory) + offset + values.length) % values.length]);
  }
  const categoryActions = kind === "favorites" ? <>
    <Action title="前のカテゴリ" shortcut={{ modifiers: ["cmd"], key: "arrowLeft" }} onAction={() => cycleCategory(-1)} />
    <Action title="次のカテゴリ" shortcut={{ modifiers: ["cmd"], key: "arrowRight" }} onAction={() => cycleCategory(1)} />
  </> : null;
  useEffect(() => {
    let active = true;
    let loading = false;
    let signature = "";
    async function load() {
      if (loading) return;
      loading = true;
      try {
        const metadata = await stat(path);
        const nextSignature = `${metadata.ino}:${metadata.mtimeMs}:${metadata.size}`;
        if (signature === nextSignature) return;
        const value: Index = JSON.parse(await readFile(path, "utf8"));
        if (value.version !== 1 || !value.token || !Array.isArray(value[kind])) throw new Error("Unsupported index");
        if (active) { signature = nextSignature; setIndex(value); setError(undefined); }
      } catch { signature = ""; if (active) setError("Workspace Tabsを起動すると一覧が読み込まれます。更新版が必要です。"); } finally { loading = false; }
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
  return <List isLoading={!index && !error} searchBarPlaceholder="名前・アプリタブを検索" searchBarAccessory={kind === "commands" && index ? <List.Dropdown tooltip="実行先" value={target} onChange={setTarget}><List.Dropdown.Item value="" title="最後に操作したタブ" />{index.workspaces.map(w => <List.Dropdown.Item key={w.id} value={w.id} title={w.title} />)}</List.Dropdown> : kind === "favorites" ? <List.Dropdown tooltip="カテゴリ（⌘← / ⌘→で切り替え）" value={currentCategory} onChange={setCategory}><List.Dropdown.Item value="" title="すべてのカテゴリ" />{categories.map(c => <List.Dropdown.Item key={c} value={c} title={c} />)}</List.Dropdown> : undefined}>
    {error ? <List.EmptyView icon={Icon.AppWindow} title="Workspace Tabsとの接続待ち" description={error} actions={<ActionPanel><Action title="Workspace Tabsを開く" onAction={() => open("/Applications/Workspace Tabs.app")} /></ActionPanel>} /> : groups.map(group => <List.Section key={group} title={group || undefined}>
      {index?.[kind].filter(entry => kind !== "favorites" || (entry.category || "未分類") === group).map(entry => <List.Item key={entry.id} title={entry.title} subtitle={entry.subtitle} keywords={[entry.subtitle, entry.category || ""]} icon={entry.iconPath ? { source: entry.iconPath, tintColor: entry.iconPath.includes(".template.") ? Color.PrimaryText : undefined } : entry.emoji || (kind === "favorites" ? Icon.Link : Icon.AppWindow)} actions={<ActionPanel><Action title={kind === "commands" ? "実行" : "開く"} onAction={() => launch(entry)} />{categoryActions}</ActionPanel>} />)}
    </List.Section>)}
  </List>;
}
