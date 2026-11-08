import AppKit

// One vector mark supplies both the Dock icon and the in-app menu button.
func drawMark(in rect:CGRect, color:NSColor) {
    let context=NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.translateBy(x:rect.minX,y:rect.minY)
    context.scaleBy(x:rect.width/100,y:rect.height/100)
    color.setStroke();color.setFill()
    let rear=NSBezierPath()
    rear.move(to:NSPoint(x:18,y:38));rear.line(to:NSPoint(x:18,y:74))
    rear.curve(to:NSPoint(x:26,y:82),controlPoint1:NSPoint(x:18,y:79),controlPoint2:NSPoint(x:21,y:82))
    rear.line(to:NSPoint(x:70,y:82))
    rear.lineWidth=6;rear.lineCapStyle = .round;rear.lineJoinStyle = .round;rear.stroke()
    let front=NSBezierPath(roundedRect:CGRect(x:28,y:18,width:58,height:54),xRadius:8,yRadius:8)
    front.lineWidth=6;front.stroke()
    let divider=NSBezierPath()
    divider.move(to:NSPoint(x:46,y:21));divider.line(to:NSPoint(x:46,y:69))
    divider.lineWidth=5;divider.stroke()
    NSBezierPath(roundedRect:CGRect(x:33,y:55,width:7,height:5),xRadius:2.5,yRadius:2.5).fill()
    context.restoreGState()
}

let output=URL(fileURLWithPath:CommandLine.arguments[1])
let set=output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at:set,withIntermediateDirectories:true)
for (points,scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels=points*scale
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    let context=NSGraphicsContext.current!.cgContext
    context.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
    let tile=NSBezierPath(roundedRect:CGRect(x:70,y:70,width:884,height:884),xRadius:198,yRadius:198)
    NSGradient(starting:NSColor(white:0.16,alpha:1),ending:NSColor(white:0.055,alpha:1))!.draw(in:tile,angle:-90)
    NSColor(white:1,alpha:0.14).setStroke();tile.lineWidth=2;tile.stroke()
    drawMark(in:CGRect(x:86,y:102,width:820,height:820),color:NSColor(white:0.98,alpha:1))
    NSGraphicsContext.restoreGraphicsState()
    let png=bitmap.representation(using:.png,properties:[:])!
    let suffix=scale == 2 ? "@2x":""
    try png.write(to:set.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}

// A vector PDF remains sharp at any display scale; runtime applies the tab's ink.
let data=NSMutableData()
let consumer=CGDataConsumer(data:data as CFMutableData)!
var mediaBox=CGRect(x:0,y:0,width:24,height:24)
let pdf=CGContext(consumer:consumer,mediaBox:&mediaBox,nil)!
pdf.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current=NSGraphicsContext(cgContext:pdf,flipped:false)
drawMark(in:mediaBox,color:.black)
NSGraphicsContext.restoreGraphicsState()
pdf.endPDFPage();pdf.closePDF()
try (data as Data).write(to:output.appendingPathComponent("AppMark.pdf"))

let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/bin/iconutil")
task.arguments=["-c","icns",set.path,"-o",output.appendingPathComponent("AppIcon.icns").path]
try task.run();task.waitUntilExit()
guard task.terminationStatus == 0 else{exit(task.terminationStatus)}
