import AppKit
import Foundation
let output = URL(fileURLWithPath: CommandLine.arguments[1])
func bigEndian(_ value: UInt32) -> Data { var value = value.bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
var chunks = Data()
for (type, pixels) in [("icp4",16),("icp5",32),("icp6",64),("ic07",128),("ic08",256),("ic09",512),("ic10",1024)] {
    let p = CGFloat(pixels)
    let image = NSImage(size: NSSize(width:p,height:p))
    image.lockFocus()
    NSColor(calibratedRed:0.11,green:0.12,blue:0.15,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:p*0.04,y:p*0.04,width:p*0.92,height:p*0.92),xRadius:p*0.20,yRadius:p*0.20).fill()
    NSColor(calibratedRed:0.94,green:0.22,blue:0.25,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:p*0.18,y:p*0.31,width:p*0.64,height:p*0.45),xRadius:p*0.09,yRadius:p*0.09).fill()
    NSColor.white.setFill()
    let triangle=NSBezierPath();triangle.move(to:NSPoint(x:p*0.44,y:p*0.43));triangle.line(to:NSPoint(x:p*0.44,y:p*0.65));triangle.line(to:NSPoint(x:p*0.63,y:p*0.54));triangle.close();triangle.fill()
    NSColor(calibratedRed:0.8,green:0.82,blue:0.86,alpha:1).setStroke()
    let lines=NSBezierPath();lines.lineWidth=p*0.025;lines.lineCapStyle = .round
    for y in [0.20,0.25] { lines.move(to:NSPoint(x:p*0.28,y:p*y));lines.line(to:NSPoint(x:p*0.72,y:p*y)) };lines.stroke()
    image.unlockFocus()
    let png=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
    chunks.append(Data(type.utf8));chunks.append(bigEndian(UInt32(png.count+8)));chunks.append(png)
}
var icon=Data("icns".utf8);icon.append(bigEndian(UInt32(chunks.count+8)));icon.append(chunks);try icon.write(to:output)
