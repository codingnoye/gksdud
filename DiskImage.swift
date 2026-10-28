// Lays out the disk image window that has the app beside a link to Applications, for build.sh.
//   disk-image background <file>   draws the arrow between the two icons, at 1x and 2x
//   disk-image layout <volume>     marks the volume's custom icon and writes its .DS_Store
// The .DS_Store points at the background with a bookmark of that very volume, which keeps its identity when the image is
// converted; one copied from another image leaves the window white.
import AppKit

let window = NSRect(x: 200, y: 120, width: 560, height: 340)
let iconSize = 128.0
// Icon centres from the top left of the window's content.
let appCentre = NSPoint(x: 150, y: 160), applicationsCentre = NSPoint(x: 410, y: 160)

func drawBackground(to path: String) throws {
  let image = NSImage(size: window.size)
  for scale in [1.0, 2.0] {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(window.width * scale), pixelsHigh: Int(window.height * scale),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
      bitsPerPixel: 0)!
    rep.size = window.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(starting: NSColor(white: 0.985, alpha: 1), ending: NSColor(white: 0.93, alpha: 1))!
      .draw(in: NSRect(origin: .zero, size: window.size), angle: -90)
    // The SF Symbol, midway between the icons.
    let configuration = NSImage.SymbolConfiguration(pointSize: 48, weight: .semibold)
      .applying(.init(hierarchicalColor: NSColor(white: 0.6, alpha: 1)))
    let arrow = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)!
      .withSymbolConfiguration(configuration)!
    let centre = NSPoint(x: (appCentre.x + applicationsCentre.x) / 2, y: window.height - appCentre.y)
    arrow.draw(in: NSRect(x: centre.x - arrow.size.width / 2, y: centre.y - arrow.size.height / 2,
                          width: arrow.size.width, height: arrow.size.height))
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(rep)
  }
  try image.tiffRepresentation(using: .lzw, factor: 1)!.write(to: URL(fileURLWithPath: path))
}

// The kHasCustomIcon Finder flag on the volume root shows its .VolumeIcon.icns.
func markCustomIcon(_ volume: String) {
  var info = [UInt8](repeating: 0, count: 32)
  _ = getxattr(volume, "com.apple.FinderInfo", &info, 32, 0, 0)
  info[8] |= 0x04
  guard setxattr(volume, "com.apple.FinderInfo", info, 32, 0, 0) == 0 else { fatalError("Cannot mark the volume icon") }
}

// A .DS_Store is a B-tree of records in a buddy allocator; one leaf holds these few, as Finder writes it.
struct Record {
  let name: String, code: String, type: String, value: Data

  static func blob(_ name: String, _ code: String, _ data: Data) -> Record {
    Record(name: name, code: code, type: "blob", value: uint32(data.count) + data)
  }
  static func plist(_ name: String, _ code: String, _ value: [String: Any]) -> Record {
    blob(name, code, try! PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0))
  }
  static func location(_ name: String, _ point: NSPoint) -> Record {
    blob(name, "Iloc", uint32(Int(point.x)) + uint32(Int(point.y)) + uint32(0xFFFF_FFFF) + uint32(0xFFFF_0000))
  }

  var encoded: Data {
    let units = Array(name.utf16)
    return uint32(units.count) + Data(units.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
      + Data(code.utf8) + Data(type.utf8) + value
  }
}

func uint32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }

func writeStore(_ records: [Record], to path: String) throws {
  // Header at 0 (32 bytes), the database block at 32 (32), the root block at 2048 (2048), the leaf at 4096 (4096).
  // Offsets count from byte 4 of the file; a block's address is its offset with log2 of its size in the low bits.
  var file = Data(count: 4 + 8192)
  func put(_ data: Data, at offset: Int) { file.replaceSubrange(4 + offset..<4 + offset + data.count, with: data) }
  file.replaceSubrange(0..<4, with: uint32(1))
  put(Data("Bud1".utf8) + uint32(2048) + uint32(2048) + uint32(2048)
      + Data([0, 0, 0x10, 0x0C, 0, 0, 0, 0x87, 0, 0, 0x20, 0x0B, 0, 0, 0, 0]), at: 0)
  var root = uint32(3) + uint32(0) + uint32(2048 | 11) + uint32(32 | 5) + uint32(4096 | 12) + Data(count: 253 * 4)
  root += uint32(1) + Data([4]) + Data("DSDB".utf8) + uint32(1)
  // Free blocks: one of each width from 6 to 10 and from 13 to 30, at the offset of that size.
  for width in 0..<32 {
    root += (6...10).contains(width) || (13...30).contains(width) ? uint32(1) + uint32(1 << width) : uint32(0)
  }
  put(root, at: 2048)
  // Root node (block 2), no levels below it, the records, one node, 4096-byte pages.
  put(uint32(2) + uint32(0) + uint32(records.count) + uint32(1) + uint32(4096), at: 32)
  let leaf = records.reduce(uint32(0) + uint32(records.count)) { $0 + $1.encoded }
  guard leaf.count <= 4096 else { fatalError("The .DS_Store records do not fit one page") }
  put(leaf, at: 4096)
  try file.write(to: URL(fileURLWithPath: path))
}

func layout(_ volume: String) throws {
  markCustomIcon(volume)
  let background = try URL(fileURLWithPath: "\(volume)/.background.tiff")
    .bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
  let bounds = "{{\(Int(window.minX)), \(Int(window.minY))}, {\(Int(window.width)), \(Int(window.height))}}"
  // Sorted by name without case, then by code. Finder ignores the view options, background and icon size, without the
  // background colour.
  try writeStore([
    .plist(".", "bwsp", ["ContainerShowSidebar": false, "PreviewPaneVisibility": false, "ShowPathbar": false,
                         "ShowSidebar": false, "ShowStatusBar": false, "ShowTabView": false, "ShowToolbar": false,
                         "SidebarWidth": 180, "WindowBounds": bounds]),
    Record(name: ".", code: "icvl", type: "type", value: Data("icnv".utf8)),
    .plist(".", "icvp", ["arrangeBy": "none", "backgroundColorBlue": 1.0, "backgroundColorGreen": 1.0,
                         "backgroundColorRed": 1.0, "backgroundType": 2, "gridOffsetX": 0.0, "gridOffsetY": 0.0,
                         "gridSpacing": 100.0, "iconSize": iconSize, "labelOnBottom": true, "showIconPreview": true,
                         "showItemInfo": false, "textSize": 13.0, "viewOptionsVersion": 1]),
    .blob(".", "pBBk", background),
    Record(name: ".", code: "vSrn", type: "long", value: uint32(1)),
    .location("Applications", applicationsCentre),
    .location("gksdud.app", appCentre),
  ], to: "\(volume)/.DS_Store")
}

let arguments = CommandLine.arguments
switch (arguments.count, arguments.count > 1 ? arguments[1] : "") {
case (3, "background"): try drawBackground(to: arguments[2])
case (3, "layout"): try layout(arguments[2])
default:
  FileHandle.standardError.write(Data("usage: disk-image background <file> | layout <volume>\n".utf8))
  exit(2)
}
