import AppKit

// Plain AppKit entry point: Clipper is a status-bar app with one floating
// panel and one preferences window, so the SwiftUI `App` lifecycle (which
// insists on a primary scene) buys nothing here.
// Defaults must exist before the engine reads the storage policy.
PrefKey.registerDefaults()
// Top-level code is not main-actor isolated in Swift 5 language mode; it does
// run on the main thread, so asserting isolation here is sound.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.run()
}
