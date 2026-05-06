import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    showMainWindow()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    showMainWindow()
    DropViewModel.shared.handleDroppedURLs(urls)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private func showMainWindow() {
    if let window {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let hostingController = NSHostingController(rootView: ContentView())
    let window = NSWindow(contentViewController: hostingController)
    window.setContentSize(NSSize(width: 860, height: 520))
    window.contentMinSize = NSSize(width: 640, height: 360)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    if #available(macOS 11.0, *) {
      window.toolbarStyle = .unified
    }
    window.center()
    window.makeKeyAndOrderFront(nil)

    self.window = window
  }
}

@main
struct EBUR128App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}
