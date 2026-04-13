import AppKit

class LilAgentsController {
    var characters: [WalkerCharacter] = []
    private var displayLink: CVDisplayLink?
    var debugWindow: NSWindow?
    var pinnedScreenIndex: Int = -1
    private static let onboardingKey = "hasCompletedOnboarding"
    private var isHiddenForEnvironment = false

    func start() {
        let char1 = WalkerCharacter(videoName: "red-combined-10s-hevc-alpha", name: "Merit")
        let char2 = WalkerCharacter(videoName: "blue-combined-10s-hevc-alpha", name: "Muse")

        // Detect available providers, then set first-run defaults
        AgentProvider.detectAvailableProviders { [weak char1, weak char2] in
            guard let char1 = char1, let char2 = char2 else { return }
            if !UserDefaults.standard.bool(forKey: Self.onboardingKey) {
                let first = AgentProvider.firstAvailable
                char1.provider = first
                char2.provider = first
            }
        }

        // Legacy easing if combined clip is ever used without `walkLoopVideoName`.
        char1.accelStart = 3.0
        char1.fullSpeedStart = 3.75
        char1.decelStart = 8.0
        char1.walkStop = 8.5
        char1.walkAmountRange = 0.16...0.32

        char2.accelStart = 3.0
        char2.fullSpeedStart = 3.75
        char2.decelStart = 8.0
        char2.walkStop = 8.5
        char2.walkAmountRange = 0.16...0.32
        char1.displayScale = 2.28
        char2.displayScale = 2.62
        char1.idleLoopVideoName = "red-idle-hevc-alpha"
        char2.idleLoopVideoName = "blue-idle-hevc-alpha"
        char1.popoverWaveLoopVideoName = "red-popover-wave-hevc-alpha"
        char2.popoverWaveLoopVideoName = "blue-popover-wave-hevc-alpha"
        char1.walkLoopVideoName = "red-walk-hevc-alpha"
        char2.walkLoopVideoName = "blue-walk-hevc-alpha"
        // ~4.08s walk MOVs @ 12fps — dock travel tracks stepping in this window.
        char1.walkHorizontalMoveVideoRange = 0.12...3.92
        char2.walkHorizontalMoveVideoRange = 0.12...3.92
        char1.horizontalMoveVideoRange = 3.22...7.30
        char2.horizontalMoveVideoRange = 3.22...7.30
        // Dock idle: short freeze → 5 idle loops (~15s motion) → stand-still 48–90s → repeat; walks use `pauseEndTime` (22–48s after each walk) unless long still extends it.
        char1.idlePlaybackRate = 0.68
        char2.idlePlaybackRate = 0.68
        char1.idleMotionBurstLoopCount = 5
        char2.idleMotionBurstLoopCount = 5
        char1.idleShortStillSecondsRange = 2.0...5.0
        char2.idleShortStillSecondsRange = 2.0...5.0
        char1.idleLongStillSecondsRange = 48...90
        char2.idleLongStillSecondsRange = 52...92
        char1.walkPlaybackRate = 0.88
        char2.walkPlaybackRate = 0.88
        char1.popoverWavePlaybackRate = 0.9
        char2.popoverWavePlaybackRate = 0.9
        char1.completionOneShotProbability = 0
        char2.completionOneShotProbability = 1.0
        // Keep Merit visually above Muse on overlaps.
        char1.windowLevelBoost = 80
        char2.windowLevelBoost = 0
        // Muse celebrates on turn completion via one-shot overlay clip.
        char2.completionOneShotVideoName = "victory-hevc-alpha"
        char1.yOffset = -2
        char2.yOffset = -2
        char1.characterColor = NSColor(red: 200 / 255, green: 55 / 255, blue: 46 / 255, alpha: 1.0)
        char2.characterColor = NSColor(red: 165 / 255, green: 193 / 255, blue: 231 / 255, alpha: 1.0)
        char1.personaInputHint = "Focus"
        char1.personaShortLabel = "Work"
        char2.personaInputHint = "Draft"
        char2.personaShortLabel = "Writing"

        char1.flipXOffset = 0
        char2.flipXOffset = -9

        // Start at the ends of the track (see `startWalk` edge rules: left tends right, right tends left)
        // so the first walk usually moves them apart instead of into the middle.
        char1.positionProgress = 0.1
        char2.positionProgress = 0.9

        char1.pauseEndTime = CACurrentMediaTime() + Double.random(in: 8.0...18.0)
        char2.pauseEndTime = CACurrentMediaTime() + Double.random(in: 35.0...55.0)

        char1.setup()
        char2.setup()

        characters = [char1, char2]
        characters.forEach { $0.controller = self }

        setupDebugLine()
        startDisplayLink()

        if !UserDefaults.standard.bool(forKey: Self.onboardingKey) {
            triggerOnboarding()
        }
    }

    private func triggerOnboarding() {
        guard let merit = characters.first else { return }
        merit.isOnboarding = true
        // Show "hi!" bubble after a short delay so the character is visible first
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            merit.currentPhrase = "hi!"
            merit.showingCompletion = true
            merit.completionBubbleExpiry = CACurrentMediaTime() + 600 // stays until clicked
            merit.showBubble(text: "hi!", isCompletion: true)
            merit.playCompletionSound()
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        characters.forEach { $0.isOnboarding = false }
    }

    // MARK: - Debug

    private func setupDebugLine() {
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 2),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = NSColor.red
        win.hasShadow = false
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.moveToActiveSpace, .stationary]
        win.orderOut(nil)
        debugWindow = win
    }

    private func updateDebugLine(dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        guard let win = debugWindow, win.isVisible else { return }
        win.setFrame(CGRect(x: dockX, y: dockTopY, width: dockWidth, height: 2), display: true)
    }

    // MARK: - Dock Geometry

    private func getDockIconArea(screenWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let tileSize = CGFloat(dockDefaults?.double(forKey: "tilesize") ?? 48)
        let slotWidth = tileSize * 1.25

        var persistentApps = dockDefaults?.array(forKey: "persistent-apps")?.count ?? 0
        var persistentOthers = dockDefaults?.array(forKey: "persistent-others")?.count ?? 0

        // Fallback for defaults reading issues
        if persistentApps == 0 && persistentOthers == 0 {
            persistentApps = 5
            persistentOthers = 3
        }

        let showRecents = dockDefaults?.bool(forKey: "show-recents") ?? true
        let recentApps = showRecents ? (dockDefaults?.array(forKey: "recent-apps")?.count ?? 0) : 0
        let totalIcons = persistentApps + persistentOthers + recentApps

        var dividers = 0
        if persistentApps > 0 && (persistentOthers > 0 || recentApps > 0) { dividers += 1 }
        if persistentOthers > 0 && recentApps > 0 { dividers += 1 }
        if showRecents && recentApps > 0 { dividers += 1 }

        let dividerWidth: CGFloat = 12.0
        var dockWidth = slotWidth * CGFloat(totalIcons) + CGFloat(dividers) * dividerWidth

        // Small fudge factor for dock edge padding
        dockWidth *= 1.15

        // Ensure a minimum width so characters aren't bunched together when
        // dock defaults under-report the icon count (common in sandboxed apps).
        let minDockWidth = screenWidth * 0.5
        dockWidth = max(dockWidth, minDockWidth)

        let dockX = (screenWidth - dockWidth) / 2.0
        return (dockX, dockWidth)
    }

    private func dockAutohideEnabled() -> Bool {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        return dockDefaults?.bool(forKey: "autohide") ?? false
    }

    // MARK: - Display Link

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink = displayLink else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let controller = Unmanaged<LilAgentsController>.fromOpaque(userInfo!).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.tick()
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(displayLink, callback,
                                       Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
    }

    var activeScreen: NSScreen? {
        if pinnedScreenIndex >= 0, pinnedScreenIndex < NSScreen.screens.count {
            return NSScreen.screens[pinnedScreenIndex]
        }
        // Prefer the screen that currently shows the dock (bottom inset in visibleFrame).
        // NSScreen.main changes with keyboard focus and must NOT be used here — clicking a
        // secondary display switches NSScreen.main to that display, causing characters on
        // the dock screen to be incorrectly hidden.
        if let dockScreen = NSScreen.screens.first(where: { screenHasDock($0) }) {
            return dockScreen
        }
        // Dock is auto-hidden: fall back to the primary display, identified as the screen
        // whose menu bar reserves space at the top (visibleFrame.maxY < frame.maxY).
        if let primaryScreen = NSScreen.screens.first(where: { $0.visibleFrame.maxY < $0.frame.maxY }) {
            return primaryScreen
        }
        return NSScreen.screens.first
    }

    private func screenHasDock(_ screen: NSScreen) -> Bool {
        DockVisibility.screenHasVisibleDockReservedArea(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }

    private func shouldShowCharacters(on screen: NSScreen) -> Bool {
        // User explicitly pinned to this screen — always show
        if pinnedScreenIndex >= 0, pinnedScreenIndex < NSScreen.screens.count {
            return true
        }
        return DockVisibility.shouldShowCharacters(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            isMainScreen: screen == NSScreen.main,
            dockAutohideEnabled: dockAutohideEnabled()
        )
    }

    @discardableResult
    private func updateEnvironmentVisibility(for screen: NSScreen) -> Bool {
        let shouldShow = shouldShowCharacters(on: screen)
        guard shouldShow != !isHiddenForEnvironment else { return shouldShow }

        isHiddenForEnvironment = !shouldShow

        if shouldShow {
            characters.forEach { $0.showForEnvironmentIfNeeded() }
        } else {
            debugWindow?.orderOut(nil)
            characters.forEach { $0.hideForEnvironment() }
        }

        return shouldShow
    }

    func tick() {
        guard let screen = activeScreen else { return }
        guard updateEnvironmentVisibility(for: screen) else { return }

        let screenWidth = screen.frame.width
        let dockX: CGFloat
        let dockWidth: CGFloat
        let dockTopY: CGFloat

        // Dock is on this screen — constrain to dock area
        (dockX, dockWidth) = getDockIconArea(screenWidth: screenWidth)
        dockTopY = screen.visibleFrame.origin.y

        updateDebugLine(dockX: dockX, dockWidth: dockWidth, dockTopY: dockTopY)

        let activeChars = characters.filter { $0.window.isVisible && $0.isManuallyVisible }

        let now = CACurrentMediaTime()
        let anyWalking = activeChars.contains { $0.isWalking }
        for char in activeChars {
            if char.isIdleForPopover { continue }
            if char.isPaused && now >= char.pauseEndTime && anyWalking {
                char.pauseEndTime = now + Double.random(in: 28.0...55.0)
            }
        }
        for char in activeChars {
            char.update(dockX: dockX, dockWidth: dockWidth, dockTopY: dockTopY)
        }

        for char in activeChars {
            char.syncMousePassthroughWithWindow()
        }

        for char in activeChars {
            char.updateThinkingBubble()
        }

        let sorted = activeChars.sorted { $0.positionProgress < $1.positionProgress }
        let base = NSWindow.Level.statusBar.rawValue
        for (i, char) in sorted.enumerated() {
            char.window.level = NSWindow.Level(rawValue: base + i + char.windowLevelBoost)
        }
        for char in activeChars where char.isIdleForPopover {
            char.ensurePopoverAboveCharacterWindow()
        }
    }

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }
}
