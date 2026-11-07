import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let set = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(pixels)/1024, y: CGFloat(pixels)/1024)
    let bounds = NSBezierPath(roundedRect: CGRect(x: 70,y: 70,width: 884,height: 884), xRadius: 200, yRadius: 200)
    NSGradient(starting: NSColor(calibratedRed: 0.41,green: 0.32,blue: 0.80,alpha: 1), ending: NSColor(calibratedRed: 0.17,green: 0.14,blue: 0.37,alpha: 1))!.draw(in: bounds, angle: -60)
    for (x,y,w,h,a) in [(200.0,530.0,460.0,230.0,0.25),(280.0,410.0,460.0,230.0,0.55),(360.0,290.0,460.0,230.0,1.0)] {
        NSColor.white.withAlphaComponent(a).setFill()
        NSBezierPath(roundedRect: CGRect(x:x,y:y,width:w,height:h), xRadius:38,yRadius:38).fill()
        NSColor(calibratedRed:0.47,green:0.37,blue:0.85,alpha:a).setFill()
        NSBezierPath(roundedRect: CGRect(x:x+30,y:y+h-63,width:100,height:31), xRadius:10,yRadius:10).fill()
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let png = bitmap.representation(using: .png, properties: [:])!
    let suffix = scale == 2 ? "@2x" : ""
    try png.write(to: set.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
