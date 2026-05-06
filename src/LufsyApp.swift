import AppKit
import SparkleUpdater
import SwiftUI

@MainActor
enum AppDependencies {
  static let updateCoordinator = UpdateCoordinator(
    configuration: .init(
      feedURLStringProvider: {
        #if arch(arm64)
          return "https://example.com/appcast-arm64.xml"
        #else
          return "https://example.com/appcast-x86_64.xml"
        #endif
      },
      betaUpdatesEnabledProvider: {
        UserDefaults.standard.bool(forKey: UpdateSettings.defaultsKeys().betaUpdatesEnabled)
      }
    ))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    AppDependencies.updateCoordinator.initializeUpdater()
    showMainWindow()
    AppDependencies.updateCoordinator.performStartupCheckIfNeeded()
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
struct LufsyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var updateCoordinator = AppDependencies.updateCoordinator

  var body: some Scene {
    Settings {
      UpdatesSettingsView(updateCoordinator: updateCoordinator)
    }
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Check for Updates...") {
          AppDependencies.updateCoordinator.checkForUpdates()
        }
      }
    }
  }
}
