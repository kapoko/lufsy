import AppKit
import SparkleUpdater
import SwiftUI

#if LUFSY_PRO
  import LufsyPro
#endif

@MainActor
enum AppDependencies {
  static let updateCoordinator = UpdateCoordinator(
    configuration: .init(
      betaUpdatesEnabledProvider: {
        UserDefaults.standard.bool(forKey: UpdateSettings.defaultsKeys().betaUpdatesEnabled)
      }
    ))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    styleMainWindowIfAvailable()
    AppDependencies.updateCoordinator.initializeUpdater()
    AppDependencies.updateCoordinator.performStartupCheckIfNeeded()
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    NSApp.activate(ignoringOtherApps: true)
    styleMainWindowIfAvailable()
    DropViewModel.shared.handleDroppedURLs(urls)
  }

  private func styleMainWindowIfAvailable() {
    guard let window = NSApp.windows.first else { return }
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    if #available(macOS 11.0, *) {
      window.toolbarStyle = .unified
    }

    #if LUFSY_PRO
      LufsyProAppHook.styleMainWindow(window)
    #endif
  }
}

@main
struct LufsyApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var updateCoordinator = AppDependencies.updateCoordinator

  var body: some Scene {
    WindowGroup {
      ContentView()
        .frame(minWidth: 640, minHeight: 360)
    }

    Settings {
      VStack(alignment: .leading, spacing: 12) {
        UpdatesSettingsView(updateCoordinator: updateCoordinator)
      }
      .frame(width: 480, height: 250)
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
