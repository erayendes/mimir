import AppKit

// Plain AppKit entry point. Mimir is a menu-bar-only app: every surface it has is built by
// AppDelegate (status item, the SwiftUI panel inside an NSHostingView), and it has no window a
// SwiftUI `App` would own. The `App` lifecycle it used to have needed a `Scene` to compile, which
// meant a `Settings` scene holding an EmptyView — and macOS dutifully gave that scene a
// "Settings…" menu item and a ⌘, that opened a blank window. Removing the menu item wasn't enough
// (the scene reinstalls it), so the scene is gone and with it the window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
