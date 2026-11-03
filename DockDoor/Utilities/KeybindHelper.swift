import AppKit
import Carbon
import Carbon.HIToolbox.Events
import Defaults

private class KeybindHelperUserInfo {
    let instance: KeybindHelper
    init(instance: KeybindHelper) {
        self.instance = instance
    }
}

struct UserKeyBind: Codable, Defaults.Serializable {
    var keyCode: UInt16
    var modifierFlags: Int
}

struct AlternateKeybind: Codable, Defaults.Serializable, Identifiable, Equatable {
    var id = UUID()
    var keyCode: UInt16 = 0
    var modifierFlags: Int = 0
    var mode: SwitcherInvocationMode = .activeAppOnly

    func resolved(primaryModifierFlags: Int) -> UserKeyBind? {
        guard keyCode != 0 else { return nil }
        return UserKeyBind(keyCode: keyCode, modifierFlags: modifierFlags == 0 ? primaryModifierFlags : modifierFlags)
    }

    static var first: AlternateKeybind {
        get {
            AlternateKeybind(
                keyCode: Defaults[.alternateKeybindKey],
                modifierFlags: Defaults[.alternateKeybindModifierFlags],
                mode: Defaults[.alternateKeybindMode]
            )
        }
        set {
            Defaults[.alternateKeybindKey] = newValue.keyCode
            Defaults[.alternateKeybindModifierFlags] = newValue.modifierFlags
            Defaults[.alternateKeybindMode] = newValue.mode
        }
    }

    static var all: [AlternateKeybind] {
        [first] + Defaults[.additionalAlternateKeybinds]
    }
}

enum ShortcutModifier: CaseIterable, Identifiable {
    case control
    case option
    case command

    var id: Self { self }

    var mask: Int {
        switch self {
        case .control: Defaults[.Int64maskControl]
        case .option: Defaults[.Int64maskAlternate]
        case .command: Defaults[.Int64maskCommand]
        }
    }

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .command: "⌘"
        }
    }

    var localizedName: String {
        switch self {
        case .control: String(localized: "Control")
        case .option: String(localized: "Option")
        case .command: String(localized: "Command")
        }
    }

    private var eventFlag: CGEventFlags {
        switch self {
        case .control: .maskControl
        case .option: .maskAlternate
        case .command: .maskCommand
        }
    }

    func isContained(in modifierFlags: Int) -> Bool {
        modifierFlags & Int(eventFlag.rawValue) != 0
    }

    static func contained(in modifierFlags: Int) -> [ShortcutModifier] {
        allCases.filter { $0.isContained(in: modifierFlags) }
    }

    static func modifierFlags(for modifiers: [ShortcutModifier]) -> Int {
        modifiers.reduce(0) { $0 | $1.mask }
    }
}

private class WindowSwitchingCoordinator {
    private var isProcessingSwitcher = false
    private var uiRenderingTask: Task<Void, Never>?
    private var windowRefreshTask: Task<Void, Never>?
    private var currentSessionId = UUID()
    /// When true, initialization should complete but immediately select the window instead of showing UI
    private var shouldSelectImmediately = false
    var trackpadOpenedCurrentSession = false

    private static var lastUpdateAllWindowsTime: Date?
    private static let updateAllWindowsThrottleInterval: TimeInterval = 5.0

    @MainActor
    func handleWindowSwitching(
        previewCoordinator: SharedPreviewWindowCoordinator,
        isModifierPressed: Bool,
        isShiftPressed: Bool,
        mode: SwitcherInvocationMode = .allWindows
    ) async {
        guard !isProcessingSwitcher else { return }
        isProcessingSwitcher = true
        defer { isProcessingSwitcher = false }

        let coordinator = previewCoordinator.windowSwitcherCoordinator

        if coordinator.isKeybindSessionActive {
            coordinator.hasMovedSinceOpen = false
            coordinator.initialHoverLocation = nil

            if isShiftPressed {
                coordinator.cycleBackward()
            } else {
                coordinator.cycleForward()
            }
        } else if isModifierPressed {
            await initializeWindowSwitching(
                previewCoordinator: previewCoordinator,
                mode: mode
            )
        }
    }

    @MainActor
    private func initializeWindowSwitching(
        previewCoordinator: SharedPreviewWindowCoordinator,
        mode: SwitcherInvocationMode = .allWindows
    ) async {
        // Reset the immediate-select flag at start of initialization
        shouldSelectImmediately = false
        windowRefreshTask?.cancel()

        currentSessionId = UUID()
        let sessionId = currentSessionId
        let targetScreen = getTargetScreenForSwitcher()
        let currentMouseLocation = DockObserver.getMousePosition()
        let dockPosition = DockUtils.getDockPosition()

        var windows = buildSwitcherWindows(mode: mode)
        if windows.isEmpty {
            // Empty cache: discover in the background and open as soon as the first windows land.
            startBackgroundRefresh(
                previewCoordinator: previewCoordinator,
                mode: mode,
                dockPosition: dockPosition,
                targetScreen: targetScreen,
                sessionId: sessionId,
                priority: .userInitiated
            )
            let deadline = Date().addingTimeInterval(1.5)
            while windows.isEmpty, Date() < deadline {
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard sessionId == currentSessionId else { return }
                windows = buildSwitcherWindows(mode: mode)
            }
        }
        guard !windows.isEmpty else { return }

        let coordinator = previewCoordinator.windowSwitcherCoordinator
        coordinator.initializeForWindowSwitcher(with: windows, dockPosition: dockPosition, bestGuessMonitor: targetScreen)
        coordinator.activateKeybindSession()

        // If modifier was released during initialization, immediately select and exit
        if shouldSelectImmediately {
            if let selectedWindow = coordinator.getCurrentWindow() {
                selectedWindow.bringToFront()
                selectedWindow.warpMouseToCenterIfNeeded()
                if selectedWindow.isWindowlessApp, Defaults[.openNewWindowForWindowlessApps] {
                    WindowUtil.activateAndOpenNewWindow(app: selectedWindow.app)
                }
            }
            coordinator.deactivateKeybindSession()
            previewCoordinator.hideWindow()
            shouldSelectImmediately = false
            return
        }

        uiRenderingTask?.cancel()
        uiRenderingTask = Task { @MainActor in
            if !Defaults[.instantWindowSwitcher] {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await renderWindowSwitcherUI(
                previewCoordinator: previewCoordinator,
                mode: mode,
                dockPosition: dockPosition,
                currentMouseLocation: currentMouseLocation,
                targetScreen: targetScreen,
                sessionId: sessionId
            )
        }
    }

    // fileprivate: also used by KeybindHelper's Cmd+Tab search session.
    @MainActor
    fileprivate func buildSwitcherWindows(mode: SwitcherInvocationMode) -> [WindowInfo] {
        var windows = WindowUtil.getAllWindowsOfAllApps()
        let windowsForWindowlessDetection = windows

        let filterBySpace = (mode == .currentSpaceOnly || mode == .activeAppCurrentSpace)
            || (mode == .allWindows && Defaults[.showWindowsFromCurrentSpaceOnlyInSwitcher])
        if filterBySpace {
            windows = WindowUtil.filterWindowsByCurrentSpace(windows)
        }

        if mode == .allWindows, Defaults[.showWindowsFromCurrentMonitorOnlyInSwitcher] {
            windows = WindowUtil.filterWindowsByCurrentMonitor(windows)
        }

        let filterByApp = isActiveAppMode(mode)
        if filterByApp {
            windows = WindowUtil.getWindowsForFrontmostApp(from: windows)
        }

        if !Defaults[.includeHiddenWindowsInSwitcher] {
            windows = windows.filter { !$0.isHidden && !$0.isMinimized }
        }

        windows = WindowUtil.sortWindowsForSwitcher(windows)

        if !filterByApp {
            windows = WindowUtil.groupWindowsByApp(windows)
        }

        if !filterByApp, Defaults[.showWindowlessAppsInSwitcher] {
            windows.append(contentsOf: WindowUtil.getWindowlessRunningApps(existingWindows: windowsForWindowlessDetection))
        }

        return windows
    }

    private func isActiveAppMode(_ mode: SwitcherInvocationMode) -> Bool {
        (mode == .activeAppOnly || mode == .activeAppCurrentSpace)
            || (mode == .allWindows && Defaults[.limitSwitcherToFrontmostApp])
    }

    @MainActor
    private func scheduleWindowRefresh(
        previewCoordinator: SharedPreviewWindowCoordinator,
        mode: SwitcherInvocationMode,
        dockPosition: DockPosition,
        targetScreen: NSScreen,
        sessionId: UUID
    ) {
        let now = Date()
        if let lastUpdate = WindowSwitchingCoordinator.lastUpdateAllWindowsTime,
           now.timeIntervalSince(lastUpdate) < WindowSwitchingCoordinator.updateAllWindowsThrottleInterval
        {
            return
        }
        startBackgroundRefresh(
            previewCoordinator: previewCoordinator,
            mode: mode,
            dockPosition: dockPosition,
            targetScreen: targetScreen,
            sessionId: sessionId,
            priority: .low
        )
    }

    @MainActor
    private func startBackgroundRefresh(
        previewCoordinator: SharedPreviewWindowCoordinator,
        mode: SwitcherInvocationMode,
        dockPosition: DockPosition,
        targetScreen: NSScreen,
        sessionId: UUID,
        priority: TaskPriority
    ) {
        WindowSwitchingCoordinator.lastUpdateAllWindowsTime = Date()

        windowRefreshTask?.cancel()
        windowRefreshTask = Task.detached(priority: priority) { [weak self, weak previewCoordinator, mode, dockPosition, targetScreen, sessionId] in
            await WindowUtil.updateAllWindowsInCurrentSpace()
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self, weak previewCoordinator] in
                guard let self, let previewCoordinator else { return }
                guard sessionId == currentSessionId else { return }

                let coordinator = previewCoordinator.windowSwitcherCoordinator
                guard coordinator.isKeybindSessionActive else { return }

                let freshWindows = buildSwitcherWindows(mode: mode)
                guard !freshWindows.isEmpty else { return }

                applyRefreshedSwitcherWindows(
                    freshWindows,
                    coordinator: coordinator,
                    dockPosition: dockPosition,
                    bestGuessMonitor: targetScreen
                )
            }
        }
    }

    @MainActor
    private func applyRefreshedSwitcherWindows(
        _ freshWindows: [WindowInfo],
        coordinator: PreviewStateCoordinator,
        dockPosition: DockPosition,
        bestGuessMonitor: NSScreen
    ) {
        let selectedWindow = coordinator.getCurrentWindow()
        let previousWindowCount = coordinator.windows.count

        // Replace the global switcher list rather than using the single-app merge path.
        // Windowless entries can share window ID 0, so preserving the full rebuilt list is safer.
        coordinator.setWindows(freshWindows, dockPosition: dockPosition, bestGuessMonitor: bestGuessMonitor)

        if let selectedWindow,
           let newIndex = coordinator.windows.firstIndex(where: { isSameSwitcherWindow($0, selectedWindow) })
        {
            coordinator.setIndex(to: newIndex)
        }

        if coordinator.windows.count != previousWindowCount {
            coordinator.onFrameRefreshNeeded?()
        }
    }

    private func isSameSwitcherWindow(_ first: WindowInfo, _ second: WindowInfo) -> Bool {
        // Window ID alone is not enough here because placeholder/windowless entries use 0.
        first.id == second.id &&
            first.app.processIdentifier == second.app.processIdentifier
    }

    @MainActor
    private func renderWindowSwitcherUI(
        previewCoordinator: SharedPreviewWindowCoordinator,
        mode: SwitcherInvocationMode,
        dockPosition: DockPosition,
        currentMouseLocation: CGPoint,
        targetScreen: NSScreen,
        sessionId: UUID
    ) async {
        guard sessionId == currentSessionId else { return }
        let coordinator = previewCoordinator.windowSwitcherCoordinator
        guard coordinator.isKeybindSessionActive else { return }

        if previewCoordinator.isVisible, coordinator.windowSwitcherActive {
            return
        }
        let showWindowLambda = { (mouseLocation: NSPoint?, mouseScreen: NSScreen?) in
            let windows = coordinator.windows
            guard !windows.isEmpty else { return }
            previewCoordinator.showWindow(
                appName: "Window Switcher",
                windows: windows,
                mouseLocation: mouseLocation,
                mouseScreen: mouseScreen,
                dockItemElement: nil,
                overrideDelay: true,
                centeredHoverWindowState: .windowSwitcher,
                onWindowTap: {
                    self.cancelSwitching(previewCoordinator: previewCoordinator)
                    Task { @MainActor in
                        previewCoordinator.hideWindow()
                    }
                },
                initialIndex: coordinator.currIndex
            )
        }

        switch Defaults[.windowSwitcherPlacementStrategy] {
        case .pinnedToScreen:
            let screenCenter = NSPoint(x: targetScreen.frame.midX, y: targetScreen.frame.midY)
            showWindowLambda(screenCenter, targetScreen)
        case .screenWithLastActiveWindow:
            showWindowLambda(nil, nil)
        case .screenWithMouse:
            let mouseScreen = NSScreen.screenFromQuartzPoint(currentMouseLocation)
            let convertedMouseLocation = DockObserver.nsPointFromCGPoint(currentMouseLocation, forScreen: mouseScreen)
            showWindowLambda(convertedMouseLocation, mouseScreen)
        }

        if Defaults[.focusSearchOnWindowSwitcherOpen], Defaults[.enableWindowSwitcherSearch] {
            previewCoordinator.focusSearchWindow()
        }

        // Refresh only once the switcher is actually on screen, so quick press-release
        // invocations that never render skip the discovery pass entirely.
        scheduleWindowRefresh(
            previewCoordinator: previewCoordinator,
            mode: mode,
            dockPosition: dockPosition,
            targetScreen: targetScreen,
            sessionId: sessionId
        )
    }

    fileprivate func getTargetScreenForSwitcher() -> NSScreen {
        if Defaults[.windowSwitcherPlacementStrategy] == .pinnedToScreen,
           let pinnedScreen = NSScreen.findScreen(byIdentifier: Defaults[.pinnedScreenIdentifier])
        {
            return pinnedScreen
        }
        let mouseLocation = DockObserver.getMousePosition()
        return NSScreen.screenFromQuartzPoint(mouseLocation)
    }

    @MainActor
    func selectCurrentWindow(previewCoordinator: SharedPreviewWindowCoordinator) -> WindowInfo? {
        let coordinator = previewCoordinator.windowSwitcherCoordinator
        guard coordinator.isKeybindSessionActive else { return nil }

        let selectedWindow = coordinator.getCurrentWindow()
        currentSessionId = UUID()
        coordinator.deactivateKeybindSession()
        uiRenderingTask?.cancel()
        windowRefreshTask?.cancel()
        return selectedWindow
    }

    func isActive(previewCoordinator: SharedPreviewWindowCoordinator) -> Bool {
        previewCoordinator.windowSwitcherCoordinator.isKeybindSessionActive
    }

    @MainActor
    func cancelSwitching(previewCoordinator: SharedPreviewWindowCoordinator) {
        currentSessionId = UUID()
        shouldSelectImmediately = false
        previewCoordinator.windowSwitcherCoordinator.deactivateKeybindSession()
        uiRenderingTask?.cancel()
        windowRefreshTask?.cancel()
    }

    /// Signals that the modifier was released during initialization.
    /// If initialization is still in progress, it will complete but immediately select the window.
    /// If initialization already completed, this just cancels the UI rendering task.
    @MainActor
    func cancelPendingRender() {
        currentSessionId = UUID()
        shouldSelectImmediately = true
        uiRenderingTask?.cancel()
        windowRefreshTask?.cancel()
    }
}

class KeybindHelper {
    private let previewCoordinator: SharedPreviewWindowCoordinator
    private let windowSwitchingCoordinator = WindowSwitchingCoordinator()

    private var isSwitcherModifierKeyPressed: Bool = false
    private var isShiftKeyPressedGeneral: Bool = false
    private var hasProcessedModifierRelease: Bool = false
    private var preventSwitcherHideOnRelease: Bool = false
    private var heldKeyRepeatTask: Task<Void, Never>?
    private var windowStashedByShortcut: WindowInfo?
    private var nativeSelectionSyncDebounce: DispatchWorkItem?

    /// Track the invocation mode for alternate keybinds
    private var currentInvocationMode: SwitcherInvocationMode = .allWindows

    // Track Command key state to detect key-up fallback for lingering previews
    private var isCommandKeyCurrentlyDown: Bool = false
    private var lastCmdTabObservedActive: Bool = false
    private var cmdTabActionPerformed: Bool = false
    /// Set on event tap thread when switcher keybind fires, so other keyDown handlers
    /// can detect the switcher is active without reading MainActor-only state.
    private var switcherSessionActive: Bool = false
    private var activeSessionKeybind: UserKeyBind = Defaults[.UserKeybind]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var monitorTimer: Timer?
    private var unmanagedEventTapUserInfo: Unmanaged<KeybindHelperUserInfo>?
    private var trackpadSwipeTrigger: TrackpadSwipeTrigger?

    init(previewCoordinator: SharedPreviewWindowCoordinator) {
        self.previewCoordinator = previewCoordinator
        setupEventTap()
        startMonitoring()
        DockObserver.activeInstance?.instantSearchPresenter = { [weak self] in
            MainActor.assumeIsolated { self?.presentInstantSearchSession() ?? false }
        }
        if Defaults[.enableWindowSwitcher], Defaults[.enableTrackpadSwitcherSwipe] {
            trackpadSwipeTrigger = TrackpadSwipeTrigger { [weak self] event in
                self?.handleTrackpadSwipe(event)
            }
        }
    }

    func reset() {
        cleanup()
        resetState()
        setupEventTap()
        startMonitoring()
        trackpadSwipeTrigger?.reset()
    }

    func recover() {
        reset()
        switcherSessionActive = false
        hasProcessedModifierRelease = true
        isCommandKeyCurrentlyDown = false
        lastCmdTabObservedActive = false
        cmdTabActionPerformed = false
        Task { @MainActor in
            if self.windowSwitchingCoordinator.isActive(previewCoordinator: self.previewCoordinator) {
                self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                self.previewCoordinator.hideWindow()
            }
        }
    }

    private func cleanup() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        heldKeyRepeatTask?.cancel()
        heldKeyRepeatTask = nil
        removeEventTap()
    }

    /// Cancels any running held-key repeat task to prevent main thread blocking
    func cancelHeldKeyRepeatTask() {
        heldKeyRepeatTask?.cancel()
        heldKeyRepeatTask = nil
    }

    private func resetState() {
        isSwitcherModifierKeyPressed = false
        isShiftKeyPressedGeneral = false
        preventSwitcherHideOnRelease = false
        currentInvocationMode = .allWindows
        cancelHeldKeyRepeatTask()
    }

    private func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.checkEventTapStatus()
        }
    }

    private func checkEventTapStatus() {
        guard let eventTap, CGEvent.tapIsEnabled(tap: eventTap) else {
            reset()
            return
        }
    }

    private static let eventCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        return Unmanaged<KeybindHelperUserInfo>.fromOpaque(refcon).takeUnretainedValue().instance.handleEvent(proxy: proxy, type: type, event: event)
    }

    private func setupEventTap() {
        guard eventTap == nil, DockObserver.canPostEvents else { return }

        let eventMask = (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue)

        let userInfo = KeybindHelperUserInfo(instance: self)
        let retainedUserInfo = Unmanaged.passRetained(userInfo)

        guard let newEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: KeybindHelper.eventCallback,
            userInfo: retainedUserInfo.toOpaque()
        ) else {
            retainedUserInfo.release()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                print("Retrying KeybindHelper event tap setup...")
                self?.setupEventTap()
            }
            return
        }

        unmanagedEventTapUserInfo = retainedUserInfo
        eventTap = newEventTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newEventTap, 0)

        if let runLoopSource {
            EventTapThread.shared.add(runLoopSource)
            CGEvent.tapEnable(tap: newEventTap, enable: true)
        }
    }

    private func removeEventTap() {
        if let eventTap {
            let userInfo = unmanagedEventTapUserInfo
            EventTapThread.shared.remove(eventTap, source: runLoopSource) { userInfo?.release() }
        }
        unmanagedEventTapUserInfo = nil
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Keys typed while the tap was disabled would reach the native switcher unseen
        // (Command+Q quits, Command+H hides), so a search session cannot survive that.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, DockObserver.isCmdTabSearchSession {
            DispatchQueue.main.async { DockObserver.activeInstance?.endCmdTabSearchSession() }
        }
        if let passthrough = reEnableIfNeeded(tap: eventTap, type: type, event: event) {
            return passthrough
        }

        switch type {
        case .flagsChanged:
            let keyBoardShortcutSaved = sessionKeybind()
            let (currentSwitcherModifierIsPressed, currentShiftState) = updateModifierStatesFromFlags(event: event, keyBoardShortcutSaved: keyBoardShortcutSaved)

            // Track Command up/down explicitly for Cmd+Tab fallback behavior
            let cmdNowDown = event.flags.contains(.maskCommand)
            if isCommandKeyCurrentlyDown, !cmdNowDown {
                let observedCmdTab = Defaults[.enableCmdTabEnhancements] && lastCmdTabObservedActive
                let actionAlreadyHandled = cmdTabActionPerformed
                let wasVisible = previewCoordinator.tapSnapshot.isVisible
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Land a pending native-highlight write before the system reads
                        // the selection to activate an app.
                        self.flushNativeSelectionSync()
                        if observedCmdTab {
                            if actionAlreadyHandled {
                                self.previewCoordinator.hideWindow()
                            } else if wasVisible, self.previewCoordinator.windowSwitcherCoordinator.currIndex >= 0 {
                                self.previewCoordinator.selectAndBringToFrontCurrentWindow()
                            } else {
                                self.previewCoordinator.hideWindow()
                            }
                            self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                        }
                    }
                    // Tear down only after the selected window was activated: a converted
                    // search session is dismissed here, which clears the panel selection.
                    DockObserver.activeInstance?.teardownCmdTabObserver()
                }
                lastCmdTabObservedActive = false
                cmdTabActionPerformed = false
            }
            isCommandKeyCurrentlyDown = cmdNowDown

            var effectiveSwitcherModifierIsPressed = currentSwitcherModifierIsPressed
            if switcherSessionActive {
                let saved = keyBoardShortcutSaved.modifierFlags
                let f = event.flags
                let requiredModifiersHeld =
                    ((saved & Int(CGEventFlags.maskAlternate.rawValue)) == 0 || f.contains(.maskAlternate)) &&
                    ((saved & Int(CGEventFlags.maskControl.rawValue)) == 0 || f.contains(.maskControl)) &&
                    ((saved & Int(CGEventFlags.maskCommand.rawValue)) == 0 || f.contains(.maskCommand))
                if requiredModifiersHeld {
                    effectiveSwitcherModifierIsPressed = true
                } else {
                    switcherSessionActive = false
                }
            }

            Task { @MainActor [weak self] in
                self?.handleModifierEvent(currentSwitcherModifierIsPressed: effectiveSwitcherModifierIsPressed, currentShiftState: currentShiftState)
            }

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let shouldRouteCmdTabToWindowSwitcher = isCmdTabWindowSwitcherKeybind(keyCode: keyCode, flags: flags)

            // Consume bare spacebar for a visible media preview so it doesn't also reach the focused app and double-toggle playback.
            if keyCode == Int64(kVK_Space),
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               !flags.hasSuperfluousModifiers(),
               MediaKeyboardShortcutCoordinator.shared.handleSpaceKeyDown()
            {
                return nil
            }

            let backwardKeyCode = Defaults[.switcherBackwardKeyCode]
            if Self.eventFlagForKeyCode(backwardKeyCode) == nil,
               keyCode == Int64(backwardKeyCode),
               previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive
            {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    handleModifierEvent(
                        currentSwitcherModifierIsPressed: isSwitcherModifierKeyPressed,
                        currentShiftState: true
                    )
                }
                return nil
            }

            // Detect Cmd+Tab press to start on-demand polling for the switcher
            if Defaults[.enableCmdTabEnhancements],
               keyCode == Int64(kVK_Tab),
               flags.contains(.maskCommand)
            {
                if !shouldRouteCmdTabToWindowSwitcher {
                    DispatchQueue.main.async { DockObserver.activeInstance?.startCmdTabPolling() }
                }
            }

            // If system Cmd+Tab switcher is active, optionally handle arrows when enhancements are enabled
            if DockObserver.isCmdTabSwitcherActive, shouldRouteCmdTabToWindowSwitcher {
                DispatchQueue.main.async { DockObserver.activeInstance?.teardownCmdTabObserver() }
                lastCmdTabObservedActive = false
                cmdTabActionPerformed = false
            } else if DockObserver.isCmdTabSwitcherActive {
                lastCmdTabObservedActive = true
                // Search session: every key except Escape and the native-cycling keys is
                // routed through the existing window-switcher key handling (characters,
                // arrows, Enter) and swallowed, so letters type into the search instead
                // of reaching the native switcher. Applies from the first instant of the
                // session, before the panel has rendered, so an early keystroke cannot leak.
                if DockObserver.isCmdTabSearchSession {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    switch CmdTabSessionKey.disposition(forKeyCode: keyCode) {
                    case .escape:
                        // End the session right away instead of waiting for the Dock to
                        // announce that the switcher went away; the existing Escape branch
                        // below still dismisses the panel and passes Escape on.
                        DispatchQueue.main.async { DockObserver.activeInstance?.endCmdTabSearchSession() }
                    case .passToSystem:
                        // Tab, Shift+Tab and the backward key keep cycling the native
                        // strip (muscle memory: they move between apps); the panel
                        // follows through reflectNativeSelectionIntoSearchSession.
                        return Unmanaged.passUnretained(event)
                    case .consume:
                        let (_, actionTask) = determineActionForKeyDown(event: event)
                        if let actionTask {
                            dispatchHeldKeyAction(actionTask)
                        }
                        return nil
                    }
                }

                if Defaults[.enableCmdTabEnhancements],
                   previewCoordinator.tapSnapshot.isVisible
                {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let hasSelection = previewCoordinator.windowSwitcherCoordinator.currIndex >= 0
                    let flags = event.flags

                    switch keyCode {
                    case Int64(kVK_Escape):
                        Task { @MainActor in
                            self.previewCoordinator.hideWindow()
                        }
                        // Pass Escape through so the Dock can dismiss the system switcher too
                        return Unmanaged.passUnretained(event)
                    case Int64(kVK_LeftArrow):
                        if hasSelection {
                            Task { @MainActor in
                                self.previewCoordinator.navigateWithArrowKey(direction: .left)
                            }
                            // Consume only when a selection is active (focused mode)
                            return nil
                        } else {
                            // Let system Cmd+Tab handle left/right until user focuses with Up
                            return Unmanaged.passUnretained(event)
                        }
                    case Int64(kVK_RightArrow):
                        if hasSelection {
                            Task { @MainActor in
                                self.previewCoordinator.navigateWithArrowKey(direction: .right)
                            }
                            return nil
                        } else {
                            return Unmanaged.passUnretained(event)
                        }
                    case Int64(kVK_UpArrow):
                        return Unmanaged.passUnretained(event)
                    case Int64(kVK_DownArrow):
                        // If a preview is selected, first Down just deselects and is consumed.
                        // Subsequent Down (with no selection) is passed through to system Exposé.
                        if hasSelection {
                            Task { @MainActor in
                                self.previewCoordinator.windowSwitcherCoordinator.setIndex(to: -1)
                            }
                            return nil
                        } else {
                            return Unmanaged.passUnretained(event)
                        }
                    case Int64(kVK_ANSI_H), Int64(kVK_ANSI_L):
                        if Defaults[.enableVimMotions], hasSelection {
                            let dir: ArrowDirection = keyCode == Int64(kVK_ANSI_H) ? .left : .right
                            Task { @MainActor in
                                self.previewCoordinator.navigateWithArrowKey(direction: dir)
                            }
                            return nil
                        } else {
                            return Unmanaged.passUnretained(event)
                        }
                    case Int64(kVK_ANSI_J):
                        if Defaults[.enableVimMotions], hasSelection {
                            Task { @MainActor in
                                self.previewCoordinator.windowSwitcherCoordinator.setIndex(to: -1)
                            }
                            return nil
                        } else {
                            return Unmanaged.passUnretained(event)
                        }
                    case Int64(Defaults[.searchTriggerKey]):
                        // Open the search session from the Cmd+Tab overlay. The general
                        // determineActionForKeyDown path is unreachable while the native
                        // switcher is active (this block always returns), so the trigger
                        // has to be handled here.
                        if Defaults[.enableWindowSwitcherSearch], !previewCoordinator.tapSnapshot.isSearchFocused {
                            Task { @MainActor in
                                self.convertCmdTabOverlayToSearch()
                            }
                            return nil
                        }
                        return Unmanaged.passUnretained(event)
                    default:
                        // Allow activation via customizable Cmd+key (when not yet focused) and
                        // Command-based actions when a preview is focused
                        if flags.contains(.maskCommand) {
                            if hasSelection, keyCode == Int64(Defaults[.cmdTabBackwardCycleKey]) {
                                Task { @MainActor in
                                    let currentIndex = self.previewCoordinator.windowSwitcherCoordinator.currIndex
                                    let windowCount = self.previewCoordinator.windowSwitcherCoordinator.windows.count
                                    let newIndex = currentIndex > 0 ? currentIndex - 1 : windowCount - 1
                                    self.previewCoordinator.windowSwitcherCoordinator.setIndex(to: newIndex)
                                }
                                return nil
                            }

                            // Forward cycle key (default: A)
                            if keyCode == Int64(Defaults[.cmdTabCycleKey]) {
                                Task { @MainActor in
                                    let currentIndex = self.previewCoordinator.windowSwitcherCoordinator.currIndex
                                    let windowCount = self.previewCoordinator.windowSwitcherCoordinator.windows.count
                                    let isShift = flags.contains(.maskShift)

                                    if !hasSelection {
                                        // First activation: select first preview
                                        self.previewCoordinator.windowSwitcherCoordinator.setIndex(to: 0)
                                        Defaults[.hasSeenCmdTabFocusHint] = true
                                    } else if isShift {
                                        // Cmd+Shift+A: cycle backward
                                        let newIndex = currentIndex > 0 ? currentIndex - 1 : windowCount - 1
                                        self.previewCoordinator.windowSwitcherCoordinator.setIndex(to: newIndex)
                                    } else {
                                        // Cmd+A: cycle forward
                                        let newIndex = (currentIndex + 1) % windowCount
                                        self.previewCoordinator.windowSwitcherCoordinator.setIndex(to: newIndex)
                                    }
                                }
                                return nil
                            }
                        }

                        if hasSelection, flags.contains(.maskCommand),
                           !previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive
                        {
                            // Check configurable Cmd+key shortcuts.
                            // Skipped while the Cmd+Tab overlay is converted into a search
                            // session: letters must reach the search field, not actions.
                            if let action = getActionForCmdShortcut(keyCode: keyCode) {
                                cmdTabActionPerformed = true
                                Task { @MainActor in
                                    self.previewCoordinator.performActionOnCurrentWindow(action: action)
                                }
                                return nil
                            }
                        }
                    }
                }
                // Not enhancing or not in our cmdTab context — let the system handle it.
                return Unmanaged.passUnretained(event)
            }
            let (shouldConsume, actionTask) = determineActionForKeyDown(event: event)
            if let task = actionTask {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    heldKeyRepeatTask?.cancel()
                    heldKeyRepeatTask = Task { @MainActor in
                        await task()
                    }
                }
            }
            if shouldConsume { return nil }

        case .leftMouseDown:
            let isWindowSwitcherActive = previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive
            let isCmdTabActive = DockObserver.isCmdTabSwitcherActive

            let snapshot = previewCoordinator.tapSnapshot
            if snapshot.isVisible, isWindowSwitcherActive || isCmdTabActive {
                let clickLocation = NSEvent.mouseLocation
                let isInSearchWindow = snapshot.searchFrame?.contains(clickLocation) ?? false
                if snapshot.frame.contains(clickLocation) || isInSearchWindow {
                    let flags = event.flags
                    if flags.contains(.maskControl) {
                        var newFlags = flags
                        newFlags.remove(.maskControl)
                        event.flags = newFlags
                    }
                } else {
                    switcherSessionActive = false
                    Task { @MainActor in
                        if isWindowSwitcherActive {
                            self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                            self.preventSwitcherHideOnRelease = false
                            self.hasProcessedModifierRelease = true
                        }
                        if isCmdTabActive {
                            DockObserver.activeInstance?.teardownCmdTabObserver()
                        }
                        self.previewCoordinator.hideWindow()
                    }
                }
            }

        case .keyUp:
            let backwardKeyCode = Defaults[.switcherBackwardKeyCode]
            if Self.eventFlagForKeyCode(backwardKeyCode) == nil,
               event.getIntegerValueField(.keyboardEventKeycode) == Int64(backwardKeyCode)
            {
                Task { @MainActor [weak self] in
                    self?.isShiftKeyPressedGeneral = false
                    self?.cancelHeldKeyRepeatTask()
                }
            }

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private static func eventFlagForKeyCode(_ keyCode: UInt16) -> CGEventFlags? {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift: .maskShift
        case kVK_Control, kVK_RightControl: .maskControl
        case kVK_Option, kVK_RightOption: .maskAlternate
        case kVK_Command, kVK_RightCommand: .maskCommand
        default: nil
        }
    }

    private func alternateKeybinds() -> [(keybind: UserKeyBind, mode: SwitcherInvocationMode)] {
        let primaryModifierFlags = Defaults[.UserKeybind].modifierFlags
        return AlternateKeybind.all.compactMap { alternate in
            alternate.resolved(primaryModifierFlags: primaryModifierFlags).map { ($0, alternate.mode) }
        }
    }

    private func sessionKeybind() -> UserKeyBind {
        switcherSessionActive ? activeSessionKeybind : Defaults[.UserKeybind]
    }

    private func beginSwitcherSession(with keybind: UserKeyBind) {
        activeSessionKeybind = keybind
        switcherSessionActive = true
    }

    private func isCmdTabWindowSwitcherKeybind(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == Int64(kVK_Tab), flags.contains(.maskCommand) else { return false }
        return tabKeybinds().contains { modifierFlagsMatch($0.modifierFlags, flags: flags) }
    }

    private func usesCmdTabWindowSwitcherKeybind() -> Bool {
        tabKeybinds().contains { modifierFlagsMatch($0.modifierFlags, flags: .maskCommand) }
    }

    private func tabKeybinds() -> [UserKeyBind] {
        guard Defaults[.enableWindowSwitcher] else { return [] }
        return ([Defaults[.UserKeybind]] + alternateKeybinds().map(\.keybind)).filter { $0.keyCode == UInt16(kVK_Tab) }
    }

    private func modifierFlagsMatch(_ saved: Int, flags: CGEventFlags) -> Bool {
        let wantsAlt = (saved & Int(CGEventFlags.maskAlternate.rawValue)) != 0
        let wantsCtrl = (saved & Int(CGEventFlags.maskControl.rawValue)) != 0
        let wantsCmd = (saved & Int(CGEventFlags.maskCommand.rawValue)) != 0

        return wantsAlt == flags.contains(.maskAlternate) &&
            wantsCtrl == flags.contains(.maskControl) &&
            wantsCmd == flags.contains(.maskCommand)
    }

    private func updateModifierStatesFromFlags(event: CGEvent, keyBoardShortcutSaved: UserKeyBind) -> (currentSwitcherModifierIsPressed: Bool, currentShiftState: Bool) {
        let saved = keyBoardShortcutSaved.modifierFlags
        let wantsAlt = (saved & Int(CGEventFlags.maskAlternate.rawValue)) != 0
        let wantsCtrl = (saved & Int(CGEventFlags.maskControl.rawValue)) != 0
        let wantsCmd = (saved & Int(CGEventFlags.maskCommand.rawValue)) != 0

        let flags = event.flags
        let hasAlt = flags.contains(.maskAlternate)
        let hasCtrl = flags.contains(.maskControl)
        let hasCmd = flags.contains(.maskCommand)

        let backwardFlag = Self.eventFlagForKeyCode(Defaults[.switcherBackwardKeyCode])
        let altMatch = backwardFlag == .maskAlternate || (wantsAlt == hasAlt)
        let ctrlMatch = backwardFlag == .maskControl || (wantsCtrl == hasCtrl)
        let cmdMatch = backwardFlag == .maskCommand || (wantsCmd == hasCmd)
        let currentSwitcherModifierIsPressed = altMatch && ctrlMatch && cmdMatch

        let currentShiftState: Bool = if let flag = backwardFlag {
            flags.contains(flag)
        } else {
            isShiftKeyPressedGeneral
        }

        return (currentSwitcherModifierIsPressed, currentShiftState)
    }

    @MainActor
    private func handleModifierEvent(currentSwitcherModifierIsPressed: Bool, currentShiftState: Bool) {
        // If system Cmd+Tab switcher is active, do not engage DockDoor's own switcher logic
        if DockObserver.isCmdTabSwitcherActive {
            guard usesCmdTabWindowSwitcherKeybind() else { return }
            DockObserver.activeInstance?.teardownCmdTabObserver()
        }
        let oldSwitcherModifierState = isSwitcherModifierKeyPressed
        let oldShiftState = isShiftKeyPressedGeneral

        isSwitcherModifierKeyPressed = currentSwitcherModifierIsPressed
        isShiftKeyPressedGeneral = currentShiftState

        if preventSwitcherHideOnRelease, !previewCoordinator.isVisible {
            preventSwitcherHideOnRelease = false
        }

        if !oldSwitcherModifierState && currentSwitcherModifierIsPressed {
            hasProcessedModifierRelease = false
        }

        let isWindowSwitcherActive = previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive
        let shouldSkipShiftOnlyBackward = Defaults[.requireShiftTabToGoBack] && isWindowSwitcherActive

        // Only allow Shift-only backward cycling when the window switcher is already active.
        if !oldShiftState, currentShiftState,
           previewCoordinator.isVisible,
           isWindowSwitcherActive,
           currentSwitcherModifierIsPressed || Defaults[.preventSwitcherHide]
        {
            if !shouldSkipShiftOnlyBackward {
                Task { @MainActor in
                    await self.windowSwitchingCoordinator.handleWindowSwitching(
                        previewCoordinator: self.previewCoordinator,
                        isModifierPressed: currentSwitcherModifierIsPressed,
                        isShiftPressed: true,
                        mode: self.currentInvocationMode
                    )
                }

                if isWindowSwitcherActive {
                    heldKeyRepeatTask?.cancel()
                    heldKeyRepeatTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)

                        while !Task.isCancelled,
                              self.isShiftKeyPressedGeneral,
                              self.previewCoordinator.isVisible,
                              self.previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive
                        {
                            await self.windowSwitchingCoordinator.handleWindowSwitching(
                                previewCoordinator: self.previewCoordinator,
                                isModifierPressed: self.isSwitcherModifierKeyPressed,
                                isShiftPressed: true,
                                mode: self.currentInvocationMode
                            )
                            try? await Task.sleep(nanoseconds: 80_000_000)
                        }
                    }
                }
            }
        }

        if oldShiftState, !currentShiftState {
            cancelHeldKeyRepeatTask()
        }

        if !Defaults[.preventSwitcherHide], !preventSwitcherHideOnRelease, !(previewCoordinator.isSearchWindowFocused) {
            if oldSwitcherModifierState, !isSwitcherModifierKeyPressed, !hasProcessedModifierRelease {
                hasProcessedModifierRelease = true
                preventSwitcherHideOnRelease = false
                selectOnSwitcherRelease()
            }
        }
    }

    @MainActor
    private func selectOnSwitcherRelease() {
        windowSwitchingCoordinator.cancelPendingRender()
        let stashedWindow = windowStashedByShortcut
        windowStashedByShortcut = nil

        Task { @MainActor in
            if let stashedWindow,
               let selectedWindow = self.previewCoordinator.windowSwitcherCoordinator.getCurrentWindow(),
               selectedWindow.id == stashedWindow.id,
               selectedWindow.app.processIdentifier == stashedWindow.app.processIdentifier,
               selectedWindow.isMinimized || selectedWindow.isHidden
            {
                self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                self.previewCoordinator.hideWindow()
                return
            }

            if self.previewCoordinator.isVisible, self.previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive {
                self.previewCoordinator.selectAndBringToFrontCurrentWindow()
                self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
            } else if let selectedWindow = self.windowSwitchingCoordinator.selectCurrentWindow(previewCoordinator: self.previewCoordinator) {
                selectedWindow.bringToFront()
                selectedWindow.warpMouseToCenterIfNeeded()
                if selectedWindow.isWindowlessApp, Defaults[.openNewWindowForWindowlessApps] {
                    WindowUtil.activateAndOpenNewWindow(app: selectedWindow.app)
                }
                self.previewCoordinator.hideWindow()
            }
        }
    }

    @MainActor
    func handleGestureSwitcher(_ event: TrackpadSwipeEvent) {
        handleTrackpadSwipe(event, requiresSwipeSetting: false)
    }

    @MainActor
    private func handleTrackpadSwipe(_ event: TrackpadSwipeEvent, requiresSwipeSetting: Bool = true) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch event {
            case .open, .cycleForward, .cycleBackward:
                guard Defaults[.enableWindowSwitcher], !requiresSwipeSetting || Defaults[.enableTrackpadSwitcherSwipe] else { return }
                if event == .open {
                    guard !WindowUtil.shouldIgnoreKeybindForFrontmostApp() else { return }
                    if !windowSwitchingCoordinator.isActive(previewCoordinator: previewCoordinator) {
                        windowSwitchingCoordinator.trackpadOpenedCurrentSession = true
                    }
                }
                await windowSwitchingCoordinator.handleWindowSwitching(
                    previewCoordinator: previewCoordinator,
                    isModifierPressed: event == .open,
                    isShiftPressed: event == .cycleBackward
                )
            case .release:
                guard windowSwitchingCoordinator.trackpadOpenedCurrentSession else { return }
                windowSwitchingCoordinator.trackpadOpenedCurrentSession = false
                guard !Defaults[.preventSwitcherHide],
                      !(Defaults[.focusSearchOnWindowSwitcherOpen] && Defaults[.enableWindowSwitcherSearch]),
                      !previewCoordinator.isSearchWindowFocused
                else { return }
                selectOnSwitcherRelease()
            case .cancel:
                guard windowSwitchingCoordinator.trackpadOpenedCurrentSession else { return }
                windowSwitchingCoordinator.trackpadOpenedCurrentSession = false
                windowSwitchingCoordinator.cancelSwitching(previewCoordinator: previewCoordinator)
                previewCoordinator.hideWindow()
            }
        }
    }

    private func determineActionForKeyDown(event: CGEvent) -> (shouldConsume: Bool, actionTask: (() async -> Void)?) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let keyBoardShortcutSaved: UserKeyBind = Defaults[.UserKeybind]
        let alternateShortcuts = alternateKeybinds()
        let snapshot = previewCoordinator.tapSnapshot
        let previewIsCurrentlyVisible = snapshot.isVisible || switcherSessionActive

        let isDesiredModifierPressedNow = modifierFlagsMatch(keyBoardShortcutSaved.modifierFlags, flags: flags)
        let isExactSwitcherShortcutPressed = keyCode == keyBoardShortcutSaved.keyCode &&
            (isDesiredModifierPressedNow || keyBoardShortcutSaved.modifierFlags == 0)
        let pressedAlternateShortcut = alternateShortcuts.first {
            keyCode == $0.keybind.keyCode && modifierFlagsMatch($0.keybind.modifierFlags, flags: flags)
        }

        if previewIsCurrentlyVisible || snapshot.fullPreviewFrame != nil,
           keyCode == kVK_Escape, !isExactSwitcherShortcutPressed, pressedAlternateShortcut == nil
        {
            switcherSessionActive = false
            return (true, { @MainActor in
                self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                self.previewCoordinator.hideWindow()
                self.preventSwitcherHideOnRelease = false
                self.hasProcessedModifierRelease = true
            })
        }

        if previewIsCurrentlyVisible {
            if isPreviewShortcutModifierHeld(flags), previewCoordinator.windowSwitcherCoordinator.currIndex >= 0,
               !DockObserver.isCmdTabSearchSession
            {
                if let action = getActionForCmdShortcut(keyCode: keyCode) {
                    preventSwitcherHideOnRelease = true
                    return (true, { @MainActor in
                        let keepsSwitcherOpen = self.previewCoordinator.performActionOnCurrentWindow(action: action)
                        self.windowStashedByShortcut = action == .minimize || action == .hide
                            ? self.previewCoordinator.windowSwitcherCoordinator.getCurrentWindow()
                            : nil
                        if !keepsSwitcherOpen || self.previewCoordinator.windowSwitcherCoordinator.windows.isEmpty {
                            self.switcherSessionActive = false
                            self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                            self.preventSwitcherHideOnRelease = false
                            self.hasProcessedModifierRelease = true
                        } else {
                            self.preventSwitcherHideOnRelease = false

                            if !Defaults[.preventSwitcherHide], !self.isSwitcherModifierKeyPressed {
                                self.switcherSessionActive = false
                                self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                                self.hasProcessedModifierRelease = true
                                self.previewCoordinator.hideWindow()
                            }
                        }
                    })
                }
            }
        }

        if isExactSwitcherShortcutPressed {
            guard Defaults[.enableWindowSwitcher] else { return (false, nil) }
            if WindowUtil.shouldIgnoreKeybindForFrontmostApp() { return (false, nil) }
            beginSwitcherSession(with: keyBoardShortcutSaved)
            return (true, {
                await self.handleKeybindActivation(
                    mode: .allWindows,
                    isModifierPressed: true,
                    isShiftPressed: flags.contains(.maskShift)
                )
            })
        }

        if let pressedAlternateShortcut {
            guard Defaults[.enableWindowSwitcher] else { return (false, nil) }
            if WindowUtil.shouldIgnoreKeybindForFrontmostApp() { return (false, nil) }
            beginSwitcherSession(with: pressedAlternateShortcut.keybind)
            let mode = pressedAlternateShortcut.mode
            return (true, {
                await self.handleKeybindActivation(
                    mode: mode,
                    isModifierPressed: true,
                    isShiftPressed: flags.contains(.maskShift)
                )
            })
        }

        if previewIsCurrentlyVisible {
            if keyCode == kVK_Tab {
                let isShiftPressed = isShiftKeyPressedGeneral

                return (true, { @MainActor in
                    if self.previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive {
                        if !self.previewCoordinator.windowSwitcherCoordinator.hasActiveSearch {
                            let shouldGoBackward = isShiftPressed &&
                                (!Defaults[.requireShiftTabToGoBack] ||
                                    self.isSwitcherModifierKeyPressed ||
                                    Defaults[.preventSwitcherHide])

                            await self.windowSwitchingCoordinator.handleWindowSwitching(
                                previewCoordinator: self.previewCoordinator,
                                isModifierPressed: self.isSwitcherModifierKeyPressed,
                                isShiftPressed: shouldGoBackward,
                                mode: self.currentInvocationMode
                            )
                        }
                    } else {
                        self.previewCoordinator.navigateWithArrowKey(direction: .right)
                    }
                })
            }

            switch keyCode {
            case Int64(kVK_LeftArrow), Int64(kVK_RightArrow), Int64(kVK_UpArrow), Int64(kVK_DownArrow):
                if Defaults[.passArrowsThroughToSystem], flags.contains(.maskControl) {
                    return (false, nil)
                }
                let dir: ArrowDirection = switch keyCode {
                case Int64(kVK_LeftArrow):
                    .left
                case Int64(kVK_RightArrow):
                    .right
                case Int64(kVK_UpArrow):
                    .up
                default:
                    .down
                }
                return (true, { @MainActor in
                    self.previewCoordinator.navigateWithArrowKey(direction: dir)
                })
            case Int64(kVK_ANSI_H), Int64(kVK_ANSI_J), Int64(kVK_ANSI_K), Int64(kVK_ANSI_L):
                if Defaults[.enableVimMotions],
                   !snapshot.isSearchFocused,
                   allowsVimMotionNavigation(flags: flags, keyBoardShortcutSaved: sessionKeybind()),
                   !DockObserver.isCmdTabSearchSession
                {
                    let dir: ArrowDirection = switch keyCode {
                    case Int64(kVK_ANSI_H): .left
                    case Int64(kVK_ANSI_L): .right
                    case Int64(kVK_ANSI_K): .up
                    default: .down
                    }
                    return (true, { @MainActor in
                        self.previewCoordinator.navigateWithArrowKey(direction: dir)
                    })
                }
            case Int64(Defaults[.windowSwitcherSelectionKeyCode]), Int64(kVK_Return), Int64(kVK_ANSI_KeypadEnter):
                if previewCoordinator.windowSwitcherCoordinator.currIndex >= 0 {
                    return (true, makeEnterSelectionTask())
                }
            default:
                break
            }
        }

        if previewIsCurrentlyVisible,
           previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive,
           Defaults[.enableWindowSwitcherSearch],
           keyCode == Int64(Defaults[.searchTriggerKey]),
           !snapshot.isSearchFocused
        {
            // During a converted Cmd+Tab search the field must stay unfocused:
            // a focused field would turn Command-held keystrokes into shortcuts.
            let focusField = !DockObserver.isCmdTabSearchSession
            return (true, { @MainActor in
                self.previewCoordinator.focusSearchWindow(focusField: focusField)
                self.preventSwitcherHideOnRelease = true
            })
        }
        if previewIsCurrentlyVisible,
           previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive,
           Defaults[.enableWindowSwitcherSearch],
           !snapshot.isSearchFocused
        {
            if keyCode == Int64(kVK_Delete) {
                return (true, { @MainActor in
                    var query = self.previewCoordinator.windowSwitcherCoordinator.searchQuery
                    if !query.isEmpty {
                        query.removeLast()
                        self.previewCoordinator.windowSwitcherCoordinator.searchQuery = query
                        SharedPreviewWindowCoordinator.activeInstance?.updateSearchWindow(with: query)

                        if query.isEmpty {
                            self.preventSwitcherHideOnRelease = false
                        }
                    }
                })
            }

            if !flags.contains(.maskCommand) || DockObserver.isCmdTabSwitcherActive {
                var length = 0
                var buffer = [UniChar](repeating: 0, count: 4)
                event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
                let characters = String(utf16CodeUnits: buffer, count: length)
                let filteredChars = characters.filter { char in
                    char.isLetter || char.isNumber || char.isWhitespace ||
                        ".,!?-_()[]{}@#$%^&*+=|\\:;\"'<>/~`".contains(char)
                }
                if !filteredChars.isEmpty {
                    return (true, { @MainActor in
                        self.previewCoordinator.windowSwitcherCoordinator.searchQuery.append(contentsOf: filteredChars)
                        let newQuery = self.previewCoordinator.windowSwitcherCoordinator.searchQuery
                        SharedPreviewWindowCoordinator.activeInstance?.updateSearchWindow(with: newQuery)

                        if !newQuery.isEmpty {
                            self.preventSwitcherHideOnRelease = true
                        }
                    })
                }
            }
        }

        if previewIsCurrentlyVisible,
           previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive,
           !isSwitcherModifierKeyPressed,
           !flags.hasSuperfluousModifiers(ignoring: [Self.eventFlagForKeyCode(Defaults[.switcherBackwardKeyCode]) ?? .maskShift, .maskAlphaShift, .maskNumericPad])
        {
            let retriggerMode: SwitcherInvocationMode? = if keyCode == keyBoardShortcutSaved.keyCode, keyBoardShortcutSaved.modifierFlags != 0 {
                .allWindows
            } else if let alternate = alternateShortcuts.first(where: { keyCode == $0.keybind.keyCode && $0.keybind.modifierFlags != 0 }) {
                alternate.mode
            } else {
                nil
            }
            if let retriggerMode {
                if WindowUtil.shouldIgnoreKeybindForFrontmostApp() { return (false, nil) }
                return (true, { await self.handleKeybindActivation(mode: retriggerMode) })
            }
        }

        return (false, nil)
    }

    private func isPreviewShortcutModifierHeld(_ flags: CGEventFlags) -> Bool {
        if flags.contains(.maskCommand) { return true }
        guard switcherSessionActive || previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive else { return false }
        let switcherModifiers = CGEventFlags(rawValue: UInt64(activeSessionKeybind.modifierFlags))
            .intersection([.maskAlternate, .maskControl, .maskCommand])
        return !switcherModifiers.isEmpty && flags.contains(switcherModifiers)
    }

    private func allowsVimMotionNavigation(flags: CGEventFlags, keyBoardShortcutSaved: UserKeyBind) -> Bool {
        var allowedModifiers: CGEventFlags = [.maskShift, .maskAlphaShift, .maskNumericPad]
        let saved = keyBoardShortcutSaved.modifierFlags

        if (saved & Int(CGEventFlags.maskAlternate.rawValue)) != 0 {
            allowedModifiers.insert(.maskAlternate)
        }
        if (saved & Int(CGEventFlags.maskControl.rawValue)) != 0 {
            allowedModifiers.insert(.maskControl)
        }
        if (saved & Int(CGEventFlags.maskCommand.rawValue)) != 0 {
            allowedModifiers.insert(.maskCommand)
        }
        if let backwardFlag = Self.eventFlagForKeyCode(Defaults[.switcherBackwardKeyCode]) {
            allowedModifiers.insert(backwardFlag)
        }

        let activeModifiers = flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift])
        return activeModifiers.subtracting(allowedModifiers).isEmpty
    }

    private func makeEnterSelectionTask() -> (() async -> Void) {
        { @MainActor in
            self.preventSwitcherHideOnRelease = false

            if self.previewCoordinator.isVisible, self.previewCoordinator.windowSwitcherCoordinator.windowSwitcherActive {
                self.previewCoordinator.selectAndBringToFrontCurrentWindow()
                self.windowSwitchingCoordinator.cancelSwitching(previewCoordinator: self.previewCoordinator)
                return
            }

            if let selectedWindow = self.windowSwitchingCoordinator.selectCurrentWindow(previewCoordinator: self.previewCoordinator) {
                selectedWindow.bringToFront()
                selectedWindow.warpMouseToCenterIfNeeded()
                if selectedWindow.isWindowlessApp, Defaults[.openNewWindowForWindowlessApps] {
                    WindowUtil.activateAndOpenNewWindow(app: selectedWindow.app)
                }
                self.previewCoordinator.hideWindow()
            } else {
                self.previewCoordinator.selectAndBringToFrontCurrentWindow()
            }
        }
    }

    /// Cancels any pending held-key repeat and schedules the new action task.
    private func dispatchHeldKeyAction(_ actionTask: @escaping () async -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            heldKeyRepeatTask?.cancel()
            heldKeyRepeatTask = Task { @MainActor in
                await actionTask()
            }
        }
    }

    // MARK: - Cmd+Tab search conversion

    /// Rebuilds the Cmd+Tab overlay as a full window-switcher session over every app's
    /// windows and focuses the search field. The native Cmd+Tab switcher stays on screen;
    /// its highlighted row is kept in sync via AX (see syncNativeCmdTabSelection), so
    /// releasing Command activates the app that owns the current search match.
    @MainActor
    func convertCmdTabOverlayToSearch() {
        guard DockObserver.isCmdTabSwitcherActive,
              !usesCmdTabWindowSwitcherKeybind(),
              Defaults[.enableCmdTabEnhancements],
              !IsSecureEventInputEnabled()
        else { return }

        if DockObserver.isCmdTabSearchSession {
            previewCoordinator.focusSearchWindow(focusField: false)
            return
        }

        let windows = windowSwitchingCoordinator.buildSwitcherWindows(mode: .allWindows)
        guard !windows.isEmpty else { return }

        // The native switcher's highlighted row already matches the overlay's current
        // selection at this point; seed the dedupe with it and skip the initial AX
        // write (it would target a half-initialized list — see the review round 2).
        let seededPID = previewCoordinator.windowSwitcherCoordinator.getCurrentWindow()?.app.processIdentifier

        presentSearchSession(with: windows)

        // Seed after presentation: the debounced initial write checks the seed at
        // fire time, so the pre-conversion highlight is never double-written.
        DockObserver.activeInstance?.cmdTabSelection.seed(seededPID)
    }

    /// Renders the full window-switcher search session over the given windows.
    /// Shared by the slash-trigger conversion and the instant direct-open mode. The
    /// search bar appears through the shared render path, exactly as in the Alt+Tab
    /// switcher (placeholder prompting the trigger key); it is never focused here.
    @MainActor
    private func presentSearchSession(with windows: [WindowInfo], selecting startPID: pid_t? = nil) {
        let coordinator = previewCoordinator.windowSwitcherCoordinator
        // Open on the display the native switcher is on; fall back to the overlay's
        // display, then the switcher's own placement strategy.
        let strip = DockObserver.activeInstance?.cmdTabSwitcherFrame()
        let stripScreen = strip.flatMap { frame in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        }
        let screen = stripScreen
            ?? coordinator.currentBestGuessMonitor
            ?? windowSwitchingCoordinator.getTargetScreenForSwitcher()

        // Top-anchor the panel: the search bar sits at a fixed spot at the top of the
        // visible frame and the results cascade below it. The panel's TOP stays put
        // while its height follows the filtered list, so neither the bar nor the top
        // edge jumps during filtering.
        let visFrame = screen.visibleFrame
        let barHeight: CGFloat = 40
        let topGap: CGFloat = 8
        let stripGap: CGFloat = 12
        let panelTopTarget = visFrame.maxY - barHeight - topGap

        // Keep the panel clear of the native strip: budget the layout to the space
        // between the strip's top edge and the search bar. A small floor keeps at
        // least a row visible; with no readable strip frame the normal screen-based
        // limit applies. Set before initialization so the first layout pass honors it.
        SwitcherHeightBudget.current = strip.map { CmdTabStripGeometry.heightBudget(panelTop: panelTopTarget, stripTop: $0.maxY, gap: stripGap, floor: 120) }

        // Flip the switcher state first so search filtering, navigation and Enter
        // selection all use the existing window-switcher code paths unchanged.
        // The overlay panel then resizes in place when showWindow renders the full
        // list, so there is no blink. Detach the callback first so initialization's
        // index changes cannot fire AX writes.
        coordinator.onSelectedIndexChanged = nil
        coordinator.setShowing(.windowSwitcher, toState: true)
        DockObserver.isCmdTabSearchSession = true
        coordinator.initializeForWindowSwitcher(with: windows, dockPosition: .cmdTab, bestGuessMonitor: screen)
        // Start on the requested app (the system's own initial highlight in instant
        // mode) before rendering, so the asynchronous render applies this index.
        if let startPID {
            coordinator.setIndex(to: coordinator.firstSearchIndex(forPID: startPID) ?? -1)
        }

        // Install after initialization so the callback never observes a half-built list.
        coordinator.onSelectedIndexChanged = { [weak self] _ in
            Task { @MainActor in
                self?.syncNativeCmdTabSelection()
            }
        }

        previewCoordinator.customOriginProvider = { size in
            let x = max(visFrame.minX, min(visFrame.midX - size.width / 2, visFrame.maxX - size.width))
            let y = max(visFrame.minY, panelTopTarget - size.height)
            return CGPoint(x: x, y: y)
        }

        previewCoordinator.showWindow(
            appName: "Window Switcher",
            windows: windows,
            mouseLocation: nil,
            mouseScreen: screen,
            dockItemElement: nil,
            overrideDelay: true,
            centeredHoverWindowState: .none,
            onWindowTap: {
                DockObserver.activeInstance?.hideWindowAndResetLastApp()
            },
            bundleIdentifier: nil,
            bypassDockMouseValidation: true,
            dockPositionOverride: .cmdTab,
            initialIndex: coordinator.currIndex
        )
    }

    /// Direct-open: Cmd+Tab opens straight into the full search session, skipping the
    /// single-app overlay entirely (instant mode). One window from the start.
    /// Returns false when the session cannot open, so the caller shows the normal overlay.
    @MainActor
    func presentInstantSearchSession() -> Bool {
        // Secure input hides keystrokes from the event tap; typed letters would then
        // reach the native switcher (Command+Q quits, Command+H hides), so never invite typing.
        guard DockObserver.isCmdTabSwitcherActive,
              Defaults[.enableCmdTabEnhancements],
              Defaults[.enableInstantCmdTabSearch],
              Defaults[.enableWindowSwitcherSearch],
              !usesCmdTabWindowSwitcherKeybind(),
              !IsSecureEventInputEnabled()
        else { return false }

        let windows = windowSwitchingCoordinator.buildSwitcherWindows(mode: .allWindows)
        guard !windows.isEmpty else { return false }

        // Start on the system's own initial highlight (the previous app), so a quick
        // Cmd+Tab-and-release still switches exactly like the stock switcher. Recording
        // it as already synced stops the panel from writing it back.
        let nativePID = DockObserver.activeInstance?.selectedCmdTabPID()
        DockObserver.activeInstance?.cmdTabSelection.seed(nativePID)
        presentSearchSession(with: windows, selecting: nativePID)
        return true
    }

    /// Runs a pending debounced native-highlight write immediately (used on Command release).
    @MainActor
    func flushNativeSelectionSync() {
        let pending = nativeSelectionSyncDebounce
        nativeSelectionSyncDebounce = nil
        guard let pending, !pending.isCancelled else { return }
        pending.perform()
        pending.cancel()
    }

    /// Mirrors the overlay's selected window onto the native Cmd+Tab switcher's
    /// highlighted row through the accessibility API, debounced so typing does not
    /// strobe the highlight across every intermediate match.
    @MainActor
    func syncNativeCmdTabSelection() {
        // Whatever was pending targets a selection that no longer exists, even when
        // there is no new target (no match, session over).
        nativeSelectionSyncDebounce?.cancel()
        nativeSelectionSyncDebounce = nil
        guard DockObserver.isCmdTabSearchSession else { return }
        guard let window = previewCoordinator.windowSwitcherCoordinator.getCurrentWindow() else { return }
        let bundleId = window.app.bundleIdentifier
        let appName = window.app.localizedName
        let pid = window.app.processIdentifier
        // Debounce: one AX write per pause in typing/navigation, not per keystroke —
        // per-keystroke writes strobe the native highlight across every intermediate
        // search match.
        // A native move by the user (Tab) after this was scheduled wins over the stale write.
        let generation = DockObserver.activeInstance?.cmdTabSelection.userMoveGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, DockObserver.isCmdTabSearchSession,
                  DockObserver.activeInstance?.cmdTabSelection.userMoveGeneration == generation
            else { return }
            _ = DockObserver.activeInstance?.selectCmdTabRow(matchingBundleId: bundleId,
                                                             appName: appName,
                                                             appPID: pid)
        }
        nativeSelectionSyncDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    @MainActor
    private func handleKeybindActivation(
        mode: SwitcherInvocationMode = .allWindows,
        isModifierPressed: Bool? = nil,
        isShiftPressed: Bool? = nil
    ) {
        guard Defaults[.enableWindowSwitcher] else { return }
        windowSwitchingCoordinator.trackpadOpenedCurrentSession = false
        windowStashedByShortcut = nil
        hasProcessedModifierRelease = false
        currentInvocationMode = mode
        let modifierPressedForActivation = isModifierPressed ?? isSwitcherModifierKeyPressed
        let shiftPressedForActivation = isShiftPressed ?? isShiftKeyPressedGeneral
        if modifierPressedForActivation {
            isSwitcherModifierKeyPressed = true
        }
        isShiftKeyPressedGeneral = shiftPressedForActivation
        if Defaults[.focusSearchOnWindowSwitcherOpen], Defaults[.enableWindowSwitcherSearch] {
            preventSwitcherHideOnRelease = true
        }
        Task { @MainActor in
            await windowSwitchingCoordinator.handleWindowSwitching(
                previewCoordinator: previewCoordinator,
                isModifierPressed: modifierPressedForActivation,
                isShiftPressed: shiftPressedForActivation,
                mode: mode
            )
        }
    }

    /// Returns the action for a Cmd+key shortcut if the keyCode matches any configured shortcut
    private func getActionForCmdShortcut(keyCode: Int64) -> WindowAction? {
        let shortcut1Key = Defaults[.cmdShortcut1Key]
        let shortcut2Key = Defaults[.cmdShortcut2Key]
        let shortcut3Key = Defaults[.cmdShortcut3Key]

        switch keyCode {
        case Int64(shortcut1Key):
            let action = Defaults[.cmdShortcut1Action]
            return action != .none ? action : nil
        case Int64(shortcut2Key):
            let action = Defaults[.cmdShortcut2Action]
            return action != .none ? action : nil
        case Int64(shortcut3Key):
            let action = Defaults[.cmdShortcut3Action]
            return action != .none ? action : nil
        default:
            return nil
        }
    }
}

/// Re-enables a disabled event tap and returns a passthrough result, or nil if the event type is not tap-disabled.
func reEnableIfNeeded(tap: CFMachPort?, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else { return nil }
    if let tap {
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    return Unmanaged.passUnretained(event)
}

extension CGEventFlags {
    func hasSuperfluousModifiers(ignoring: CGEventFlags = []) -> Bool {
        let significantModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let relevantToCheck = significantModifiers.subtracting(ignoring)
        return !intersection(relevantToCheck).isEmpty
    }
}
