// MacosAgent: Phase 1 - menu bar app shell.
//
// Runs as a status-bar-only app (no Dock icon, no main window). Two capabilities wired
// together here, each already confirmed working in isolation:
//   - FSEventsWatcher: watches ~/Downloads for new files (AirDrop's default save location -
//     confirmed by this app's own logging combined with a real AirDrop send; see
//     ../docs/ARCHITECTURE.md open questions).
//   - sendViaAirDrop: opens the native AirDrop picker for a chosen file, via the public
//     NSSharingService API.
//
// Phase 3 wires both of these to the actual network relay; this file is Phase 1 scope only.

import AppKit
import CoreServices
import Foundation
import UserNotifications
import os

let logger = Logger(subsystem: "com.airbridge.macos-agent", category: "general")

/// Watches one or more directories for file-system changes using the low-level FSEvents API.
///
/// A class (not a struct) because FSEventStreamCreate needs a stable pointer identity to pass
/// through its C callback context.
final class DownloadsWatcher {
    private var stream: FSEventStreamRef?
    private let pathsToWatch: [String]
    private let onPathChanged: (String) -> Void

    init(paths: [String], onPathChanged: @escaping (String) -> Void) {
        self.pathsToWatch = paths
        self.onPathChanged = onPathChanged
    }

    func start() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, _, _ in
            guard let info = clientCallBackInfo else { return }
            let watcher = Unmanaged<DownloadsWatcher>.fromOpaque(info).takeUnretainedValue()
            let pathsArray = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for index in 0..<numEvents {
                let path = String(cString: pathsArray[index])
                watcher.onPathChanged(path)
            }
        }

        guard
            let streamRef = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                pathsToWatch as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0,
                UInt32(kFSEventStreamCreateFlagFileEvents)
            )
        else {
            logger.error("Failed to create FSEventStream")
            return
        }

        stream = streamRef
        FSEventStreamSetDispatchQueue(streamRef, DispatchQueue.main)
        FSEventStreamStart(streamRef)
        logger.info("Watching \(self.pathsToWatch.joined(separator: ", "), privacy: .public)")
    }

    func stop() {
        guard let streamRef = stream else { return }
        FSEventStreamStop(streamRef)
        FSEventStreamInvalidate(streamRef)
        FSEventStreamRelease(streamRef)
        stream = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {
    private var statusItem: NSStatusItem?
    private var watcher: DownloadsWatcher?
    private var recentlyDetected: [String] = []
    /// FSEvents reports multiple events per path for a single AirDrop save (create, then one
    /// or more writes/renames as the file is finalized) - confirmed via real AirDrop testing,
    /// which pushed the same file 3 times. Debounce by only pushing a given path once per
    /// window; AirDrop/Finder saves complete well within this.
    private var lastPushedAt: [String: Date] = [:]
    private let pushDebounceWindow: TimeInterval = 5
    private var server: AgentServer?

    // NSSharingService's perform(withItems:) is asynchronous - the whole AirDrop UI flow and
    // transfer run after this call returns. If nothing retains the service instance, ARC frees
    // it as soon as the creating function's scope exits, which tears down the operation right
    // as the user picks a destination (this was the actual cause of "shows waiting, then
    // failed" - confirmed via sharingd's log showing our process's XPC connection invalidated
    // ~1.5s into the session, transfersInitiated: 0). Apple's own sample code always keeps a
    // strong reference to the in-flight service for this reason; this property is that
    // reference.
    private var activeSharingService: NSSharingService?

    /// Opens the native AirDrop send picker for the given file, using the public,
    /// Apple-documented NSSharingService API - not a workaround or private API.
    func sendViaAirDrop(fileURL: URL) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            logger.error("AirDrop sharing service is unavailable on this system")
            return
        }
        guard service.canPerform(withItems: [fileURL]) else {
            logger.error("AirDrop cannot perform with item: \(fileURL.path, privacy: .public)")
            return
        }
        service.delegate = self
        activeSharingService = service
        service.perform(withItems: [fileURL])
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        logger.error("AirDrop send failed: \(error.localizedDescription, privacy: .public)")
        activeSharingService = nil
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        logger.info("AirDrop send completed")
        activeSharingService = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestNotificationAuthorization()
        setUpStatusItem()
        startServer()
        startWatchingDownloads()
    }

    /// UNUserNotificationCenter requires a real .app bundle with a bundle identifier - without
    /// one it doesn't just fail silently, it hits an assertion failure in
    /// UNUserNotificationCenter.m that crashes the whole process (confirmed directly: the
    /// agent died on launch the moment this was called against the raw `swift build` output).
    /// Fixed by always running this binary from inside AirBridge.app (see
    /// ../package-app.sh / ../CLAUDE.md), not the loose .build/debug/MacosAgent executable.
    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                logger.error("Notification authorization error: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to show notification: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func startServer() {
        do {
            let identity = try TLSIdentityStore.loadOrCreate()
            let server = AgentServer(identity: identity) { [weak self] fileURL in
                DispatchQueue.main.async {
                    self?.handleFileReceivedFromAndroid(fileURL)
                }
            }
            server.start()
            self.server = server
            refreshPairingMenuItem()
        } catch {
            logger.error("Failed to start TLS server: \(String(describing: error), privacy: .public)")
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "⇄"
        item.button?.toolTip = "AirDrop Bridge Agent"

        // Indices below are load-bearing: refreshPairingMenuItem() and
        // refreshRecentlyDetectedMenu() index into this menu directly rather than searching by
        // title, so keep this list and those two functions' comments in sync.
        let menu = NSMenu()
        menu.addItem(                                                                     // 0
            withTitle: "Send File to Phone…",
            action: #selector(chooseFileAndSendToPhone),
            keyEquivalent: ""
        ).target = self
        menu.addItem(NSMenuItem.separator())                                               // 1
        menu.addItem(                                                                      // 2
            withTitle: "Send File via Real AirDrop (to an Apple device)…",
            action: #selector(chooseFileAndSend),
            keyEquivalent: ""
        ).target = self
        menu.addItem(NSMenuItem.separator())                                               // 3
        menu.addItem(withTitle: "Pairing code: ------", action: nil, keyEquivalent: "")    // 4
            .isEnabled = false
        menu.addItem(                                                                      // 5
            withTitle: "Regenerate Pairing Code…",
            action: #selector(regeneratePairingCode),
            keyEquivalent: ""
        ).target = self
        menu.addItem(NSMenuItem.separator())                                               // 6
        menu.addItem(                                                                      // 7
            withTitle: "Recently detected Downloads:",
            action: nil,
            keyEquivalent: ""
        ).isEnabled = false
        menu.addItem(withTitle: "(none yet)", action: nil, keyEquivalent: "").isEnabled = false // 8
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    private func startWatchingDownloads() {
        let downloadsPath = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
        logger.info("Starting Downloads watcher at \(downloadsPath, privacy: .public)")
        let watcher = DownloadsWatcher(paths: [downloadsPath]) { [weak self] path in
            self?.handleDetectedPath(path)
        }
        watcher.start()
        self.watcher = watcher
    }

    private func handleDetectedPath(_ path: String) {
        logger.info("Path changed: \(path, privacy: .public)")
        recentlyDetected.insert(path, at: 0)
        recentlyDetected = Array(recentlyDetected.prefix(5))
        refreshRecentlyDetectedMenu()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return
        }

        let now = Date()
        if let lastPush = lastPushedAt[path], now.timeIntervalSince(lastPush) < pushDebounceWindow {
            logger.info("Debounced duplicate FSEvents push for \(path, privacy: .public)")
            return
        }
        lastPushedAt[path] = now

        let fileURL = URL(fileURLWithPath: path)
        server?.pushFile(at: fileURL) { [weak self] success in
            DispatchQueue.main.async {
                guard success else { return }
                self?.showNotification(title: "AirBridge", body: "Sent \(fileURL.lastPathComponent) to your phone")
            }
        }
    }

    /// Android -> Mac direction: the file already landed in ~/Downloads (AgentServer wrote it
    /// directly there - see docs/PROTOCOL.md). Pre-mark it in the debounce dict *before*
    /// FSEvents can fire for it, so the Mac->Android watcher doesn't immediately bounce the
    /// same file right back to the phone it just came from.
    private func handleFileReceivedFromAndroid(_ fileURL: URL) {
        lastPushedAt[fileURL.path] = Date()
        logger.info("Saved \(fileURL.lastPathComponent, privacy: .public) from Android to Downloads")
        showNotification(title: "AirBridge", body: "Received \(fileURL.lastPathComponent) from your phone")
    }

    @objc private func regeneratePairingCode() {
        server?.regeneratePairingCode()
        refreshPairingMenuItem()
    }

    private func refreshPairingMenuItem() {
        guard let menu = statusItem?.menu, let server else { return }
        // Item index 4 is the "Pairing code: ------" placeholder set up in setUpStatusItem().
        let address = localIPv4Address() ?? "(no Wi-Fi address found)"
        menu.items[4].title = "Pair at \(address):47835, code \(server.currentPairingCode)"
    }

    /// First non-loopback IPv4 address of an up network interface - shown to the user so they
    /// can manually enter it on the Android side. mDNS auto-discovery is also attempted on the
    /// Android side, but real home/mesh routers often block multicast between Wi-Fi clients
    /// even when plain unicast TCP works fine between them - confirmed on this exact network
    /// during testing, so manual entry is the primary path, not just a fallback.
    private func localIPv4Address() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return nil }
        defer { freeifaddrs(addresses) }

        var cursor = addresses
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  current.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var address = sockaddr_in()
            memcpy(&address, current.pointee.ifa_addr, Int(MemoryLayout<sockaddr_in>.size))
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(NI_MAXHOST))
            return String(cString: buffer)
        }
        return nil
    }

    private func refreshRecentlyDetectedMenu() {
        guard let menu = statusItem?.menu else { return }
        // Items: [0] Send to Phone…, [1] sep, [2] Send via real AirDrop…, [3] sep,
        // [4] pairing code, [5] regenerate, [6] sep, [7] header, [8...] entries, [sep], [Quit].
        // Rebuild the dynamic middle section each time rather than tracking indices by hand.
        let fixedPrefix = 9
        while menu.items.count > fixedPrefix + 1 {
            menu.removeItem(at: fixedPrefix)
        }
        if recentlyDetected.isEmpty {
            menu.insertItem(withTitle: "(none yet)", action: nil, keyEquivalent: "", at: fixedPrefix)
        } else {
            for (index, path) in recentlyDetected.enumerated() {
                menu.insertItem(
                    withTitle: (path as NSString).lastPathComponent,
                    action: nil,
                    keyEquivalent: "",
                    at: fixedPrefix + index
                )
            }
        }
    }

    @objc private func chooseFileAndSend() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose a file to send via AirDrop"

        // A .accessory-policy status-bar app still has no window of its own; activate first
        // so the open panel (and, after it, the AirDrop picker) can become key/frontmost.
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        sendViaAirDrop(fileURL: url)
    }

    /// Manual trigger for the Mac -> phone direction, as an alternative to dragging a file into
    /// Downloads: pushes the chosen file straight to the paired Android device over the same
    /// bridge connection AgentServer already keeps open.
    @objc private func chooseFileAndSendToPhone() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose a file to send to your phone"

        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        server?.pushFile(at: url) { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.showNotification(title: "AirBridge", body: "Sent \(url.lastPathComponent) to your phone")
                } else {
                    self?.showNotification(title: "AirBridge", body: "Couldn't send \(url.lastPathComponent) - is your phone paired and connected?")
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
