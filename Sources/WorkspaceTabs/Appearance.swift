import WorkspaceCore
import SwiftUI
import AppKit

// Shared dimensions for the browser shell. Keep inset and control spacing on a 4pt grid.
enum BrowserLayout {
    static let small:CGFloat = 4
    static let gap:CGFloat = 8
    static let inset:CGFloat = 8
    static let control:CGFloat = 32
    static let appTab:CGFloat = 40
    static let tabBar:CGFloat = 48
    static let iconSidebar:CGFloat = appTab + inset * 2
    static let sidebar:CGFloat = 220
    static let tabRadius:CGFloat = 8
    static let appRadius:CGFloat = 10
    static let pageRadius:CGFloat = 12
}

/// A persistent outline makes every browser tab visible, including inactive tabs.
struct BrowserStripChip:ViewModifier {
    let ink:Color
    var selected=false
    var hovered=false
    func body(content:Content)->some View {
        let shape=RoundedRectangle(cornerRadius:BrowserLayout.tabRadius,style:.continuous)
        content.frame(height:BrowserLayout.control)
            .background(ink.opacity(selected ? 0.18:hovered ? 0.10:0.045),in:shape)
            .overlay(shape.strokeBorder(ink.opacity(selected ? 0.65:hovered ? 0.38:0.22),lineWidth:selected ? 1.25:1))
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return L("システム")
        case .light: return L("ライト")
        case .dark: return L("ダーク")
        }
    }
}

enum Palette {
    private static let appMark: NSImage? = Bundle.main.url(forResource:"AppMark",withExtension:"pdf").flatMap{NSImage(contentsOf:$0)}
    private static let menuGlyphs=NSCache<NSString,NSImage>()
    static func menuGlyph(_ ink: Color) -> NSImage {
        let key=hex(ink) as NSString
        if let cached=menuGlyphs.object(forKey:key){return cached}
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        if let appMark {appMark.draw(in:NSRect(x:0,y:0,width:24,height:24))}
        else {NSImage(systemSymbolName:"rectangle.on.rectangle",accessibilityDescription:nil)?.draw(in:NSRect(x:3,y:3,width:18,height:18))}
        NSColor(ink).setFill(); NSRect(x: 0, y: 0, width: 24, height: 24).fill(using: .sourceAtop)
        image.unlockFocus(); image.isTemplate = false
        menuGlyphs.countLimit=16;menuGlyphs.setObject(image,forKey:key)
        return image
    }
    /// Menu labels ignore foregroundStyle, so bake the tab bar ink into the symbol.
    static func symbolGlyph(_ name:String,_ ink:Color)->NSImage {
        let config=NSImage.SymbolConfiguration(pointSize:14,weight:.semibold).applying(.init(paletteColors:[NSColor(ink)]))
        let image=NSImage(systemSymbolName:name,accessibilityDescription:nil)?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate=false
        return image
    }
    private static let groupMenuLabels=NSCache<NSString,NSImage>()
    static func groupMenuLabel(_ title:String,ink:Color,icon:NSImage?=nil,iconKey:String="folder")->NSImage {
        let key=(hex(ink)+"|"+title+"|"+iconKey) as NSString
        if let image=groupMenuLabels.object(forKey:key) {return image}
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
        let attributes:[NSAttributedString.Key:Any]=[
            .font:NSFont.systemFont(ofSize:12,weight:.semibold),
            .foregroundColor:NSColor(ink),.paragraphStyle:paragraph
        ]
        let text=NSAttributedString(string:title,attributes:attributes)
        let width=min(110,ceil(text.size().width))
        let image=NSImage(size:NSSize(width:width+38,height:20))
        image.lockFocus()
        if let custom=icon {
            let ratio=min(16/custom.size.width,16/custom.size.height)
            let size=NSSize(width:custom.size.width*ratio,height:custom.size.height*ratio)
            custom.draw(in:NSRect(x:(16-size.width)/2,y:(20-size.height)/2,width:size.width,height:size.height))
            if custom.isTemplate {NSColor(ink).setFill();NSRect(x:0,y:0,width:16,height:20).fill(using:.sourceAtop)}
        } else if let folder=NSImage(systemSymbolName:"folder",accessibilityDescription:nil) {
            folder.draw(in:NSRect(x:0,y:3,width:15,height:14))
            NSColor(ink).setFill();NSRect(x:0,y:3,width:15,height:14).fill(using:.sourceAtop)
        }
        text.draw(in:NSRect(x:20,y:2,width:width,height:17))
        let arrow=NSBezierPath();arrow.lineWidth=1.4;arrow.lineCapStyle = .round;arrow.lineJoinStyle = .round
        arrow.move(to:NSPoint(x:width+26,y:12));arrow.line(to:NSPoint(x:width+30,y:8));arrow.line(to:NSPoint(x:width+34,y:12))
        NSColor(ink).setStroke();arrow.stroke()
        image.unlockFocus();image.isTemplate=false
        groupMenuLabels.countLimit=128;groupMenuLabels.setObject(image,forKey:key)
        return image
    }
    /// Two rows of eight: neutrals, then the hue wheel from blue round to brown.
    /// Saved names stay valid, so only add new names; never rename one.
    static let names = ["gray", "charcoal", "blue", "indigo", "violet", "pink", "rose", "red",
                        "orange", "amber", "yellow", "lime", "green", "teal", "cyan", "brown"]
    static func normalizedHex(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard [3, 6].contains(value.count), value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        return "#" + value.uppercased()
    }
    static func hex(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    static func ink(_ background: String, preference: String? = nil) -> Color {
        if preference == "white" { return .white }
        if preference == "black" { return .black }
        let c = NSColor(color(background)).usingColorSpace(.sRGB) ?? .black
        func linear(_ v: CGFloat) -> Double { let x = Double(v); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        return luminance > 0.179 ? .black : .white
    }
    static func displayName(_ name: String) -> String {
        switch name {
        case "gray": return L("グレー")
        case "charcoal": return L("チャコール")
        case "blue": return L("青")
        case "indigo": return L("インディゴ")
        case "violet": return L("紫")
        case "pink": return L("ピンク")
        case "rose": return L("ローズ")
        case "red": return L("赤")
        case "orange": return L("オレンジ")
        case "amber": return L("アンバー")
        case "yellow": return L("黄")
        case "lime": return L("ライム")
        case "green": return L("緑")
        case "teal": return L("ティール")
        case "cyan": return L("シアン")
        case "brown": return L("ブラウン")
        default: return name
        }
    }
    static func color(_ name: String) -> Color {
        if let hex = normalizedHex(name), let rgb = UInt32(hex.dropFirst(), radix: 16) {
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
        }
        switch name {
        case "blue": return Color(red: 0.30, green: 0.58, blue: 0.96)
        case "green": return Color(red: 0.28, green: 0.70, blue: 0.52)
        case "amber": return Color(red: 0.88, green: 0.63, blue: 0.25)
        case "rose": return Color(red: 0.90, green: 0.41, blue: 0.53)
        case "violet": return Color(red: 0.58, green: 0.47, blue: 0.91)
        case "charcoal": return Color(red: 0.24, green: 0.26, blue: 0.29)
        case "indigo": return Color(red: 0.36, green: 0.41, blue: 0.86)
        case "pink": return Color(red: 0.91, green: 0.49, blue: 0.76)
        case "red": return Color(red: 0.88, green: 0.33, blue: 0.31)
        case "orange": return Color(red: 0.94, green: 0.51, blue: 0.24)
        case "yellow": return Color(red: 0.94, green: 0.79, blue: 0.27)
        case "lime": return Color(red: 0.56, green: 0.75, blue: 0.27)
        case "teal": return Color(red: 0.17, green: 0.62, blue: 0.62)
        case "cyan": return Color(red: 0.27, green: 0.71, blue: 0.87)
        case "brown": return Color(red: 0.60, green: 0.45, blue: 0.34)
        default: return Color(red: 0.48, green: 0.50, blue: 0.54)
        }
    }
}

struct ColorPickerRow: View {
    @ObservedObject private var localization = AppLocalization.shared
    @Binding var selection: String
    @State private var input = ""
    private var valid: Bool { Palette.normalizedHex(input) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(L("プリセット")); Spacer()
                PaletteSwatches(selection: $selection, size: 23)
            }
            HStack {
                ColorPicker(L("カラー"), selection: Binding(get: { Palette.color(selection) }, set: { selection = Palette.hex($0) }), supportsOpacity: false)
                TextField("#RRGGBB", text: $input).labelsHidden().textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(width: 110)
                    .accessibilityLabel(L("カラーコード"))
                    .onChange(of: input) { _, value in
                        if let hex = Palette.normalizedHex(value), hex != Palette.hex(Palette.color(selection)) { selection = hex }
                    }
            }
            if !valid { Text(L("#RGB または #RRGGBBで入力してください。現在の色は保持されます。")).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { input = Palette.hex(Palette.color(selection)) }
        .onChange(of: selection) { _, value in
            let hex = Palette.hex(Palette.color(value))
            if Palette.normalizedHex(input) != hex { input = hex }
        }
    }
}

/// The preset colors in rows of eight, so the list can grow without widening forms.
struct PaletteSwatches: View {
    @ObservedObject private var localization = AppLocalization.shared
    @Binding var selection: String
    var size: CGFloat
    var body: some View {
        Grid(horizontalSpacing: size * 0.35, verticalSpacing: size * 0.35) {
            ForEach(Array(stride(from: 0, to: Palette.names.count, by: 8)), id: \.self) { start in
                GridRow {
                    ForEach(Palette.names[start..<min(start + 8, Palette.names.count)], id: \.self) { name in
                        Button { selection = name } label: {
                            Circle().fill(Palette.color(name)).frame(width: size, height: size)
                                .overlay { Circle().strokeBorder(.primary.opacity(0.12)) }
                                .overlay { if selection == name { Image(systemName: "checkmark").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(Palette.ink(name)) } }
                        }.buttonStyle(.plain).help(Palette.displayName(name)).accessibilityLabel(Palette.displayName(name)).accessibilityAddTraits(selection == name ? .isSelected : [])
                    }
                }
            }
        }
    }
}

/// Paints the window's title bar in the app tab color, so the traffic-light strip
/// matches the tab bar below it instead of staying white.
struct TitlebarTint: NSViewRepresentable {
    let color: Color
    let ink: Color
    func makeNSView(context: Context) -> Tint { Tint() }
    func updateNSView(_ view: Tint, context: Context) { view.tint = (NSColor(color), ink == .white); view.apply() }
    final class Tint: NSView {
        var tint: (NSColor, Bool)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            guard let window, let (color, dark) = tint else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = color
            // Only the title bar follows the tint's lightness, so the title stays
            // readable without changing the theme of the page or the tabs.
            window.standardWindowButton(.closeButton)?.superview?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
    }
}
