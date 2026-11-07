import Foundation

public enum BrowserStyle {
    public static func script(hex: String, enabled: Bool, strength: Double) -> String {
        let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let color = raw.count == 6 && raw.allSatisfy({ $0.isASCII && $0.isHexDigit }) ? "#" + raw : "#9478E8"
        let amount = strength.isFinite ? min(100, max(0, strength * 100)) : 18
        return """
        (() => {
          const id = 'workspace-tabs-sidebar-theme';
          const old = document.getElementById(id); if (old) old.remove();
          if (!\(enabled ? "true" : "false") || location.protocol !== 'https:' ||
              !['app.notion.com','app.dev.notion.com','www.notion.so','notion.so','www.notion.com'].includes(location.hostname)) return;
          const style = document.createElement('style'); style.id = id;
          style.textContent = `.notion-sidebar-container { background-color: color-mix(in srgb, \(color) \(amount)%, #ffffff) !important; }
          @media (prefers-color-scheme: dark) { .notion-sidebar-container { background-color: color-mix(in srgb, \(color) \(amount)%, #191919) !important; } }
          body.dark .notion-sidebar-container, .dark .notion-sidebar-container { background-color: color-mix(in srgb, \(color) \(amount)%, #191919) !important; }`;
          (document.head || document.documentElement).appendChild(style);
        })();
        """
    }
}
