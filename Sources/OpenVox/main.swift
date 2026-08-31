import Cocoa

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu-bar only; Info.plist LSUIElement covers the bundled case
app.run()
