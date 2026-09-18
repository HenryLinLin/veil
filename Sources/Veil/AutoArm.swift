import AppKit

final class AutoArm {
    var onSharing: ((Bool, Bool) -> Void)?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var enabled = false
    private var lastSeen: TimeInterval = 0
    private var active = false
    private let meetingApps = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox", "com.cisco.webexmeetingsapp"]
    func configure(enabled: Bool) {
        stop()
        self.enabled = enabled
        guard enabled else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateWatch() })
        }
        updateWatch()
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        enabled = false
        active = false
        lastSeen = 0
    }
    private func updateWatch() {
        let candidate = NSWorkspace.shared.runningApplications.contains { meetingApps.contains($0.bundleIdentifier ?? "") }
        guard enabled && candidate else {
            timer?.invalidate(); timer = nil
            if active { active = false; onSharing?(false, false) }
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        check()
    }
    private func check() {
        let candidates = ScreenWindow.visible().filter { meetingApps.contains($0.app) }
        // TODO: recognize localized sharing toolbars.
        let sharing = candidates.first { window in
            let title = window.title.lowercased()
            return title.contains("you are sharing") || title.contains("stop sharing") || title.contains("sharing toolbar") || title.contains("screen sharing toolbar")
        }
        if let sharing {
            lastSeen = ProcessInfo.processInfo.systemUptime
            if !active { active = true; onSharing?(true, sharing.title.lowercased().contains("window")) }
        } else if active && ProcessInfo.processInfo.systemUptime - lastSeen > 4 {
            active = false
            onSharing?(false, false)
        }
    }
}
