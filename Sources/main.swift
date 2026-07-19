// main.swift — native macOS live viewer + NVR playback for Hikvision cameras.
//
// One window, a grid of live tiles, one per directly-reachable camera.
// Pipeline per camera:
//   ffmpeg (RTSP -> raw Annex B HEVC/H.264 on stdout, stream copy, no transcode)
//   -> NAL splitter/access-unit assembler -> CMSampleBuffer
//   -> AVSampleBufferDisplayLayer (hardware decode).
//
// Build: ./build.sh   (compiles Sources/*.swift; see README)
// All config lives in the Settings window (Cmd-,), stored in a 0600 JSON file
// (~/Library/Application Support/hikviewer/config.json), which is also the
// File > Export / Import format.
// The grid runs on the substream (channel 102); double-clicking a tile focuses
// it full-window on the camera's main stream (101). On a focused tile, P opens
// recorded-footage playback from the NVR (space pauses, arrows seek, Esc back
// to live). Esc returns to the grid, Cmd-Q quits. Long-pressing a tile lifts
// it for drag-to-reorder (Esc cancels); the new order is saved.

import AppKit

let cliArgs = Array(CommandLine.arguments.dropFirst())
// Utility: render the app icon to a PNG at a given pixel size (for previewing
// or building the .icns / .app).  Usage: --icon <path> [size]
if let i = cliArgs.firstIndex(of: "--icon") {
    let out = cliArgs.indices.contains(i + 1) ? cliArgs[i + 1] : "hikviewer-icon.png"
    let size = cliArgs.indices.contains(i + 2) ? (Double(cliArgs[i + 2]).map { CGFloat($0) } ?? 512) : 512
    let img = makeAppIcon(size)
    let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let props = [NSBitmapImageRep.PropertyKey: Any]()
    if let png = target.representation(using: NSBitmapImageRep.FileType.png, properties: props) {
        try? png.write(to: URL(fileURLWithPath: out))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
let settingsItem = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
settingsItem.target = delegate
appMenu.addItem(settingsItem)
let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
updateItem.target = delegate
appMenu.addItem(updateItem)
appMenu.addItem(.separator())
// Standard Hide items — without a menu item, Cmd-H does nothing at all.
appMenu.addItem(withTitle: "Hide HikViewer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
hideOthers.keyEquivalentModifierMask = [.command, .option]
appMenu.addItem(hideOthers)
appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Quit HikViewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu

let fileMenuItem = NSMenuItem()
mainMenu.addItem(fileMenuItem)
let fileMenu = NSMenu(title: "File")
let exportItem = NSMenuItem(title: "Export Cameras…", action: #selector(AppDelegate.exportCameras(_:)), keyEquivalent: "e")
exportItem.target = delegate
let importItem = NSMenuItem(title: "Import Cameras…", action: #selector(AppDelegate.importCameras(_:)), keyEquivalent: "i")
importItem.target = delegate
fileMenu.addItem(exportItem)
fileMenu.addItem(importItem)
fileMenuItem.submenu = fileMenu

app.mainMenu = mainMenu
app.run()
