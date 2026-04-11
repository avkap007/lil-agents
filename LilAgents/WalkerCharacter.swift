import AVFoundation
import AppKit
import QuartzCore

enum CharacterSize: String, CaseIterable {
    case large, medium, small
    var height: CGFloat {
        switch self {
        case .large: return 200
        case .medium: return 150
        case .small: return 100
        }
    }
    var displayName: String {
        switch self {
        case .large: return "Large"
        case .medium: return "Medium"
        case .small: return "Small"
        }
    }
}

class WalkerCharacter {
    /// Which chat UI initiated chrome actions (copy / refresh) when dock + detached can both exist.
    private enum ChatChromeHost {
        case dockPopover
        case detachedWindow(NSWindow)
    }

    private final class DetachedChatPanel {
        let window: NSWindow
        let terminal: TerminalView
        var session: any AgentSession
        var providerOverride: AgentProvider?
        var closeObserver: NSObjectProtocol?
        var becameKeyObserver: NSObjectProtocol?

        init(
            window: NSWindow,
            terminal: TerminalView,
            session: any AgentSession,
            providerOverride: AgentProvider?
        ) {
            self.window = window
            self.terminal = terminal
            self.session = session
            self.providerOverride = providerOverride
        }
    }

    let videoName: String
    let name: String
    var provider: AgentProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: "\(name)Provider") ?? "claude"
            return AgentProvider(rawValue: raw) ?? .claude
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "\(name)Provider")
        }
    }
    var size: CharacterSize {
        get {
            let raw = UserDefaults.standard.string(forKey: "\(name)Size") ?? "big"
            return CharacterSize(rawValue: raw) ?? .large
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "\(name)Size")
            updateDimensions()
        }
    }
    var window: NSWindow!
    var playerLayer: AVPlayerLayer!
    var queuePlayer: AVQueuePlayer!
    var looper: AVPlayerLooper!

    let videoWidth: CGFloat = 1080
    let videoHeight: CGFloat = 1920
    private(set) var displayHeight: CGFloat = 200
    var displayWidth: CGFloat { displayHeight * (videoWidth / videoHeight) }

    /// Scales the dock window vs the menu “character size” (Bruce ≈ 1.0; Red needs >1 to match on-screen scale).
    var displayScale: CGFloat = 1.0 {
        didSet {
            displayHeight = size.height * displayScale
            if window != nil {
                updateDimensions()
            }
        }
    }

    /// Added to `statusBar + index` so a character can stay visually above another when they overlap.
    var windowLevelBoost: Int = 0

    /// When set, horizontal sliding only runs while looped video time is inside this range; before/after, X stays fixed (idle / wave / idle tail in combined clips).
    var horizontalMoveVideoRange: ClosedRange<CFTimeInterval>? = nil
    /// When set, `startWalk()` plays this walk-only clip instead of `videoName` (combined). Requires alpha-tuned timing in `walkHorizontalMoveVideoRange`.
    var walkLoopVideoName: String? = nil
    /// X-travel window for the dedicated walk clip (seconds into that MOV). If nil, a linear window over most of `activeLoopDuration` is used.
    var walkHorizontalMoveVideoRange: ClosedRange<CFTimeInterval>? = nil
    /// When set, this clip loops while paused (standing); combined `videoName` is unused for walks if `walkLoopVideoName` is set.
    var idleLoopVideoName: String? = nil
    /// Looped idle plays slower for calmer standing motion (`AVPlayer.rate`).
    var idlePlaybackRate: Float = 0.68
    /// While on the dock (not in the popover), freeze the idle loop briefly now and then — reads as “standing still” beats. Set upper bound below `0.15` to disable.
    var idleStillHoldSecondsRange: ClosedRange<Double> = 1.2...2.6
    /// After loading the idle loop or finishing a hold, wait at least this long before another hold may start.
    var idleMotionMinBeforeHoldSeconds: CFTimeInterval = 3.8
    /// Walk clip: small slowdown; spacing is mostly from longer pauses, not extreme rate.
    var walkPlaybackRate: Float = 0.88
    /// Wave clip: played once when opening the dock popover and occasionally as an ambient one-shot at the dock.
    var popoverWaveLoopVideoName: String? = nil
    /// Playback rate for the popover wave loop.
    var popoverWavePlaybackRate: Float = 0.9
    /// Roughly every this many seconds, play the popover wave clip once while at the dock (not while typing).
    var ambientWaveIntervalSeconds: CFTimeInterval = 15 * 60
    /// Extra random delay (seconds) added to each ambient wave schedule.
    var ambientWaveJitterRange: ClosedRange<Double> = -30...120
    /// After closing the popover, don’t schedule an ambient wave for at least this many seconds (avoids wave right after typing).
    var ambientWaveCooldownAfterPopoverSeconds: CFTimeInterval = 6 * 60
    /// Muse: probability [0,1] to play `completionOneShotVideoName` when a turn completes. Merit: keep at 0.
    var completionOneShotProbability: Float = 1.0
    /// Optional one-shot completion animation (played when an agent turn completes).
    var completionOneShotVideoName: String? = nil
    private var oneShotEndObserver: NSObjectProtocol?
    private var popoverIntroWaveObserver: NSObjectProtocol?
    private var wasPlayingBeforeOneShot = false
    private var isPlayingOneShot = false
    /// When true, `walkProgress` uses `walkHorizontalMoveVideoRange` (dedicated walk MOV).
    private var useWalkClipMoveRange = false
    /// Next time an ambient “desk” wave may fire (wall clock).
    private var nextAmbientWaveTime: CFTimeInterval = 0
    /// Dock-only: frozen idle pose during micro-hold.
    private var idleMicroHoldActive = false
    private var idleMicroHoldEndsAt: CFTimeInterval = 0
    private var idleMicroHoldNextEval: CFTimeInterval = 0

    // Walk timing (per-character, from frame analysis; combined clip is ~10s)
    /// Duration of the clip currently loaded into the looper (combined ~10s, idle loop ~2.08s).
    private(set) var activeLoopDuration: CFTimeInterval = 10.0
    var accelStart: CFTimeInterval = 3.0
    var fullSpeedStart: CFTimeInterval = 3.75
    var decelStart: CFTimeInterval = 7.5
    var walkStop: CFTimeInterval = 8.25
    var walkAmountRange: ClosedRange<CGFloat> = 0.25...0.5
    var yOffset: CGFloat = 0
    var flipXOffset: CGFloat = 0
    var characterColor: NSColor = .gray

    // Walk state
    var playCount = 0
    var walkStartTime: CFTimeInterval = 0
    var positionProgress: CGFloat = 0.0
    var isWalking = false
    var isPaused = true
    var pauseEndTime: CFTimeInterval = 0
    var goingRight = true
    var walkStartPos: CGFloat = 0.0
    var walkEndPos: CGFloat = 0.0
    var currentTravelDistance: CGFloat = 500.0
    // Walk endpoints stored in pixels for consistent speed across screen switches
    var walkStartPixel: CGFloat = 0.0
    var walkEndPixel: CGFloat = 0.0

    // Onboarding
    var isOnboarding = false

    // Popover state
    var isIdleForPopover = false
    var popoverWindow: NSWindow?
    var terminalView: TerminalView?
    private var detachedPanels: [DetachedChatPanel] = []
    var session: (any AgentSession)?
    var clickOutsideMonitor: Any?
    var escapeKeyMonitor: Any?
    var currentStreamingText = ""
    weak var controller: LilAgentsController?
    var themeOverride: PopoverTheme?
    var isAgentBusy: Bool {
        if session?.isBusy == true { return true }
        return detachedPanels.contains { $0.session.isBusy }
    }

    var hasDetachedChats: Bool { !detachedPanels.isEmpty }
    var thinkingBubbleWindow: NSWindow?
    private(set) var isManuallyVisible = true
    private var environmentHiddenAt: CFTimeInterval?
    private var wasPopoverVisibleBeforeEnvironmentHide = false
    private var wasDetachedVisibleBeforeEnvironmentHide = false
    private var wasBubbleVisibleBeforeEnvironmentHide = false
    private var popoverBecameKeyObserver: NSObjectProtocol?
    /// Which window’s title bar opened the provider menu (dock popover vs detached).
    private weak var providerMenuHostWindow: NSWindow?

    private static let detachedTitleLeadingInset: CGFloat = 90
    private static let detachedProviderArrowButtonTag = 901
    private static let detachedProviderClickAreaTag = 902

    init(videoName: String, name: String) {
        self.videoName = videoName
        self.name = name
        self.displayHeight = size.height * displayScale
    }

    // MARK: - Setup

    func updateDimensions() {
        displayHeight = size.height * displayScale
        let newWidth = displayWidth
        let newHeight = displayHeight
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window else { return }
            let oldFrame = window.frame
            let newFrame = CGRect(x: oldFrame.origin.x, y: oldFrame.origin.y, width: newWidth, height: newHeight)
            
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.setFrame(newFrame, display: true)
            self.playerLayer.frame = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
            if let hostView = window.contentView {
                hostView.frame = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
            }
            CATransaction.commit()
            
            self.updateFlip()
        }
    }

    func setup() {
        queuePlayer = AVQueuePlayer()
        queuePlayer.automaticallyWaitsToMinimizeStalling = false

        playerLayer = AVPlayerLayer(player: queuePlayer)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.isOpaque = false
        playerLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)

        let screen = NSScreen.main!
        let dockTopY = screen.visibleFrame.origin.y
        let bottomPadding = displayHeight * 0.15
        let y = dockTopY - bottomPadding + yOffset

        let contentRect = CGRect(x: 0, y: y, width: displayWidth, height: displayHeight)
        window = NonKeyableWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.moveToActiveSpace, .stationary]

        let hostView = CharacterContentView(frame: CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight))
        hostView.character = self
        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        hostView.layer?.isOpaque = false
        hostView.layer?.addSublayer(playerLayer)

        window.contentView = hostView
        window.orderFrontRegardless()

        let initialClip = idleLoopVideoName ?? videoName
        playLoop(videoName: initialClip)
        if idleLoopVideoName != nil {
            queuePlayer.play()
        } else {
            queuePlayer.pause()
            queuePlayer.seek(to: .zero)
        }
        refreshPlaybackRateAfterClipChange()
        scheduleNextAmbientWave()
        resetIdleMicroHoldScheduleAfterMotionPhase()
    }

    deinit {
        if let observer = oneShotEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = popoverIntroWaveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        for panel in detachedPanels {
            if let o = panel.closeObserver { NotificationCenter.default.removeObserver(o) }
            if let o = panel.becameKeyObserver { NotificationCenter.default.removeObserver(o) }
        }
        detachedPanels.removeAll()
        removePopoverBecameKeyObserver()
    }

    private func playLoop(videoName: String) {
        guard let url = Bundle.main.url(forResource: videoName, withExtension: "mov") else {
            print("Video \(videoName) not found")
            return
        }

        if let observer = oneShotEndObserver {
            NotificationCenter.default.removeObserver(observer)
            oneShotEndObserver = nil
        }
        if let observer = popoverIntroWaveObserver {
            NotificationCenter.default.removeObserver(observer)
            popoverIntroWaveObserver = nil
        }

        queuePlayer.removeAllItems()
        let asset = AVAsset(url: url)
        let dur = CMTimeGetSeconds(asset.duration)
        activeLoopDuration = dur.isFinite && dur > 0 ? dur : 10.0
        let item = AVPlayerItem(asset: asset)
        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        isPlayingOneShot = false
    }

    private func refreshPlaybackRateAfterClipChange() {
        guard !isPlayingOneShot else { return }
        if isWalking {
            queuePlayer.rate = walkPlaybackRate
        } else if idleLoopVideoName != nil {
            queuePlayer.rate = idlePlaybackRate
        } else {
            queuePlayer.rate = 1.0
        }
    }

    private func scheduleNextAmbientWave() {
        let jitter = Double.random(in: ambientWaveJitterRange)
        nextAmbientWaveTime = CACurrentMediaTime() + ambientWaveIntervalSeconds + jitter
    }

    private func resetIdleMicroHoldScheduleAfterMotionPhase() {
        idleMicroHoldActive = false
        let now = CACurrentMediaTime()
        idleMicroHoldNextEval = now + idleMotionMinBeforeHoldSeconds + Double.random(in: 0...2.5)
    }

    private func cancelIdleMicroHoldResumingPlayback() {
        guard idleMicroHoldActive else { return }
        idleMicroHoldActive = false
        guard idleLoopVideoName != nil, !isWalking, isPaused, !isPlayingOneShot else { return }
        queuePlayer.play()
        queuePlayer.rate = idlePlaybackRate
    }

    /// Dock idle only: mix short frozen poses into the looping idle clip.
    private func tickIdleMicroHold(now: CFTimeInterval) {
        guard idleLoopVideoName != nil,
              isPaused,
              !isWalking,
              !isIdleForPopover,
              !isPlayingOneShot,
              isManuallyVisible,
              environmentHiddenAt == nil
        else {
            if idleMicroHoldActive { cancelIdleMicroHoldResumingPlayback() }
            return
        }
        guard idleStillHoldSecondsRange.upperBound >= 0.15 else { return }

        if idleMicroHoldActive {
            if now >= idleMicroHoldEndsAt {
                idleMicroHoldActive = false
                queuePlayer.play()
                queuePlayer.rate = idlePlaybackRate
                idleMicroHoldNextEval = now + idleMotionMinBeforeHoldSeconds + Double.random(in: 0...2.5)
            }
            return
        }

        guard now >= idleMicroHoldNextEval else { return }

        let lo = idleStillHoldSecondsRange.lowerBound
        let hi = idleStillHoldSecondsRange.upperBound
        let holdDur = lo + Double.random(in: 0...max(hi - lo, 0))
        guard holdDur >= 0.12 else {
            idleMicroHoldNextEval = now + 1.5
            return
        }
        idleMicroHoldActive = true
        idleMicroHoldEndsAt = now + holdDur
        queuePlayer.pause()
    }

    private func fallbackWalkLinearRange() -> ClosedRange<CFTimeInterval> {
        let d = activeLoopDuration
        let hi = max(d - 0.12, 0.2)
        return 0.08...hi
    }

    /// Standing / popover / pause: idle-only loop when configured; otherwise frozen first frame of combined clip.
    private func switchToIdleStandingAnimation() {
        if let idle = idleLoopVideoName {
            playLoop(videoName: idle)
            queuePlayer.play()
            refreshPlaybackRateAfterClipChange()
        } else {
            queuePlayer.pause()
            queuePlayer.seek(to: .zero)
        }
    }

    /// Single wave when opening the dock popover, then return to standing idle while you chat.
    private func playPopoverIntroWaveOneShotThenIdle() {
        guard let clip = popoverWaveLoopVideoName, !clip.isEmpty else {
            switchToIdleStandingAnimation()
            return
        }
        guard let url = Bundle.main.url(forResource: clip, withExtension: "mov") else {
            switchToIdleStandingAnimation()
            return
        }

        if let observer = popoverIntroWaveObserver {
            NotificationCenter.default.removeObserver(observer)
            popoverIntroWaveObserver = nil
        }

        looper?.disableLooping()
        looper = nil
        queuePlayer.removeAllItems()

        let item = AVPlayerItem(url: url)
        popoverIntroWaveObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if let obs = self.popoverIntroWaveObserver {
                NotificationCenter.default.removeObserver(obs)
                self.popoverIntroWaveObserver = nil
            }
            self.isPlayingOneShot = false
            self.switchToIdleStandingAnimation()
            self.queuePlayer.play()
        }

        isPlayingOneShot = true
        queuePlayer.insert(item, after: nil)
        queuePlayer.seek(to: .zero)
        queuePlayer.rate = popoverWavePlaybackRate
        queuePlayer.play()
    }

    private func restoreLooperAfterOneShot() {
        if let idle = idleLoopVideoName, !isWalking {
            playLoop(videoName: idle)
            queuePlayer.play()
            refreshPlaybackRateAfterClipChange()
            resetIdleMicroHoldScheduleAfterMotionPhase()
            return
        }
        let clip = walkLoopVideoName ?? videoName
        useWalkClipMoveRange = walkLoopVideoName != nil && isWalking
        playLoop(videoName: clip)
        if wasPlayingBeforeOneShot && isWalking && !isPaused {
            queuePlayer.play()
            refreshPlaybackRateAfterClipChange()
        } else {
            queuePlayer.pause()
            queuePlayer.seek(to: .zero)
            refreshPlaybackRateAfterClipChange()
        }
    }

    private func playCompletionOneShotIfConfigured() {
        guard let clip = completionOneShotVideoName, !clip.isEmpty else { return }
        guard Float.random(in: 0...1) < completionOneShotProbability else { return }
        guard !isPlayingOneShot else { return }
        guard let url = Bundle.main.url(forResource: clip, withExtension: "mov") else {
            print("Video \(clip) not found")
            return
        }

        wasPlayingBeforeOneShot = queuePlayer.rate > 0
        looper?.disableLooping()
        looper = nil
        queuePlayer.removeAllItems()

        let oneShot = AVPlayerItem(url: url)
        oneShotEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: oneShot,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.restoreLooperAfterOneShot()
        }

        isPlayingOneShot = true
        queuePlayer.insert(oneShot, after: nil)
        queuePlayer.seek(to: .zero)
        queuePlayer.rate = 1.0
        queuePlayer.play()
    }

    /// Occasional wave at the dock (not while the terminal is open).
    private func playAmbientWaveOneShotIfDue(now: CFTimeInterval) {
        guard let clip = popoverWaveLoopVideoName, !clip.isEmpty else { return }
        guard now >= nextAmbientWaveTime else { return }
        guard !isPlayingOneShot, !isWalking, !isIdleForPopover else { return }
        cancelIdleMicroHoldResumingPlayback()
        guard let url = Bundle.main.url(forResource: clip, withExtension: "mov") else { return }

        wasPlayingBeforeOneShot = queuePlayer.rate > 0
        looper?.disableLooping()
        looper = nil
        queuePlayer.removeAllItems()

        let item = AVPlayerItem(url: url)
        if let observer = oneShotEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        oneShotEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isPlayingOneShot = false
            self.restoreLooperAfterOneShot()
            self.scheduleNextAmbientWave()
        }

        isPlayingOneShot = true
        queuePlayer.insert(item, after: nil)
        queuePlayer.seek(to: .zero)
        queuePlayer.rate = 1.0
        queuePlayer.play()
    }

    // MARK: - Visibility

    func setManuallyVisible(_ visible: Bool) {
        isManuallyVisible = visible
        if visible {
            if environmentHiddenAt == nil {
                window.orderFrontRegardless()
            }
            if isWalking {
                queuePlayer.play()
                queuePlayer.rate = walkPlaybackRate
            } else if isIdleForPopover {
                if isPlayingOneShot {
                    queuePlayer.play()
                    queuePlayer.rate = popoverWavePlaybackRate
                } else {
                    switchToIdleStandingAnimation()
                }
            } else if idleLoopVideoName != nil, isPaused {
                queuePlayer.play()
                queuePlayer.rate = idlePlaybackRate
            }
        } else {
            queuePlayer.pause()
            window.orderOut(nil)
            popoverWindow?.orderOut(nil)
            for panel in detachedPanels {
                panel.window.orderOut(nil)
            }
            thinkingBubbleWindow?.orderOut(nil)
        }
    }

    func hideForEnvironment() {
        guard environmentHiddenAt == nil else { return }

        environmentHiddenAt = CACurrentMediaTime()
        wasPopoverVisibleBeforeEnvironmentHide = popoverWindow?.isVisible ?? false
        wasDetachedVisibleBeforeEnvironmentHide = detachedPanels.contains { $0.window.isVisible }
        wasBubbleVisibleBeforeEnvironmentHide = thinkingBubbleWindow?.isVisible ?? false

        queuePlayer.pause()
        window.orderOut(nil)
        popoverWindow?.orderOut(nil)
        for panel in detachedPanels {
            panel.window.orderOut(nil)
        }
        thinkingBubbleWindow?.orderOut(nil)
    }

    func showForEnvironmentIfNeeded() {
        guard let hiddenAt = environmentHiddenAt else { return }

        let hiddenDuration = CACurrentMediaTime() - hiddenAt
        environmentHiddenAt = nil
        walkStartTime += hiddenDuration
        pauseEndTime += hiddenDuration
        completionBubbleExpiry += hiddenDuration
        lastPhraseUpdate += hiddenDuration
        nextAmbientWaveTime += hiddenDuration

        guard isManuallyVisible else { return }

        window.orderFrontRegardless()
        if isWalking {
            queuePlayer.play()
            queuePlayer.rate = walkPlaybackRate
        } else if isIdleForPopover {
            if isPlayingOneShot {
                queuePlayer.play()
                queuePlayer.rate = popoverWavePlaybackRate
            } else {
                switchToIdleStandingAnimation()
            }
        } else if idleLoopVideoName != nil {
            queuePlayer.play()
            queuePlayer.rate = idlePlaybackRate
        }

        if isIdleForPopover && wasPopoverVisibleBeforeEnvironmentHide {
            updatePopoverPosition()
            ensurePopoverAboveCharacterWindow()
            popoverWindow?.orderFrontRegardless()
            popoverWindow?.makeKey()
            if let terminal = terminalView {
                popoverWindow?.makeFirstResponder(terminal.inputField)
            }
        }

        if wasDetachedVisibleBeforeEnvironmentHide {
            for panel in detachedPanels {
                panel.window.orderFrontRegardless()
            }
            if let front = detachedPanels.last {
                front.window.makeKey()
                front.window.makeFirstResponder(front.terminal.inputField)
            }
        }

        if wasBubbleVisibleBeforeEnvironmentHide {
            updateThinkingBubble()
        }
    }

    // MARK: - Click Handling & Popover

    func handleClick() {
        if isOnboarding {
            openOnboardingPopover()
            return
        }
        if isIdleForPopover {
            closePopover()
        } else {
            openPopover()
        }
    }

    private func openOnboardingPopover() {
        showingCompletion = false
        hideBubble()

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        playPopoverIntroWaveOneShotThenIdle()

        if popoverWindow == nil {
            createPopoverWindow()
        }

        // Show static welcome message instead of Claude terminal
        terminalView?.inputField.isEditable = false
        terminalView?.inputField.placeholderString = ""
        let welcome = """
        hey! we're merit and muse — your lil dock agents.

        click either of us to open a Claude AI chat. we'll walk around while you work and let you know when Claude's thinking.

        check the menu bar icon (top right) for themes, sounds, and more options.

        click anywhere outside to dismiss, then click us again to start chatting.
        """
        terminalView?.appendStreamingText(welcome)
        terminalView?.endStreaming()

        updatePopoverPosition()
        ensurePopoverAboveCharacterWindow()
        popoverWindow?.orderFrontRegardless()

        // Set up click-outside to dismiss and complete onboarding
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.closeOnboarding()
        }
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.closeOnboarding(); return nil }
            return event
        }
    }

    private func closeOnboarding() {
        if let monitor = clickOutsideMonitor { NSEvent.removeMonitor(monitor); clickOutsideMonitor = nil }
        if let monitor = escapeKeyMonitor { NSEvent.removeMonitor(monitor); escapeKeyMonitor = nil }
        removePopoverBecameKeyObserver()
        popoverWindow?.orderOut(nil)
        popoverWindow = nil
        terminalView = nil
        isIdleForPopover = false
        isOnboarding = false
        isPaused = true
        pauseEndTime = CACurrentMediaTime() + Double.random(in: 25.0...50.0)
        switchToIdleStandingAnimation()
        let push = CACurrentMediaTime() + ambientWaveCooldownAfterPopoverSeconds
        nextAmbientWaveTime = max(nextAmbientWaveTime, push)
        controller?.completeOnboarding()
    }

    func openPopover() {
        idleMicroHoldActive = false
        idleMicroHoldNextEval = 0
        // Close any other open popover
        if let siblings = controller?.characters {
            for sibling in siblings where sibling !== self && sibling.isIdleForPopover {
                sibling.closePopover()
            }
        }

        isIdleForPopover = true
        isWalking = false
        isPaused = true
        playPopoverIntroWaveOneShotThenIdle()

        // Always clear any bubble (thinking or completion) when popover opens
        showingCompletion = false
        hideBubble()

        if popoverWindow == nil {
            createPopoverWindow()
        }

        if session == nil {
            let newSession = provider.createSession()
            session = newSession
            if let term = terminalView {
                wireSession(newSession, terminal: term)
            }
            newSession.start()
        } else if let s = session, let term = terminalView {
            wireSession(s, terminal: term)
        }

        if let terminal = terminalView, let session = session, !session.history.isEmpty {
            terminal.replayHistory(session.history)
        }

        updatePopoverPosition()
        ensurePopoverAboveCharacterWindow()
        popoverWindow?.orderFrontRegardless()
        popoverWindow?.makeKey()

        if let terminal = terminalView {
            popoverWindow?.makeFirstResponder(terminal.inputField)
        }

        // Remove old monitors before adding new ones
        removeEventMonitors()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let popover = self.popoverWindow else { return }
            let popoverFrame = popover.frame
            let charFrame = self.window.frame
            if !popoverFrame.contains(NSEvent.mouseLocation) && !charFrame.contains(NSEvent.mouseLocation) {
                self.closePopover()
            }
        }

        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.closePopover()
                return nil
            }
            return event
        }
    }

    func closePopover() {
        guard isIdleForPopover else { return }

        popoverWindow?.orderOut(nil)
        removeEventMonitors()

        isIdleForPopover = false

        // If still waiting for a response, show thinking bubble immediately
        // If completion came while popover was open, show completion bubble
        if showingCompletion {
            // Reset expiry so user gets the full 3s from now
            completionBubbleExpiry = CACurrentMediaTime() + 3.0
            showBubble(text: currentPhrase, isCompletion: true)
        } else if isAgentBusy {
            // Force a fresh phrase pick and show immediately
            currentPhrase = ""
            lastPhraseUpdate = 0
            updateThinkingPhrase()
            showBubble(text: currentPhrase, isCompletion: false)
        }

        let delay = Double.random(in: 30.0...60.0)
        pauseEndTime = CACurrentMediaTime() + delay
        switchToIdleStandingAnimation()
        let push = CACurrentMediaTime() + ambientWaveCooldownAfterPopoverSeconds
        nextAmbientWaveTime = max(nextAmbientWaveTime, push)
        resetIdleMicroHoldScheduleAfterMotionPhase()
    }

    private func removeEventMonitors() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }

    var resolvedTheme: PopoverTheme {
        (themeOverride ?? PopoverTheme.current).withCharacterColor(characterColor).withCustomFont()
    }

    func createPopoverWindow() {
        removePopoverBecameKeyObserver()
        let t = resolvedTheme
        let popoverWidth: CGFloat = 420
        let popoverHeight: CGFloat = 310

        let win = KeyableWindow(
            contentRect: CGRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        // Level is synced to sit just above this character's window (see `ensurePopoverAboveCharacterWindow`).
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 10)
        win.collectionBehavior = [.moveToActiveSpace, .stationary]
        let brightness = t.popoverBg.redComponent * 0.299 + t.popoverBg.greenComponent * 0.587 + t.popoverBg.blueComponent * 0.114
        win.appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.popoverBg.cgColor
        container.layer?.cornerRadius = t.popoverCornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = t.popoverBorderWidth
        container.layer?.borderColor = t.popoverBorder.cgColor
        container.autoresizingMask = [.width, .height]

        let titleBar = NSView(frame: NSRect(x: 0, y: popoverHeight - 28, width: popoverWidth, height: 28))
        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = t.titleBarBg.cgColor
        container.addSubview(titleBar)

        let titleLabel = NSTextField(labelWithString: t.titleString(for: provider))
        titleLabel.font = t.titleFont
        titleLabel.textColor = t.titleText
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: 12, y: 6)
        titleBar.addSubview(titleLabel)

        let arrowBtn = NSButton(frame: NSRect(x: titleLabel.frame.maxX + 2, y: 5, width: 16, height: 16))
        arrowBtn.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Switch provider")
        arrowBtn.imageScaling = .scaleProportionallyDown
        arrowBtn.bezelStyle = .inline
        arrowBtn.isBordered = false
        arrowBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        arrowBtn.target = self
        arrowBtn.action = #selector(showProviderMenu(_:))
        titleBar.addSubview(arrowBtn)

        // Make the title label clickable too
        let clickArea = NSButton(frame: NSRect(x: 0, y: 0, width: arrowBtn.frame.maxX + 4, height: 28))
        clickArea.isTransparent = true
        clickArea.target = self
        clickArea.action = #selector(showProviderMenu(_:))
        titleBar.addSubview(clickArea)

        let popOutBtn = NSButton(frame: NSRect(x: popoverWidth - 68, y: 5, width: 16, height: 16))
        popOutBtn.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Pop out chat")
        popOutBtn.imageScaling = .scaleProportionallyDown
        popOutBtn.bezelStyle = .inline
        popOutBtn.isBordered = false
        popOutBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        popOutBtn.target = self
        popOutBtn.action = #selector(popOutChatToDetachedWindow(_:))
        titleBar.addSubview(popOutBtn)

        let refreshBtn = NSButton(frame: NSRect(x: popoverWidth - 48, y: 5, width: 16, height: 16))
        refreshBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshBtn.imageScaling = .scaleProportionallyDown
        refreshBtn.bezelStyle = .inline
        refreshBtn.isBordered = false
        refreshBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshSessionFromButton(_:))
        titleBar.addSubview(refreshBtn)

        let copyBtn = NSButton(frame: NSRect(x: popoverWidth - 28, y: 5, width: 16, height: 16))
        copyBtn.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
        copyBtn.imageScaling = .scaleProportionallyDown
        copyBtn.bezelStyle = .inline
        copyBtn.isBordered = false
        copyBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        copyBtn.target = self
        copyBtn.action = #selector(copyLastResponseFromButton(_:))
        titleBar.addSubview(copyBtn)

        let sep = NSView(frame: NSRect(x: 0, y: popoverHeight - 29, width: popoverWidth, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = t.separatorColor.cgColor
        container.addSubview(sep)

        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight - 29))
        terminal.characterColor = characterColor
        terminal.themeOverride = themeOverride
        terminal.provider = provider
        terminal.autoresizingMask = [.width, .height]
        terminal.onSendMessage = { [weak self] message in
            self?.session?.send(message: message)
        }
        terminal.onClearRequested = { [weak self] in
            self?.resetSession(for: .dockPopover)
        }
        container.addSubview(terminal)

        win.contentView = container
        popoverWindow = win
        terminalView = terminal

        popoverBecameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.popoverWindow === win else { return }
            self.ensurePopoverAboveCharacterWindow()
            win.orderFrontRegardless()
        }
    }

    private func removePopoverBecameKeyObserver() {
        if let o = popoverBecameKeyObserver {
            NotificationCenter.default.removeObserver(o)
            popoverBecameKeyObserver = nil
        }
    }

    /// Keeps the dock popover above this character's window.
    func ensurePopoverAboveCharacterWindow() {
        guard let popover = popoverWindow, popover.isVisible else { return }
        // Use a fixed level high enough to be above all character windows,
        // same as detached window so they can naturally order via clicks
        let target = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 15)
        if popover.level != target {
            popover.level = target
        }
    }

    /// After `terminalView` is replaced (e.g. style switch), rebind session callbacks to the new view.
    func rewirePopoverSessionIfNeeded() {
        guard let s = session, let term = terminalView else { return }
        wireSession(s, terminal: term)
    }

    private func detachedPanel(for window: NSWindow) -> DetachedChatPanel? {
        detachedPanels.first { $0.window === window }
    }

    private func bindDetachedPanelCallbacks(_ panel: DetachedChatPanel) {
        let win = panel.window
        let term = panel.terminal
        wireSession(panel.session, terminal: term)
        term.onSendMessage = { [weak self] message in
            guard let self, let p = self.detachedPanel(for: win) else { return }
            p.session.send(message: message)
        }
        term.onClearRequested = { [weak self] in
            self?.resetSession(for: .detachedWindow(win))
        }
    }

    private func handleDetachedWindowDidClose(_ panel: DetachedChatPanel) {
        if let o = panel.closeObserver {
            NotificationCenter.default.removeObserver(o)
            panel.closeObserver = nil
        }
        if let o = panel.becameKeyObserver {
            NotificationCenter.default.removeObserver(o)
            panel.becameKeyObserver = nil
        }
        let sess = panel.session
        detachedPanels.removeAll { $0 === panel }
        DispatchQueue.main.async {
            sess.terminate()
        }
    }

    func terminateAllDetachedSessions() {
        for panel in detachedPanels {
            panel.session.terminate()
        }
    }

    func reapplyAppearanceToAllDetachedTerminals() {
        for panel in detachedPanels {
            panel.terminal.reapplyAppearanceFromTheme()
        }
    }

    /// Close popped-out chat without going through `didClose` teardown (e.g. global provider switch).
    func discardDetachedChatSilently() {
        let panels = detachedPanels
        detachedPanels.removeAll()
        for panel in panels {
            if let o = panel.closeObserver {
                NotificationCenter.default.removeObserver(o)
                panel.closeObserver = nil
            }
            if let o = panel.becameKeyObserver {
                NotificationCenter.default.removeObserver(o)
                panel.becameKeyObserver = nil
            }
            let sess = panel.session
            panel.window.close()
            DispatchQueue.main.async {
                sess.terminate()
            }
        }
    }

    private func resetSession(for host: ChatChromeHost) {
        switch host {
        case .detachedWindow(let win):
            guard let panel = detachedPanel(for: win) else { return }
            panel.session.terminate()
            currentStreamingText = ""
            showingCompletion = false
            currentPhrase = ""
            completionBubbleExpiry = 0
            hideBubble()
            let term = panel.terminal
            term.resetState()
            term.showSessionMessage()
            let p = panel.providerOverride ?? provider
            let newSession = p.createSession()
            panel.session = newSession
            term.provider = p
            wireSession(newSession, terminal: term)
            term.onSendMessage = { [weak self] message in
                guard let self, let p = self.detachedPanel(for: win) else { return }
                p.session.send(message: message)
            }
            term.onClearRequested = { [weak self] in
                self?.resetSession(for: .detachedWindow(win))
            }
            newSession.start()

        case .dockPopover:
            session?.terminate()
            session = nil
            currentStreamingText = ""
            showingCompletion = false
            currentPhrase = ""
            completionBubbleExpiry = 0
            hideBubble()
            terminalView?.resetState()
            terminalView?.showSessionMessage()
            let newSession = provider.createSession()
            session = newSession
            if let term = terminalView {
                wireSession(newSession, terminal: term)
            }
            newSession.start()
        }
    }

    private func wireSession(_ session: any AgentSession, terminal: TerminalView) {
        session.onText = { [weak self, weak terminal] text in
            self?.currentStreamingText += text
            terminal?.appendStreamingText(text)
        }

        session.onTurnComplete = { [weak self, weak terminal] in
            terminal?.endStreaming()
            self?.playCompletionSound()
            self?.showCompletionBubble()
            self?.playCompletionOneShotIfConfigured()
        }

        session.onError = { [weak terminal] text in
            terminal?.appendError(text)
        }

        session.onToolUse = { [weak self, weak terminal] toolName, input in
            guard let self = self else { return }
            let summary = self.formatToolInput(input)
            terminal?.appendToolUse(toolName: toolName, summary: summary)
        }

        session.onToolResult = { [weak terminal] summary, isError in
            terminal?.appendToolResult(summary: summary, isError: isError)
        }

        session.onProcessExit = { [weak self, weak terminal] in
            guard let self = self else { return }
            terminal?.endStreaming()
            let pname: String
            if let term = terminal,
               let panel = self.detachedPanels.first(where: { $0.terminal === term }) {
                pname = (panel.providerOverride ?? self.provider).displayName
            } else {
                pname = self.provider.displayName
            }
            terminal?.appendError("\(pname) session ended.")
        }

        session.onSessionReady = { }
    }

    @objc func popOutChatToDetachedWindow(_ sender: Any?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.popOutChatToDetachedWindow(sender)
            }
            return
        }
        guard let pw = popoverWindow,
              let senderView = sender as? NSView,
              senderView.window === pw else { return }
        guard !isOnboarding else { return }
        guard let sess = session, let term = terminalView else { return }

        removeEventMonitors()
        term.removeFromSuperview()
        popoverWindow?.orderOut(nil)
        removePopoverBecameKeyObserver()
        popoverWindow = nil

        session = nil
        terminalView = nil

        let panel = createDetachedChatWindow(session: sess, terminal: term, providerOverride: provider)
        bindDetachedPanelCallbacks(panel)

        isIdleForPopover = false

        if showingCompletion {
            completionBubbleExpiry = CACurrentMediaTime() + 3.0
            showBubble(text: currentPhrase, isCompletion: true)
        } else if isAgentBusy {
            currentPhrase = ""
            lastPhraseUpdate = 0
            updateThinkingPhrase()
            showBubble(text: currentPhrase, isCompletion: false)
        }

        let delay = Double.random(in: 30.0...60.0)
        pauseEndTime = CACurrentMediaTime() + delay
        switchToIdleStandingAnimation()
        resetIdleMicroHoldScheduleAfterMotionPhase()
        let push = CACurrentMediaTime() + ambientWaveCooldownAfterPopoverSeconds
        nextAmbientWaveTime = max(nextAmbientWaveTime, push)

        panel.window.center()
        panel.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.window.makeFirstResponder(panel.terminal.inputField)
    }

    private func createDetachedChatWindow(
        session sess: any AgentSession,
        terminal term: TerminalView,
        providerOverride: AgentProvider?
    ) -> DetachedChatPanel {
        let t = resolvedTheme
        let winW: CGFloat = 760
        let winH: CGFloat = 520

        let win = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 480, height: 320)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 15)
        win.collectionBehavior = [.moveToActiveSpace]
        let brightness = t.popoverBg.redComponent * 0.299 + t.popoverBg.greenComponent * 0.587 + t.popoverBg.blueComponent * 0.114
        win.appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)
        let detachedP = providerOverride ?? provider
        win.title = "\(name) — \(detachedP.displayName)"
        term.provider = detachedP

        let container = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.popoverBg.cgColor
        container.layer?.cornerRadius = t.popoverCornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = t.popoverBorderWidth
        container.layer?.borderColor = t.popoverBorder.cgColor
        container.autoresizingMask = [.width, .height]

        let titleBar = NSView(frame: NSRect(x: 0, y: winH - 28, width: winW, height: 28))
        titleBar.wantsLayer = true
        titleBar.layer?.backgroundColor = t.titleBarBg.cgColor
        titleBar.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(titleBar)

        let titleLabel = NSTextField(labelWithString: t.titleString(for: detachedP))
        titleLabel.font = t.titleFont
        titleLabel.textColor = t.titleText
        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: Self.detachedTitleLeadingInset, y: 6)
        titleBar.addSubview(titleLabel)

        let arrowBtn = NSButton(frame: NSRect(x: titleLabel.frame.maxX + 2, y: 5, width: 16, height: 16))
        arrowBtn.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Switch provider")
        arrowBtn.imageScaling = .scaleProportionallyDown
        arrowBtn.bezelStyle = .inline
        arrowBtn.isBordered = false
        arrowBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        arrowBtn.target = self
        arrowBtn.action = #selector(showProviderMenu(_:))
        arrowBtn.tag = Self.detachedProviderArrowButtonTag
        titleBar.addSubview(arrowBtn)

        let clickW = max(arrowBtn.frame.maxX - Self.detachedTitleLeadingInset + 8, 48)
        let clickArea = NSButton(frame: NSRect(x: Self.detachedTitleLeadingInset, y: 0, width: clickW, height: 28))
        clickArea.isTransparent = true
        clickArea.target = self
        clickArea.action = #selector(showProviderMenu(_:))
        clickArea.tag = Self.detachedProviderClickAreaTag
        titleBar.addSubview(clickArea)

        let refreshBtn = NSButton(frame: NSRect(x: winW - 48, y: 5, width: 16, height: 16))
        refreshBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshBtn.imageScaling = .scaleProportionallyDown
        refreshBtn.bezelStyle = .inline
        refreshBtn.isBordered = false
        refreshBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        refreshBtn.target = self
        refreshBtn.action = #selector(refreshSessionFromButton(_:))
        refreshBtn.autoresizingMask = .minXMargin
        titleBar.addSubview(refreshBtn)

        let copyBtn = NSButton(frame: NSRect(x: winW - 28, y: 5, width: 16, height: 16))
        copyBtn.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Copy")
        copyBtn.imageScaling = .scaleProportionallyDown
        copyBtn.bezelStyle = .inline
        copyBtn.isBordered = false
        copyBtn.contentTintColor = t.titleText.withAlphaComponent(0.75)
        copyBtn.autoresizingMask = .minXMargin
        copyBtn.target = self
        copyBtn.action = #selector(copyLastResponseFromButton(_:))
        titleBar.addSubview(copyBtn)

        let sep = NSView(frame: NSRect(x: 0, y: winH - 29, width: winW, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = t.separatorColor.cgColor
        sep.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(sep)

        term.frame = NSRect(x: 0, y: 0, width: winW, height: winH - 29)
        term.autoresizingMask = [.width, .height]
        container.addSubview(term)

        win.contentView = container

        let panel = DetachedChatPanel(
            window: win,
            terminal: term,
            session: sess,
            providerOverride: providerOverride
        )

        panel.closeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSWindowDidClose"),
            object: win,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let closed = note.object as? NSWindow,
                  let found = self.detachedPanels.first(where: { $0.window === closed }) else { return }
            self.handleDetachedWindowDidClose(found)
        }

        panel.becameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: win,
            queue: .main
        ) { [weak panel] _ in
            panel?.window.orderFrontRegardless()
        }

        detachedPanels.append(panel)
        return panel
    }

    func refreshDetachedChromeTheme() {
        let t = resolvedTheme
        let brightness = t.popoverBg.redComponent * 0.299 + t.popoverBg.greenComponent * 0.587 + t.popoverBg.blueComponent * 0.114
        let appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)
        for panel in detachedPanels {
            guard let container = panel.window.contentView else { continue }
            container.layer?.backgroundColor = t.popoverBg.cgColor
            container.layer?.borderColor = t.popoverBorder.cgColor
            for view in container.subviews {
                if abs(view.frame.height - 1) < 0.5 {
                    view.layer?.backgroundColor = t.separatorColor.cgColor
                }
            }
            if let titleBar = container.subviews.first(where: { abs($0.frame.height - 28) < 0.5 && abs($0.frame.maxY - container.bounds.height) < 2 }) {
                titleBar.layer?.backgroundColor = t.titleBarBg.cgColor
                for sub in titleBar.subviews {
                    if let tf = sub as? NSTextField {
                        tf.textColor = t.titleText
                        tf.font = t.titleFont
                    }
                    if let btn = sub as? NSButton, btn.image != nil {
                        btn.contentTintColor = t.titleText.withAlphaComponent(0.75)
                    }
                }
            }
            panel.window.appearance = appearance
            updateDetachedTitleBarProviderLabels(for: panel.window)
        }
    }

    @objc func showProviderMenu(_ sender: Any) {
        guard let view = sender as? NSView, let hostWindow = view.window else { return }
        guard let titleBar = view.superview, abs(titleBar.frame.height - 28) < 2 else { return }

        providerMenuHostWindow = hostWindow
        let menu = NSMenu()
        let menuFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let selected: AgentProvider
        if let panel = detachedPanel(for: hostWindow) {
            selected = panel.providerOverride ?? provider
        } else {
            selected = provider
        }
        for p in AgentProvider.allCases {
            let item = NSMenuItem(title: p.displayName, action: #selector(providerMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.attributedTitle = NSAttributedString(string: p.displayName, attributes: [.font: menuFont])
            item.representedObject = p.rawValue
            item.state = p == selected ? .on : .off
            if !p.isAvailable {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
        let menuX: CGFloat = detachedPanel(for: hostWindow) != nil ? view.frame.minX : 10
        menu.popUp(positioning: nil, at: NSPoint(x: menuX, y: 0), in: titleBar)
    }

    @objc func providerMenuItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let newProvider = AgentProvider(rawValue: raw) else { return }

        let host = providerMenuHostWindow
        providerMenuHostWindow = nil
        guard let host else { return }

        if let panel = detachedPanels.first(where: { $0.window === host }) {
            let current = panel.providerOverride ?? provider
            guard newProvider != current else { return }
            panel.providerOverride = newProvider
            restartDetachedSession(for: host)
            return
        }

        if host === popoverWindow {
            guard newProvider != provider else { return }
            provider = newProvider
            session?.terminate()
            session = nil
            popoverWindow?.orderOut(nil)
            removePopoverBecameKeyObserver()
            popoverWindow = nil
            terminalView = nil
            thinkingBubbleWindow?.orderOut(nil)
            thinkingBubbleWindow = nil
            openPopover()
            return
        }
    }

    private func restartDetachedSession(for hostWindow: NSWindow) {
        guard let panel = detachedPanel(for: hostWindow) else { return }
        let term = panel.terminal
        let p = panel.providerOverride ?? provider
        panel.session.terminate()
        currentStreamingText = ""
        term.provider = p
        term.resetState()
        term.showSessionMessage()
        let newSession = p.createSession()
        panel.session = newSession
        bindDetachedPanelCallbacks(panel)
        newSession.start()
        updateDetachedTitleBarProviderLabels(for: hostWindow)
    }

    private func updateDetachedTitleBarProviderLabels(for hostWindow: NSWindow) {
        guard let panel = detachedPanel(for: hostWindow) else { return }
        guard let cv = panel.window.contentView else { return }
        let t = resolvedTheme
        let p = panel.providerOverride ?? provider
        panel.window.title = "\(name) — \(p.displayName)"
        guard let titleBar = cv.subviews.first(where: { abs($0.frame.height - 28) < 0.5 && abs($0.frame.maxY - cv.bounds.height) < 2 }) else { return }

        var titleField: NSTextField?
        var providerArrow: NSButton?
        for sub in titleBar.subviews {
            if titleField == nil, let tf = sub as? NSTextField { titleField = tf }
            if providerArrow == nil, let b = sub as? NSButton, b.tag == Self.detachedProviderArrowButtonTag { providerArrow = b }
        }
        guard let tf = titleField else { return }
        tf.stringValue = t.titleString(for: p)
        tf.sizeToFit()
        tf.frame.origin = NSPoint(x: Self.detachedTitleLeadingInset, y: 6)
        if let arrow = providerArrow {
            var af = arrow.frame
            af.origin.x = tf.frame.maxX + 2
            arrow.frame = af
        }
        if let click = titleBar.subviews.first(where: { ($0 as? NSButton)?.tag == Self.detachedProviderClickAreaTag }) as? NSButton {
            let endX = (providerArrow?.frame.maxX ?? tf.frame.maxX) + 4
            let clickW = max(endX - Self.detachedTitleLeadingInset, 48)
            click.frame = NSRect(x: Self.detachedTitleLeadingInset, y: 0, width: clickW, height: 28)
        }
    }

    @objc func copyLastResponseFromButton(_ sender: Any?) {
        let term: TerminalView?
        if let view = sender as? NSView,
           let w = view.window,
           let panel = detachedPanel(for: w) {
            term = panel.terminal
        } else {
            term = terminalView
        }
        term?.handleSlashCommandPublic("/copy")
    }

    @objc func refreshSessionFromButton(_ sender: Any?) {
        guard !isOnboarding else { return }
        if let view = sender as? NSView,
           let w = view.window,
           detachedPanel(for: w) != nil {
            resetSession(for: .detachedWindow(w))
        } else {
            resetSession(for: .dockPopover)
        }
    }

    private func formatToolInput(_ input: [String: Any]) -> String {
        if let cmd = input["command"] as? String { return cmd }
        if let path = input["file_path"] as? String { return path }
        if let pattern = input["pattern"] as? String { return pattern }
        return input.keys.sorted().prefix(3).joined(separator: ", ")
    }

    func updatePopoverPosition() {
        guard let popover = popoverWindow, isIdleForPopover else { return }
        guard let screen = NSScreen.main else { return }

        let charFrame = window.frame
        let popoverSize = popover.frame.size
        var x = charFrame.midX - popoverSize.width / 2
        // Half character height pulls the panel toward the sprite; ~4 cm (~113 pt) extra lift keeps it off the terminal.
        let fourCmInPoints: CGFloat = 72.0 * 4.0 / 2.54
        let y = charFrame.maxY - 15 - displayHeight * 0.5 + fourCmInPoints

        let screenFrame = screen.frame
        x = max(screenFrame.minX + 4, min(x, screenFrame.maxX - popoverSize.width - 4))
        let clampedY = min(y, screenFrame.maxY - popoverSize.height - 4)

        popover.setFrameOrigin(NSPoint(x: x, y: clampedY))
    }

    // MARK: - Thinking Bubble

    private static let thinkingPhrases = [
        "hmm...", "thinking...", "one sec...", "ok hold on",
        "let me check", "working on it", "almost...", "bear with me",
        "on it!", "gimme a sec", "brb", "processing...",
        "hang tight", "just a moment", "figuring it out",
        "crunching...", "reading...", "looking...",
        "cooking...", "vibing...", "digging in",
        "connecting dots", "give me a sec",
        "don't rush me", "calculating...", "assembling\u{2026}"
    ]

    private static let completionPhrases = [
        "done!", "all set!", "ready!", "here you go", "got it!",
        "finished!", "ta-da!", "voila!",
        "boom!", "there ya go!", "check it out!"
    ]

    private var lastPhraseUpdate: CFTimeInterval = 0
    var currentPhrase = ""
    var completionBubbleExpiry: CFTimeInterval = 0
    var showingCompletion = false

    private static let bubbleH: CGFloat = 26
    /// Bubble window bottom sits at this fraction of character height from the dock baseline (lower = closer to head).
    private static let bubbleAnchorFromCharacterBottom: CGFloat = 0.58
    private var phraseAnimating = false

    func updateThinkingBubble() {
        let now = CACurrentMediaTime()

        if showingCompletion {
            if now >= completionBubbleExpiry {
                showingCompletion = false
                hideBubble()
                return
            }
            if isIdleForPopover {
                completionBubbleExpiry += 1.0 / 60.0
                hideBubble()
            } else {
                showBubble(text: currentPhrase, isCompletion: true)
            }
            return
        }

        if isAgentBusy && !isIdleForPopover {
            let oldPhrase = currentPhrase
            updateThinkingPhrase()
            if currentPhrase != oldPhrase && !oldPhrase.isEmpty && !phraseAnimating {
                animatePhraseChange(to: currentPhrase, isCompletion: false)
            } else if !phraseAnimating {
                showBubble(text: currentPhrase, isCompletion: false)
            }
        } else if !showingCompletion {
            hideBubble()
        }
    }

    private func hideBubble() {
        if thinkingBubbleWindow?.isVisible ?? false {
            thinkingBubbleWindow?.orderOut(nil)
        }
    }

    private func animatePhraseChange(to newText: String, isCompletion: Bool) {
        guard let win = thinkingBubbleWindow, win.isVisible,
              let label = win.contentView?.viewWithTag(100) as? NSTextField else {
            showBubble(text: newText, isCompletion: isCompletion)
            return
        }
        phraseAnimating = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            label.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.showBubble(text: newText, isCompletion: isCompletion)
            label.alphaValue = 0.0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                label.animator().alphaValue = 1.0
            }, completionHandler: {
                self?.phraseAnimating = false
            })
        })
    }

    func showBubble(text: String, isCompletion: Bool) {
        let t = resolvedTheme
        if thinkingBubbleWindow == nil {
            createThinkingBubble()
        }

        let h = Self.bubbleH
        let padding: CGFloat = 16
        let font = t.bubbleFont
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let bubbleW = max(ceil(textSize.width) + padding * 2, 48)

        let charFrame = window.frame
        let x = charFrame.midX - bubbleW / 2
        let y = charFrame.origin.y + charFrame.height * Self.bubbleAnchorFromCharacterBottom
        thinkingBubbleWindow?.setFrame(CGRect(x: x, y: y, width: bubbleW, height: h), display: false)

        let borderColor = isCompletion ? t.bubbleCompletionBorder.cgColor : t.bubbleBorder.cgColor
        let textColor = isCompletion ? t.bubbleCompletionText : t.bubbleText

        if let container = thinkingBubbleWindow?.contentView {
            container.frame = NSRect(x: 0, y: 0, width: bubbleW, height: h)
            container.layer?.backgroundColor = t.bubbleBg.cgColor
            container.layer?.cornerRadius = t.bubbleCornerRadius
            container.layer?.borderColor = borderColor
            if let label = container.viewWithTag(100) as? NSTextField {
                label.font = font
                let lineH = ceil(textSize.height)
                let labelY = round((h - lineH) / 2) - 1
                label.frame = NSRect(x: 0, y: labelY, width: bubbleW, height: lineH + 2)
                label.stringValue = text
                label.textColor = textColor
            }
        }

        if !(thinkingBubbleWindow?.isVisible ?? false) {
            thinkingBubbleWindow?.alphaValue = 1.0
            thinkingBubbleWindow?.orderFrontRegardless()
        }
    }

    private func updateThinkingPhrase() {
        let now = CACurrentMediaTime()
        if currentPhrase.isEmpty || now - lastPhraseUpdate > Double.random(in: 3.0...5.0) {
            var next = Self.thinkingPhrases.randomElement() ?? "..."
            while next == currentPhrase && Self.thinkingPhrases.count > 1 {
                next = Self.thinkingPhrases.randomElement() ?? "..."
            }
            currentPhrase = next
            lastPhraseUpdate = now
        }
    }

    func showCompletionBubble() {
        currentPhrase = Self.completionPhrases.randomElement() ?? "done!"
        showingCompletion = true
        completionBubbleExpiry = CACurrentMediaTime() + 3.0
        lastPhraseUpdate = 0
        phraseAnimating = false
        if !isIdleForPopover {
            showBubble(text: currentPhrase, isCompletion: true)
        }
    }

    private func createThinkingBubble() {
        let t = resolvedTheme
        let w: CGFloat = 80
        let h = Self.bubbleH
        let win = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: w, height: h),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 5)
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.moveToActiveSpace, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = t.bubbleBg.cgColor
        container.layer?.cornerRadius = t.bubbleCornerRadius
        container.layer?.borderWidth = 1
        container.layer?.borderColor = t.bubbleBorder.cgColor

        let font = t.bubbleFont
        let lineH = ceil(("Xg" as NSString).size(withAttributes: [.font: font]).height)
        let labelY = round((h - lineH) / 2) - 1

        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = t.bubbleText
        label.alignment = .center
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.frame = NSRect(x: 0, y: labelY, width: w, height: lineH + 2)
        label.tag = 100
        container.addSubview(label)

        win.contentView = container
        thinkingBubbleWindow = win
    }

    // MARK: - Completion Sound

    static var soundsEnabled = true

    private static let completionSounds: [(name: String, ext: String)] = [
        ("ping-aa", "mp3"), ("ping-bb", "mp3"), ("ping-cc", "mp3"),
        ("ping-dd", "mp3"), ("ping-ee", "mp3"), ("ping-ff", "mp3"),
        ("ping-gg", "mp3"), ("ping-hh", "mp3"), ("ping-jj", "m4a")
    ]
    private static var lastSoundIndex: Int = -1

    func playCompletionSound() {
        guard Self.soundsEnabled else { return }
        var idx: Int
        repeat {
            idx = Int.random(in: 0..<Self.completionSounds.count)
        } while idx == Self.lastSoundIndex && Self.completionSounds.count > 1
        Self.lastSoundIndex = idx

        let s = Self.completionSounds[idx]
        if let url = Bundle.main.url(forResource: s.name, withExtension: s.ext, subdirectory: "Sounds"),
           let sound = NSSound(contentsOf: url, byReference: true) {
            sound.play()
        }
    }

    // MARK: - Walking

    /// Other dock characters whose positions we use to avoid landing stacked (no teleporting — only the planned walk endpoint moves).
    private func peerCharactersForSeparation() -> [WalkerCharacter] {
        guard let all = controller?.characters else { return [] }
        return all.filter { other in
            other !== self && other.window.isVisible && other.isManuallyVisible && !other.isIdleForPopover
        }
    }

    private var minWalkSeparationPixels: CGFloat {
        max(displayWidth * 0.35, 72)
    }

    /// Nudges `end` along the same direction as `start → end` so the stop stays at least `minWalkSeparationPixels` from each peer’s current progress.
    private func applyPeerWalkEndSeparation(start: CGFloat, end: CGFloat) -> CGFloat {
        let peers = peerCharactersForSeparation()
        guard !peers.isEmpty, currentTravelDistance > 1 else { return end }
        let minProg = minWalkSeparationPixels / currentTravelDistance
        var e = end
        for _ in 0..<6 {
            var changed = false
            for peer in peers {
                let p = peer.positionProgress
                guard abs(e - p) < minProg else { continue }
                if e >= start {
                    let n = max(e, p + minProg)
                    if n != e { e = n; changed = true }
                } else {
                    let n = min(e, p - minProg)
                    if n != e { e = n; changed = true }
                }
            }
            e = min(max(e, 0), 1)
            if !changed { break }
        }
        return e
    }

    func startWalk() {
        idleMicroHoldActive = false
        isPaused = false
        isWalking = true
        playCount = 0
        walkStartTime = CACurrentMediaTime()

        if positionProgress > 0.85 {
            goingRight = false
        } else if positionProgress < 0.15 {
            goingRight = true
        } else {
            goingRight = Bool.random()
            let peers = peerCharactersForSeparation()
            if currentTravelDistance > 1,
               let nearest = peers.min(by: {
                   abs($0.positionProgress - positionProgress) < abs($1.positionProgress - positionProgress)
               }) {
                let sep = abs(nearest.positionProgress - positionProgress) * currentTravelDistance
                if sep < minWalkSeparationPixels {
                    // Peer is to the left on the dock → go right (increase progress), and vice versa.
                    goingRight = nearest.positionProgress < positionProgress
                }
            }
        }

        walkStartPos = positionProgress
        // Walk a fixed pixel distance (~200-325px) regardless of screen width.
        let referenceWidth: CGFloat = 500.0
        let walkPixels = CGFloat.random(in: walkAmountRange) * referenceWidth
        let walkAmount = currentTravelDistance > 0 ? walkPixels / currentTravelDistance : 0.3
        let tentativeEnd: CGFloat
        if goingRight {
            tentativeEnd = min(walkStartPos + walkAmount, 1.0)
        } else {
            tentativeEnd = max(walkStartPos - walkAmount, 0.0)
        }
        walkEndPos = applyPeerWalkEndSeparation(start: walkStartPos, end: tentativeEnd)

        // If separation pinned us to essentially no move, try the other direction with the same stride length.
        let minStrideProg = 8 / max(currentTravelDistance, 1)
        if abs(walkEndPos - walkStartPos) < minStrideProg {
            goingRight.toggle()
            let altEnd: CGFloat
            if goingRight {
                altEnd = min(walkStartPos + walkAmount, 1.0)
            } else {
                altEnd = max(walkStartPos - walkAmount, 0.0)
            }
            walkEndPos = applyPeerWalkEndSeparation(start: walkStartPos, end: altEnd)
        }

        // Store pixel positions so walk speed stays consistent if screen changes mid-walk
        walkStartPixel = walkStartPos * currentTravelDistance
        walkEndPixel = walkEndPos * currentTravelDistance

        updateFlip()
        useWalkClipMoveRange = walkLoopVideoName != nil
        let walkClip = walkLoopVideoName ?? videoName
        playLoop(videoName: walkClip)
        queuePlayer.seek(to: .zero)
        queuePlayer.play()
        refreshPlaybackRateAfterClipChange()
    }

    func enterPause() {
        isWalking = false
        isPaused = true
        useWalkClipMoveRange = false
        if let idle = idleLoopVideoName {
            playLoop(videoName: idle)
            queuePlayer.play()
        } else {
            queuePlayer.pause()
            queuePlayer.seek(to: .zero)
        }
        refreshPlaybackRateAfterClipChange()
        resetIdleMicroHoldScheduleAfterMotionPhase()
        let delay = Double.random(in: 40.0...85.0)
        pauseEndTime = CACurrentMediaTime() + delay
    }

    func updateFlip() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if goingRight {
            playerLayer.transform = CATransform3DIdentity
        } else {
            playerLayer.transform = CATransform3DMakeScale(-1, 1, 1)
        }
        playerLayer.frame = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
        CATransaction.commit()
    }

    var currentFlipCompensation: CGFloat {
        goingRight ? 0 : flipXOffset
    }

    func movementPosition(at videoTime: CFTimeInterval) -> CGFloat {
        let dIn = fullSpeedStart - accelStart
        let dLin = decelStart - fullSpeedStart
        let dOut = walkStop - decelStart
        let v = 1.0 / (dIn / 2.0 + dLin + dOut / 2.0)

        if videoTime <= accelStart {
            return 0.0
        } else if videoTime <= fullSpeedStart {
            let t = videoTime - accelStart
            return CGFloat(v * t * t / (2.0 * dIn))
        } else if videoTime <= decelStart {
            let easeInDist = v * dIn / 2.0
            let t = videoTime - fullSpeedStart
            return CGFloat(easeInDist + v * t)
        } else if videoTime <= walkStop {
            let easeInDist = v * dIn / 2.0
            let linearDist = v * dLin
            let t = videoTime - decelStart
            return CGFloat(easeInDist + linearDist + v * (t - t * t / (2.0 * dOut)))
        } else {
            return 1.0
        }
    }

    /// Maps current clip time to walk progress [0, 1], optionally constraining movement to a subrange.
    private func walkProgress(forVideoTime videoTime: CFTimeInterval) -> CGFloat {
        let range: ClosedRange<CFTimeInterval>?
        if useWalkClipMoveRange {
            range = walkHorizontalMoveVideoRange ?? fallbackWalkLinearRange()
        } else {
            range = horizontalMoveVideoRange
        }
        guard let range = range else {
            return movementPosition(at: videoTime)
        }
        if videoTime <= range.lowerBound {
            return 0.0
        }
        if videoTime >= range.upperBound {
            return 1.0
        }
        let span = range.upperBound - range.lowerBound
        guard span > 1e-6 else { return movementPosition(at: videoTime) }
        let u = (videoTime - range.lowerBound) / span
        // Linear here keeps dock travel tightly locked to visible stepping frames.
        return CGFloat(u)
    }

    /// Uses AVPlayer's current timeline position so dock movement stays synchronized to rendered frames.
    private func syncedVideoTime(fallbackElapsed elapsed: CFTimeInterval) -> CFTimeInterval {
        let t = queuePlayer.currentTime().seconds
        let dur = activeLoopDuration
        guard t.isFinite, t >= 0 else { return min(elapsed, dur) }
        let mod = t.truncatingRemainder(dividingBy: dur)
        return mod >= 0 ? mod : (mod + dur)
    }

    /// Wall-clock length of one playthrough of the current clip at `queuePlayer.rate` (avoids ending walks early when rate < 1).
    private var wallDurationForCurrentClip: CFTimeInterval {
        let r = Double(max(queuePlayer.rate, 0.05))
        return activeLoopDuration / r
    }

    /// Prefer sample-accurate `currentTime` before the looper wraps; then scale wall elapsed by rate.
    private func walkPhaseMediaTime(elapsed: CFTimeInterval) -> CFTimeInterval {
        let dur = activeLoopDuration
        let t = queuePlayer.currentTime().seconds
        if t.isFinite, t >= 0, t < dur + 0.2 {
            return min(max(t, 0), dur)
        }
        let scaled = elapsed * Double(max(queuePlayer.rate, 0.05))
        return min(max(scaled, 0), dur)
    }

    // MARK: - Frame Update

    func update(dockX: CGFloat, dockWidth: CGFloat, dockTopY: CGFloat) {
        currentTravelDistance = max(dockWidth - displayWidth, 0)
        let now = CACurrentMediaTime()

        if isIdleForPopover {
            let travelDistance = currentTravelDistance
            let x = dockX + travelDistance * positionProgress + currentFlipCompensation
            let bottomPadding = displayHeight * 0.15
            let y = dockTopY - bottomPadding + yOffset
            window.setFrameOrigin(NSPoint(x: x, y: y))
            updatePopoverPosition()
            ensurePopoverAboveCharacterWindow()
            updateThinkingBubble()
            return
        }

        if isPaused {
            if now >= pauseEndTime {
                startWalk()
            } else {
                playAmbientWaveOneShotIfDue(now: now)
                tickIdleMicroHold(now: now)
                let travelDistance = max(dockWidth - displayWidth, 0)
                let x = dockX + travelDistance * positionProgress + currentFlipCompensation
                let bottomPadding = displayHeight * 0.15
                let y = dockTopY - bottomPadding + yOffset
                window.setFrameOrigin(NSPoint(x: x, y: y))
                return
            }
        }

        if isWalking {
            let elapsed = now - walkStartTime
            let videoTime = walkPhaseMediaTime(elapsed: elapsed)
            let travelDistance = currentTravelDistance
            let walkWall = wallDurationForCurrentClip

            // Interpolate in pixel space for consistent speed across screen changes
            let walkNorm = elapsed >= walkWall ? 1.0 : walkProgress(forVideoTime: videoTime)
            let currentPixel = walkStartPixel + (walkEndPixel - walkStartPixel) * walkNorm

            // Convert pixel position back to progress for the current screen
            if travelDistance > 0 {
                positionProgress = min(max(currentPixel / travelDistance, 0), 1)
            }

            if elapsed >= walkWall - 0.02 {
                walkEndPos = positionProgress
                enterPause()
                return
            }

            let x = dockX + travelDistance * positionProgress + currentFlipCompensation
            let bottomPadding = displayHeight * 0.15
            let y = dockTopY - bottomPadding + yOffset
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        updateThinkingBubble()
    }
}
