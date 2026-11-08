import { LaunchProps, open, showToast, Toast } from "@raycast/api";
export default async function OpenNotionLink(props: LaunchProps<{ arguments: { url: string } }>) {
  try {
    const url = new URL(props.arguments.url.trim());
    if (url.protocol !== "https:" || !["app.notion.com", "app.dev.notion.com", "notion.so", "www.notion.so"].includes(url.hostname) || url.username || url.password) throw new Error("NotionのHTTPS URLを入力してください");
    await open("workspacetabs://open?" + new URLSearchParams({ url: url.href }).toString(), "com.ssuzuki.WorkspaceTabs");
  } catch (error) {
    await showToast({ style: Toast.Style.Failure, title: "リンクを開けませんでした", message: error instanceof Error ? error.message : "URLを確認してください" });
  }
}
