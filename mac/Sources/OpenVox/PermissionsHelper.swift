import AVFoundation
import ApplicationServices
import Cocoa
import SwiftUI

/// Microphone and Accessibility permission checks + prompts + deep links
/// to the relevant System Settings pane.
enum PermissionsHelper {
    static func micAuthorized() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Raw status, read-only -- never prompts. Callers branch on
    /// `.notDetermined` (ok to prompt now) vs `.denied`/`.restricted`
    /// (must send the user to System Settings instead).
    static func micAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMic(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// `prompt: true` shows the system "OpenVox would like to control this
    /// computer" dialog once; pass false for a silent status poll.
    static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        if !prompt { return AXIsProcessTrusted() }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Reads both grants into `appState`. macOS sends no notification when
    /// a grant changes, so the app reads them again on its own.
    static func refresh(_ appState: AppState) {
        appState.micPermissionGranted = micAuthorized()
        appState.accessibilityGranted = isAccessibilityTrusted()
    }

    static func openMicPrivacySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Reads the permission flags on `AppState` when the view appears.
/// AppDelegate reads them again on app activation, and polls while a grant
/// is missing (see AppDelegate.updatePermissionPoll). Do not add a timer
/// here: a closed window keeps its SwiftUI views and their timers, so a
/// timer here ran all day.
private struct PermissionsRefresh: ViewModifier {
    let appState: AppState

    func body(content: Content) -> some View {
        content.onAppear { PermissionsHelper.refresh(appState) }
    }
}

extension View {
    /// Re-reads the microphone and Accessibility grants into `appState` when
    /// this view appears.
    func refreshesPermissions(_ appState: AppState) -> some View {
        modifier(PermissionsRefresh(appState: appState))
    }
}
