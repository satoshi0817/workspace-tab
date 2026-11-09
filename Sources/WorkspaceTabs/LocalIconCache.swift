import AppKit
import ImageIO

/// Icon names are immutable UUID files. Replacing an icon creates a new name.
@MainActor final class LocalIconCache {
    private let images=NSCache<NSString,NSImage>()
    private(set) var decodeCount=0
    init() {images.countLimit=256;images.totalCostLimit=16*1024*1024}
    func image(directory:URL,name:String)->NSImage? {
        guard !name.isEmpty,name == URL(fileURLWithPath:name).lastPathComponent else{return nil}
        let file=directory.appendingPathComponent("Icons").appendingPathComponent(name)
        let key=file.path as NSString
        if let image=images.object(forKey:key) {return image}
        let image:NSImage
        var cost=128*128*4
        if let source=CGImageSourceCreateWithURL(file as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
           let thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:128,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) {
            image=NSImage(cgImage:thumbnail,size:NSSize(width:thumbnail.width,height:thumbnail.height))
            cost=thumbnail.bytesPerRow*thumbnail.height
        } else {
            // AppKit supports vector formats such as Notion's SVG icons.
            guard let original=NSImage(contentsOf:file),original.size.width>0,original.size.height>0 else{return nil}
            let ratio=min(128/original.size.width,128/original.size.height)
            let size=NSSize(width:original.size.width*ratio,height:original.size.height*ratio)
            image=NSImage(size:size);image.lockFocus();original.draw(in:NSRect(origin:.zero,size:size));image.unlockFocus()
        }
        image.isTemplate=name.contains(".template.")
        images.setObject(image,forKey:key,cost:cost);decodeCount += 1
        return image
    }
}
