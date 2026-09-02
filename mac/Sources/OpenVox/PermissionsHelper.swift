import AVFoundation
import ApplicationServices
import Cocoa

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
