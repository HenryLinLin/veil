import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "shield", accessibilityDescription: "Veil is off")
        let menu = NSMenu()
        menu.addItem(withTitle: "Veil · Off", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Veil", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
