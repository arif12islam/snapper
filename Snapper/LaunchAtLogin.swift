import ServiceManagement
import Foundation

/// Single place that talks to SMAppService so the menu and Settings stay in step.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func apply(_ enabled: Bool) {
        do {
            if enabled, !isEnabled {
                try SMAppService.mainApp.register()
            } else if !enabled, isEnabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Snapper: launch-at-login change failed: \(error)")
        }
    }

    /// Mirrors the real system state into the stored preference (called at launch).
    static func syncPreference() {
        UserDefaults.standard.set(isEnabled, forKey: "launchAtLogin")
    }
}
