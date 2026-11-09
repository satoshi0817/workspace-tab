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
    static let appRadius:CGFloat = 12
    static let pageRadius:CGFloat = 16
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "システム"
        case .light: return "ライト"
        case .dark: return "ダーク"
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
    private static let groupMenuLabels=NSCache<NSString,NSImage>()
    static func groupMenuLabel(_ title:String,ink:Color)->NSImage {
        let key=(hex(ink)+"|"+title) as NSString
        if let image=groupMenuLabels.object(forKey:key) {return image}
        let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
        let attributes:[NSAttributedString.Key:Any]=[
            .font:NSFont.systemFont(ofSize:12,weight:.semibold),
            .foregroundColor:NSColor(ink),.paragraphStyle:paragraph
        ]
        let text=NSAttributedString(string:title,attributes:attributes)
        let width=min(130,ceil(text.size().width))
        let image=NSImage(size:NSSize(width:width+18,height:20))
        image.lockFocus()
        text.draw(in:NSRect(x:0,y:2,width:width,height:17))
        let arrow=NSBezierPath();arrow.lineWidth=1.4;arrow.lineCapStyle = .round;arrow.lineJoinStyle = .round
        arrow.move(to:NSPoint(x:width+6,y:12));arrow.line(to:NSPoint(x:width+10,y:8));arrow.line(to:NSPoint(x:width+14,y:12))
        NSColor(ink).setStroke();arrow.stroke()
        image.unlockFocus();image.isTemplate=false
        groupMenuLabels.countLimit=128;groupMenuLabels.setObject(image,forKey:key)
        return image
    }
    static let names = ["violet", "blue", "green", "amber", "rose", "gray"]
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
    static func color(_ name: String) -> Color {
        if let hex = normalizedHex(name), let rgb = UInt32(hex.dropFirst(), radix: 16) {
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
        }
        switch name {
        case "blue": return Color(red: 0.30, green: 0.58, blue: 0.96)
        case "green": return Color(red: 0.28, green: 0.70, blue: 0.52)
        case "amber": return Color(red: 0.88, green: 0.63, blue: 0.25)
        case "rose": return Color(red: 0.90, green: 0.41, blue: 0.53)
        case "gray": return Color(red: 0.48, green: 0.50, blue: 0.54)
        default: return Color(red: 0.58, green: 0.47, blue: 0.91)
        }
    }
}

struct ColorPickerRow: View {
    @Binding var selection: String
    @State private var input = ""
    private var valid: Bool { Palette.normalizedHex(input) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("プリセット"); Spacer()
                ForEach(Palette.names, id: \.self) { name in
                    Button { selection = name } label: {
                        Circle().fill(Palette.color(name)).frame(width: 23, height: 23)
                            .overlay { if selection == name { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.ink(name)) } }
                    }.buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(selection == name ? .isSelected : [])
                }
            }
            HStack {
                ColorPicker("カラー", selection: Binding(get: { Palette.color(selection) }, set: { selection = Palette.hex($0) }), supportsOpacity: false)
                TextField("#RRGGBB", text: $input).labelsHidden().textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(width: 110)
                    .accessibilityLabel("カラーコード")
                    .onChange(of: input) { _, value in
                        if let hex = Palette.normalizedHex(value), hex != Palette.hex(Palette.color(selection)) { selection = hex }
                    }
            }
            if !valid { Text("#RGB または #RRGGBBで入力してください。現在の色は保持されます。").font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { input = Palette.hex(Palette.color(selection)) }
        .onChange(of: selection) { _, value in
            let hex = Palette.hex(Palette.color(value))
            if Palette.normalizedHex(input) != hex { input = hex }
        }
    }
}
