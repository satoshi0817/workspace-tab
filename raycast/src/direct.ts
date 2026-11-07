import { open, closeMainWindow, showToast, Toast } from "@raycast/api";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
export async function runDirect(id: string) {
  try {
    const index = JSON.parse(await readFile(join(homedir(), "Library/Application Support/WorkspaceTabs/raycast-index.json"), "utf8"));
    if (index.version !== 1 || typeof index.token !== "string") throw new Error("Unsupported index");
    const params = new URLSearchParams({ token: index.token, kind: "command", id });
    await closeMainWindow();
    await open(`workspacetabs://launch?${params.toString()}`, "com.ssuzuki.WorkspaceTabs");
  } catch {
    await showToast({ style: Toast.Style.Failure, title: "Workspace Tabsを起動してください", message: "更新版アプリを一度起動してから再実行してください" });
  }
}
