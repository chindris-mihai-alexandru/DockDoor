import ApplicationServices
import Carbon
import Cocoa
import Defaults

// AXObserver callback for Cmd+Tab switcher changes
func handleCmdTabSwitcherNotification(observer _: AXObserver, element _: AXUIElement, notificationName: CFString, context: UnsafeMutableRawPointer?) {
    DockObserver.activeInstance?.processCmdTabSwitcherEvent(notificationName)
}

extension DockObserver {
    // MARK: - Cmd+Tab Switcher Monitoring

    func teardownCmdTabObserver() {
        if let observer = cmdTabObserver {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        cmdTabObserver = nil
        stopCmdTabPolling()
        DockObserver.isCmdTabSwitcherActive = false

        cmdTabSelection.reset()
        endCmdTabSearchSession()
    }

    /// Ends a Cmd+Tab search session and dismisses its panel: the native switcher went
    /// away (Command released, Escape, destroyed), the event tap was disabled, or secure
    /// input started (typed letters would then reach the native switcher, where Command+Q
    /// quits and Command+H hides the highlighted app). Safe to call from any thread.
    func endCmdTabSearchSession() {
        // The flag is only ever read and written on the main thread, so other threads
        // (deinit) hop first; the block captures the panel, never self.
        let preview = previewCoordinator
        let end = { MainActor.assumeIsolated { DockObserver.dismissCmdTabSearchSession(preview) } }
        if Thread.isMainThread {
            end()
        } else {
            DispatchQueue.main.async(execute: end)
        }
    }

    @MainActor
    private static func dismissCmdTabSearchSession(_ preview: SharedPreviewWindowCoordinator) {
        guard isCmdTabSearchSession else { return }
        isCmdTabSearchSession = false

        let coordinator = preview.windowSwitcherCoordinator
        coordinator.onSelectedIndexChanged = nil
        coordinator.searchQuery = ""
        preview.hideWindow()
        // hideWindow returns early when the panel is already hidden, which would
        // leave the switcher flag set and make later switcher sessions misbehave.
        if coordinator.windowSwitcherActive {
            coordinator.setShowing(.both, toState: false)
        }
        SwitcherHeightBudget.current = nil
    }

    // MARK: - On-Demand Polling (Event-Driven)

    func startCmdTabPolling() {
        guard Defaults[.enableCmdTabEnhancements] else { return }
        guard cmdTabObserver == nil else { return }

        attemptCmdTabSubscription()

        if cmdTabObserver == nil {
            cmdTabPollingTimer?.invalidate()
            cmdTabPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                guard let self else {
                    timer.invalidate()
                    return
                }
                attemptCmdTabSubscription()

                if cmdTabObserver != nil {
                    timer.invalidate()
                    cmdTabPollingTimer = nil
                }
            }
        }
    }

    func stopCmdTabPolling() {
        cmdTabPollingTimer?.invalidate()
        cmdTabPollingTimer = nil
    }

    private func attemptCmdTabSubscription() {
        guard let dockApp = DockUtils.runningDock else {
            return
        }

        let dockAppPID = dockApp.processIdentifier
        let dockAppElement = AXUIElementCreateApplication(dockAppPID)

        guard let processSwitcherList = findCmdTabSwitcherElement(in: dockAppElement) else {
            return
        }

        stopCmdTabPolling()
        subscribeToProcessSwitcher(processSwitcherList: processSwitcherList, dockAppPID: dockAppPID)
        processCmdTabSwitcherChanged()
    }

    private func subscribeToProcessSwitcher(processSwitcherList: AXUIElement, dockAppPID: pid_t) {
        if cmdTabObserver != nil {
            teardownCmdTabObserver()
        }

        guard AXObserverCreate(dockAppPID, handleCmdTabSwitcherNotification, &cmdTabObserver) == .success,
              let cmdTabObserver
        else {
            return
        }

        do {
            try processSwitcherList.subscribeToNotification(cmdTabObserver, kAXSelectedChildrenChangedNotification as String) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(cmdTabObserver), .commonModes)
            }
            try processSwitcherList.subscribeToNotification(cmdTabObserver, kAXUIElementDestroyedNotification as String)
            DockObserver.isCmdTabSwitcherActive = true
        } catch {
            // Ignore subscription errors
        }
    }

    func processCmdTabSwitcherEvent(_ notification: CFString) {
        guard Defaults[.enableCmdTabEnhancements] else { return }

        let notif = notification as String

        if notif == (kAXSelectedChildrenChangedNotification as String) {
            processCmdTabSwitcherChanged()
            return
        }

        if notif == (kAXUIElementDestroyedNotification as String) {
            teardownCmdTabObserver()
            return
        }
    }

    func processCmdTabSwitcherChanged() {
        guard Defaults[.enableCmdTabEnhancements] else { return }

        // While a search session is running, native selection changes (including the
        // ones we cause ourselves via AX) must not re-render the overlay with a single
        // app's windows; the panel follows the strip instead.
        if DockObserver.isCmdTabSearchSession {
            if IsSecureEventInputEnabled() {
                endCmdTabSearchSession()
            } else {
                reflectNativeSelectionIntoSearchSession()
            }
            return
        }

        // Instant mode: Cmd+Tab opens directly into the full search session. When it
        // cannot (no windows, secure input), fall through to the normal overlay.
        if Defaults[.enableInstantCmdTabSearch], Defaults[.enableWindowSwitcherSearch],
           let present = instantSearchPresenter,
           MainActor.assumeIsolated({ present() })
        {
            return
        }

        guard let dockApp = DockUtils.runningDock else {
            return
        }

        let dockAppElement = AXUIElementCreateApplication(dockApp.processIdentifier)

        guard let selectedItem = getSelectedCmdTabItem(dockElement: dockAppElement) else {
            _ = findCmdTabSwitcherElement(in: dockAppElement)
            return
        }

        let resolvedApp = selectedItem.app
        let appName = resolvedApp?.localizedName ?? selectedItem.title ?? "Unknown"
        let bundleId = resolvedApp?.bundleIdentifier ?? selectedItem.bundleId

        var cachedWindows: [WindowInfo] = []
        if let app = resolvedApp {
            cachedWindows = WindowUtil.readCachedWindows(for: app.processIdentifier, sortedBy: .cmdTab)
        }

        let shouldIgnoreSingleWindowApp = Defaults[.ignoreAppsWithSingleWindowInCmdTab] && cachedWindows.count == 1

        if Defaults[.showWindowsFromCurrentSpaceOnlyInCmdTab] {
            cachedWindows = WindowUtil.filterWindowsByCurrentSpace(cachedWindows)
        }

        if Defaults[.showWindowsFromCurrentMonitorOnlyInCmdTab] {
            cachedWindows = WindowUtil.filterWindowsByCurrentMonitor(cachedWindows)
        }

        if !Defaults[.includeHiddenWindowsInCmdTab] {
            cachedWindows = cachedWindows.filter { !$0.isHidden && !$0.isMinimized }
        }

        let elementPos = try? selectedItem.element.position()
        let bestScreen = if let elementPos { NSScreen.screenFromQuartzPoint(elementPos) } else { NSScreen.main! }

        Task { @MainActor [weak self] in
            guard let self else { return }

            if shouldIgnoreSingleWindowApp {
                previewCoordinator.hideWindow()
                return
            }

            if cachedWindows.isEmpty {
                if let app = resolvedApp, Defaults[.showWindowlessAppsInCmdTab] {
                    cachedWindows = [WindowInfo.windowlessEntry(for: app)]
                } else {
                    previewCoordinator.hideWindow()
                    return
                }
            }

            let initialIndex = Defaults[.cmdTabAutoSelectFirstWindow] ? 0 : nil
            previewCoordinator.showWindow(
                appName: appName,
                windows: cachedWindows,
                mouseLocation: DockObserver.getMousePosition(),
                mouseScreen: bestScreen,
                dockItemElement: selectedItem.element,
                overrideDelay: true,
                centeredHoverWindowState: .none,
                onWindowTap: { [weak self] in
                    self?.hideWindowAndResetLastApp()
                },
                bundleIdentifier: bundleId,
                bypassDockMouseValidation: true,
                dockPositionOverride: .cmdTab,
                initialIndex: initialIndex
            )
        }

        if let app = resolvedApp {
            let appPID = app.processIdentifier
            let screenOrigin = bestScreen.frame.origin

            Task.detached { [weak self] in
                guard let self else { return }

                do {
                    var windows = try await WindowUtil.getActiveWindows(of: app, context: .cmdTab)

                    if Defaults[.showWindowsFromCurrentSpaceOnlyInCmdTab] {
                        windows = WindowUtil.filterWindowsByCurrentSpace(windows)
                    }

                    if Defaults[.showWindowsFromCurrentMonitorOnlyInCmdTab] {
                        windows = WindowUtil.filterWindowsByCurrentMonitor(windows)
                    }

                    if !Defaults[.includeHiddenWindowsInCmdTab] {
                        windows = windows.filter { !$0.isHidden && !$0.isMinimized }
                    }

                    guard !windows.isEmpty else { return }
                    let freshWindows = windows

                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        guard let screen = screenOrigin.screen() else { return }

                        let didMerge = previewCoordinator.mergeWindowsIfNeeded(
                            appPID,
                            windows: freshWindows,
                            dockPosition: .cmdTab,
                            bestGuessMonitor: screen
                        )
                        DebugLogger.log("WindowRefresh", details: "Cmd+Tab final merge, PID: \(appPID), windows: \(freshWindows.count), merged: \(didMerge)")
                    }
                } catch {
                    DebugLogger.log("DockObserver+CmdTab", details: "Failed to fetch windows for Cmd+Tab: \(error)")
                }
            }
        }
    }

    // MARK: - Cmd+Tab Session State

    /// Cached state tracking whether the Cmd+Tab switcher is currently active.
    /// Updated by the AXObserver when the switcher appears/disappears.
    static var isCmdTabSwitcherActive = false
    /// True while the Cmd+Tab overlay is a full-switcher search session (see KeybindHelper).
    /// Kept separate from the shared window-switcher flag so Alt+Tab behavior never keys off it.
    static var isCmdTabSearchSession = false

    private func getSelectedCmdTabItem(dockElement: AXUIElement) -> (element: AXUIElement, app: NSRunningApplication?, bundleId: String?, title: String?)? {
        guard let appSwitcherElement = findCmdTabSwitcherElement(in: dockElement) else {
            return nil
        }

        var selectedChildren: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appSwitcherElement, kAXSelectedChildrenAttribute as CFString, &selectedChildren)

        if result == .success,
           let selectedArray = selectedChildren as? [AXUIElement],
           let selectedElement = selectedArray.first
        {
            let resolved = resolveCmdTabRow(selectedElement)
            return (element: selectedElement, app: resolved.app, bundleId: resolved.bundleId, title: resolved.title)
        }

        return nil
    }

    /// Resolves a native switcher row element to its running app, bundle id and title.
    private func resolveCmdTabRow(_ element: AXUIElement) -> (app: NSRunningApplication?, bundleId: String?, title: String?) {
        var resolvedApp: NSRunningApplication?
        var resolvedBundleId: String?
        var resolvedTitle: String?

        if let appURL = try? element.attribute(kAXURLAttribute as String, NSURL.self)?.absoluteURL,
           let bundle = Bundle(url: appURL),
           let bundleIdentifier = bundle.bundleIdentifier
        {
            resolvedBundleId = bundleIdentifier
            resolvedApp = LauncherShortcutResolver.runningApplications(forBundleAt: appURL, bundleIdentifier: bundleIdentifier).first
        }

        if resolvedApp == nil {
            do {
                if let title = try element.title(), !title.isEmpty {
                    resolvedTitle = title
                    let allApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                    if let app = allApps.first(where: { $0.localizedName == title }) {
                        resolvedApp = app
                    } else {
                        let lowerTitle = title.lowercased()
                        if let app = allApps.first(where: { ($0.localizedName ?? "").lowercased().contains(lowerTitle) || lowerTitle.contains(($0.localizedName ?? "").lowercased()) }) {
                            resolvedApp = app
                        }
                    }
                    if resolvedBundleId == nil { resolvedBundleId = resolvedApp?.bundleIdentifier }
                }
            } catch {
                // ignore
            }
        }

        return (app: resolvedApp, bundleId: resolvedBundleId, title: resolvedTitle)
    }

    /// AX round-trips to the Dock can block for seconds when it is busy; cap them.
    private static let axMessagingTimeout: Float = 0.25

    /// Frame of the native Cmd+Tab switcher in AppKit screen coordinates. AX reports a
    /// top-left-origin global rect; AppKit is bottom-left-origin, flipped against the
    /// PRIMARY display's height and including the rect's own height (using another
    /// display's height breaks arrangements with displays above or left of the primary).
    func cmdTabSwitcherFrame() -> CGRect? {
        guard let dockApp = DockUtils.runningDock,
              let primaryHeight = NSScreen.screens.first?.frame.height
        else { return nil }
        let dockAppElement = AXUIElementCreateApplication(dockApp.processIdentifier)
        guard let appSwitcherElement = findCmdTabSwitcherElement(in: dockAppElement),
              let position = try? appSwitcherElement.position(),
              let size = try? appSwitcherElement.size(),
              size.width > 0, size.height > 0
        else { return nil }
        return CmdTabStripGeometry.appKitRect(axPosition: position, size: size, primaryScreenHeight: primaryHeight)
    }

    /// PID of the app the native Cmd+Tab strip currently highlights, if readable.
    func selectedCmdTabPID() -> pid_t? {
        guard let dockApp = DockUtils.runningDock else { return nil }
        let item = getSelectedCmdTabItem(dockElement: AXUIElementCreateApplication(dockApp.processIdentifier))
        return item?.app?.processIdentifier
    }

    /// Mirrors the native Cmd+Tab highlight into the converted search session: the
    /// inverse of syncNativeCmdTabSelection. Tab and Shift+Tab cycle the system strip
    /// as usual and the panel follows to that app's first (matching) window. With no
    /// match the panel deselects, so releasing Command activates the app the strip is
    /// on, exactly like stock. (A fresh session starts on the system's own initial
    /// highlight through the same lookup; see KeybindHelper.presentInstantSearchSession.)
    func reflectNativeSelectionIntoSearchSession() {
        guard let pid = selectedCmdTabPID() else { return }

        // Applied synchronously: this runs on the main run loop straight from the
        // Dock's notification, so a deferred hop could land after newer typing and
        // overwrite the selection that typing chose.
        MainActor.assumeIsolated {
            guard DockObserver.isCmdTabSearchSession else { return }
            // Our own forward writes echo back as notifications for the pid we just
            // wrote; every genuine move (including back to an earlier app) differs.
            // A genuine move also invalidates any pending panel-driven write.
            guard cmdTabSelection.nativeSelectionChanged(to: pid) else { return }
            let coordinator = previewCoordinator.windowSwitcherCoordinator
            coordinator.setIndex(to: coordinator.firstSearchIndex(forPID: pid) ?? -1)
        }
    }

    /// Moves the native Cmd+Tab selection to the row matching the given app, so the
    /// switcher highlight follows DockDoor's overlay selection instead of staying on
    /// one icon. Tries writing the list's selected children first, then the row's
    /// selected attribute. Safe to call when the switcher is gone; returns false then.
    func selectCmdTabRow(matchingBundleId bundleId: String?, appName: String?, appPID: pid_t?) -> Bool {
        guard DockObserver.isCmdTabSwitcherActive,
              let dockApp = DockUtils.runningDock
        else { return false }

        // Consecutive matches of the same app need no write, and a failed write
        // (private AX tree changed, selection not settable) is not retried every keystroke.
        guard cmdTabSelection.needsWrite(for: appPID) else { return cmdTabSelection.isInSync(with: appPID) }

        let dockAppElement = AXUIElementCreateApplication(dockApp.processIdentifier)
        AXUIElementSetMessagingTimeout(dockAppElement, Self.axMessagingTimeout)
        guard let appSwitcherElement = findCmdTabSwitcherElement(in: dockAppElement),
              let rows = try? appSwitcherElement.children(), !rows.isEmpty
        else {
            DebugLogger.log("CmdTabSelection", details: "early return: switcher/rows unavailable")
            return false
        }

        // Resolve every row once: each resolveCmdTabRow costs several AX round-trips.
        let resolvedRows = rows.map { (element: $0, resolved: resolveCmdTabRow($0)) }

        var target: AXUIElement?
        // PID first: unambiguous even when several installed apps share a name.
        if let appPID {
            target = resolvedRows.first { $0.resolved.app?.processIdentifier == appPID }?.element
        }
        if target == nil, let bundleId {
            target = resolvedRows.first { row in
                guard let rowBundle = row.resolved.bundleId else { return false }
                return rowBundle.caseInsensitiveCompare(bundleId) == .orderedSame
            }?.element
        }
        if target == nil, let appName, !appName.isEmpty {
            let lowerName = appName.lowercased()
            target = resolvedRows.first { row in
                guard let title = row.resolved.title, !title.isEmpty else { return false }
                let lowerTitle = title.lowercased()
                return lowerTitle == lowerName || lowerTitle.contains(lowerName)
            }?.element
        }
        guard let target else {
            DebugLogger.log("CmdTabSelection", details: "no matching row found")
            return false
        }

        var setResult = AXUIElementSetAttributeValue(appSwitcherElement, kAXSelectedChildrenAttribute as CFString, [target] as NSArray)
        if setResult != .success {
            setResult = AXUIElementSetAttributeValue(target, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            DebugLogger.log("CmdTabSelection", details: "row kAXSelected fallback: \(setResult.rawValue)")
        }
        if setResult != .success {
            DebugLogger.log("CmdTabSelection", details: "Failed to move native Cmd+Tab selection (AXError \(setResult.rawValue))")
            cmdTabSelection.writeFailed()
            return false
        }
        cmdTabSelection.didWrite(appPID)
        return true
    }

    private func findCmdTabSwitcherElement(in dockElement: AXUIElement) -> AXUIElement? {
        do {
            let children = try dockElement.children() ?? []

            for child in children {
                let subrole = try? child.subrole()
                if let subrole, subrole == "AXProcessSwitcherList" {
                    return child
                }

                if let found = findCmdTabSwitcherElement(in: child) {
                    return found
                }
            }
        } catch {
            // Element might not be accessible
        }

        return nil
    }
}

/// Bookkeeping for the two-way sync between the native Cmd+Tab highlight and the
/// search panel. Pure value type so the echo guard and staleness rules are unit tested.
struct CmdTabSelectionTracker: Equatable {
    private(set) var lastSyncedPID: pid_t?
    /// Bumped on every genuine user move of the native highlight; a pending panel-driven
    /// write captured an older value and must not land.
    private(set) var userMoveGeneration = 0
    /// Set after a failed AX write so the session degrades to one-way display.
    private(set) var writesDisabled = false

    /// The native highlight moved to `pid`. Returns false for the echo of our own write.
    mutating func nativeSelectionChanged(to pid: pid_t) -> Bool {
        guard pid != lastSyncedPID else { return false }
        userMoveGeneration += 1
        lastSyncedPID = pid
        return true
    }

    /// Whether the panel's selection of `pid` needs to be written to the native strip.
    func needsWrite(for pid: pid_t?) -> Bool {
        guard !writesDisabled else { return false }
        guard let pid else { return true }
        return pid != lastSyncedPID
    }

    func isInSync(with pid: pid_t?) -> Bool {
        pid != nil && pid == lastSyncedPID
    }

    mutating func didWrite(_ pid: pid_t?) { lastSyncedPID = pid }
    mutating func writeFailed() { writesDisabled = true }
    /// Records a highlight we did not write but know is current (a fresh session's start).
    mutating func seed(_ pid: pid_t?) { lastSyncedPID = pid }
    /// Starts over for a new session. The generation keeps counting, so work scheduled by
    /// an earlier session can never match a later one.
    mutating func reset() {
        let next = userMoveGeneration + 1
        self = CmdTabSelectionTracker()
        userMoveGeneration = next
    }

    func isCurrent(generation: Int) -> Bool { generation == userMoveGeneration }
}

/// Geometry for the Cmd+Tab search panel relative to the system-owned switcher strip.
enum CmdTabStripGeometry {
    /// Converts an AX rect (global, top-left origin) to AppKit (bottom-left origin).
    /// The flip uses the PRIMARY display's height and the rect's own height.
    static func appKitRect(axPosition: CGPoint, size: CGSize, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: axPosition.x, y: primaryScreenHeight - axPosition.y - size.height, width: size.width, height: size.height)
    }

    /// Vertical space between the search bar and the strip's top edge, never below `floor`.
    static func heightBudget(panelTop: CGFloat, stripTop: CGFloat, gap: CGFloat, floor: CGFloat) -> CGFloat {
        max(panelTop - (stripTop + gap), floor)
    }
}

/// How a key press is treated while a Cmd+Tab search session is active.
enum CmdTabSessionKey {
    enum Disposition: Equatable {
        /// Handled by the existing Escape branch (dismisses the switcher and the panel).
        case escape
        /// Left to the system so the native strip keeps cycling (Tab, Shift+Tab, and the
        /// backward key).
        case passToSystem
        /// Routed to the search handling and always swallowed, so no key can leak to the
        /// native switcher (Command+Q quits and Command+H hides the highlighted app there).
        case consume
    }

    static func disposition(forKeyCode keyCode: Int64) -> Disposition {
        switch keyCode {
        case Int64(kVK_Escape): .escape
        case Int64(kVK_Tab), Int64(kVK_ANSI_Grave): .passToSystem
        default: .consume
        }
    }
}
