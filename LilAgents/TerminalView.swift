import AppKit

class PaddedTextFieldCell: NSTextFieldCell {
    private let inset = NSSize(width: 8, height: 2)
    var fieldBackgroundColor: NSColor?
    var fieldCornerRadius: CGFloat = 4

    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let bg = fieldBackgroundColor {
            let path = NSBezierPath(roundedRect: cellFrame, xRadius: fieldCornerRadius, yRadius: fieldCornerRadius)
            bg.setFill()
            path.fill()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let base = super.drawingRect(forBounds: rect)
        return base.insetBy(dx: inset.width, dy: inset.height)
    }

    private func configureEditor(_ textObj: NSText) {
        if let color = textColor {
            textObj.textColor = color
        }
        if let tv = textObj as? NSTextView {
            tv.insertionPointColor = textColor ?? .textColor
            tv.drawsBackground = false
            tv.backgroundColor = .clear
        }
        textObj.font = font
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        configureEditor(textObj)
        super.edit(withFrame: rect.insetBy(dx: inset.width, dy: inset.height), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        configureEditor(textObj)
        super.select(withFrame: rect.insetBy(dx: inset.width, dy: inset.height), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

class TerminalView: NSView {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    let inputField = NSTextField()
    var onSendMessage: ((String) -> Void)?
    var onClearRequested: (() -> Void)?
    var provider: AgentProvider = .claude {
        didSet {
            updatePlaceholder()
        }
    }

    private var currentAssistantText = ""
    private var lastAssistantText = ""
    /// Plain assistant text for this user turn (survives tool breaks); used for `/copy` and `lastAssistantText` at turn end.
    private var assistantTurnPlainTextForCopy = ""
    private var isStreaming = false
    private var showingSessionMessage = false
    /// `NSTextStorage` location where the in-flight assistant reply begins (re-rendered as Markdown each chunk).
    private var assistantStreamStorageStart: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    var characterColor: NSColor?
    var themeOverride: PopoverTheme?
    /// Optional one-line persona note prepended to the provider placeholder.
    var personaInputHint: String? {
        didSet { updatePlaceholder() }
    }
    var theme: PopoverTheme {
        var t = themeOverride ?? PopoverTheme.current
        if themeOverride == nil, let color = characterColor {
            t = t.withCharacterColor(color)
        }
        return t.withCustomFont()
    }

    // MARK: - Setup

    private func updatePlaceholder() {
        let t = theme
        let base = provider.inputPlaceholder
        let trimmed = personaInputHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Short line: persona tag + provider (avoid long duplicated “ask …” copy).
        let text: String
        if trimmed.isEmpty {
            text = base
        } else {
            text = "\(trimmed) · \(provider.displayName)"
        }
        inputField.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [.font: t.font, .foregroundColor: t.textDim]
        )
    }

    private func setupViews() {
        let t = theme
        let inputHeight: CGFloat = 30
        let padding: CGFloat = 10

        scrollView.frame = NSRect(
            x: padding, y: inputHeight + padding + 6,
            width: frame.width - padding * 2,
            height: frame.height - inputHeight - padding - 10
        )
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        textView.frame = scrollView.contentView.bounds
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textColor = t.textPrimary
        textView.font = AgentResponseTypography.proseBodyFont(for: t)
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        let defaultPara = NSMutableParagraphStyle()
        defaultPara.paragraphSpacing = 8
        textView.defaultParagraphStyle = defaultPara
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: t.accentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        scrollView.documentView = textView
        addSubview(scrollView)

        inputField.frame = NSRect(
            x: padding, y: 6,
            width: frame.width - padding * 2,
            height: inputHeight
        )
        inputField.autoresizingMask = [.width]
        inputField.focusRingType = .none
        let paddedCell = PaddedTextFieldCell(textCell: "")
        paddedCell.isEditable = true
        paddedCell.isScrollable = true
        paddedCell.font = t.font
        paddedCell.textColor = t.textPrimary
        paddedCell.drawsBackground = false
        paddedCell.isBezeled = false
        paddedCell.fieldBackgroundColor = t.inputBg
        paddedCell.fieldCornerRadius = t.inputCornerRadius
        inputField.cell = paddedCell
        updatePlaceholder()
        inputField.target = self
        inputField.action = #selector(inputSubmitted)
        addSubview(inputField)
    }

    /// Re-apply colors and fonts from the current `theme` (e.g. after global style switch while this view is kept open).
    func reapplyAppearanceFromTheme() {
        let t = theme
        textView.textColor = t.textPrimary
        textView.font = AgentResponseTypography.proseBodyFont(for: t)
        textView.linkTextAttributes = [
            .foregroundColor: t.accentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        if let cell = inputField.cell as? PaddedTextFieldCell {
            cell.font = t.font
            cell.textColor = t.textPrimary
            cell.fieldBackgroundColor = t.inputBg
            cell.fieldCornerRadius = t.inputCornerRadius
        }
        updatePlaceholder()
        needsDisplay = true
    }

    func resetState() {
        isStreaming = false
        currentAssistantText = ""
        lastAssistantText = ""
        showingSessionMessage = false
        assistantStreamStorageStart = nil
        assistantTurnPlainTextForCopy = ""
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
    }

    func showSessionMessage() {
        let t = theme
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "  \u{2726} new session\n",
            attributes: [.font: t.font, .foregroundColor: t.accentColor]
        ))
        showingSessionMessage = true
    }

    // MARK: - Input

    @objc private func inputSubmitted() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.stringValue = ""

        if handleSlashCommand(text) { return }

        if showingSessionMessage {
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            showingSessionMessage = false
        }
        appendUser(text)
        isStreaming = true
        currentAssistantText = ""
        onSendMessage?(text)
    }

    // MARK: - Slash Commands

    func handleSlashCommandPublic(_ text: String) {
        _ = handleSlashCommand(text)
    }

    private func handleSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let cmd = text.lowercased().trimmingCharacters(in: .whitespaces)

        switch cmd {
        case "/clear":
            resetState()
            onClearRequested?()
            return true

        case "/copy":
            let latest = assistantTurnPlainTextForCopy.isEmpty ? lastAssistantText : assistantTurnPlainTextForCopy
            let toCopy = latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "nothing to copy yet" : latest
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(toCopy, forType: .string)
            let t = theme
            textView.textStorage?.append(NSAttributedString(
                string: "  ✓ copied to clipboard\n",
                attributes: [.font: t.font, .foregroundColor: t.successColor]
            ))
            scrollToBottom()
            return true

        case "/help":
            let t = theme
            let help = NSMutableAttributedString()
            help.append(NSAttributedString(string: "  lil agents — slash commands\n",
                attributes: [.font: t.fontBold, .foregroundColor: t.accentColor]))
            help.append(NSAttributedString(string: "  /clear  ", attributes: [.font: t.fontBold, .foregroundColor: t.textPrimary]))
            help.append(NSAttributedString(string: "clear chat history\n", attributes: [.font: t.font, .foregroundColor: t.textDim]))
            help.append(NSAttributedString(string: "  /copy   ", attributes: [.font: t.fontBold, .foregroundColor: t.textPrimary]))
            help.append(NSAttributedString(string: "copy last response\n", attributes: [.font: t.font, .foregroundColor: t.textDim]))
            help.append(NSAttributedString(string: "  /help   ", attributes: [.font: t.fontBold, .foregroundColor: t.textPrimary]))
            help.append(NSAttributedString(string: "show this message\n", attributes: [.font: t.font, .foregroundColor: t.textDim]))
            textView.textStorage?.append(help)
            scrollToBottom()
            return true

        default:
            let t = theme
            textView.textStorage?.append(NSAttributedString(
                string: "  unknown command: \(text) (try /help)\n",
                attributes: [.font: t.font, .foregroundColor: t.errorColor]
            ))
            scrollToBottom()
            return true
        }
    }

    // MARK: - Append Methods

    private var messageSpacing: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 8
        return p
    }

    private func ensureNewline() {
        if let storage = textView.textStorage, storage.length > 0 {
            if !storage.string.hasSuffix("\n") {
                storage.append(NSAttributedString(string: "\n"))
            }
        }
    }

    func appendUser(_ text: String) {
        let t = theme
        assistantStreamStorageStart = nil
        assistantTurnPlainTextForCopy = ""
        ensureNewline()
        let para = messageSpacing
        let userBold = AgentResponseTypography.proseBoldFont(for: t)
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "> ", attributes: [
            .font: userBold, .foregroundColor: t.accentColor, .paragraphStyle: para
        ]))
        attributed.append(NSAttributedString(string: "\(text)\n", attributes: [
            .font: userBold, .foregroundColor: t.textPrimary, .paragraphStyle: para
        ]))
        textView.textStorage?.append(attributed)
        scrollToBottom()
    }

    func appendStreamingText(_ text: String) {
        var cleaned = text
        if currentAssistantText.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: "^\n+", with: "", options: .regularExpression)
        }
        currentAssistantText += cleaned
        assistantTurnPlainTextForCopy += cleaned
        guard !cleaned.isEmpty, let storage = textView.textStorage else { return }
        let t = theme
        if assistantStreamStorageStart == nil {
            assistantStreamStorageStart = storage.length
        }
        let start = assistantStreamStorageStart!
        let safeStart = min(max(0, start), storage.length)
        if safeStart != start {
            assistantStreamStorageStart = safeStart
        }
        let replaceLen = max(0, storage.length - safeStart)
        var rendered = AgentResponseTypography.markdownAttributedString(currentAssistantText, theme: t)
        if rendered.length == 0, !currentAssistantText.isEmpty {
            rendered = AgentResponseTypography.plainAttributedString(currentAssistantText, theme: t)
        }
        storage.replaceCharacters(in: NSRange(location: safeStart, length: replaceLen), with: rendered)
        scrollToBottom()
    }

    func endStreaming() {
        if isStreaming {
            isStreaming = false
        }
        if !assistantTurnPlainTextForCopy.isEmpty {
            lastAssistantText = assistantTurnPlainTextForCopy
        }
        currentAssistantText = ""
        assistantTurnPlainTextForCopy = ""
        assistantStreamStorageStart = nil
    }

    func appendError(_ text: String) {
        let t = theme
        assistantStreamStorageStart = nil
        assistantTurnPlainTextForCopy = ""
        textView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [
            .font: AgentResponseTypography.proseBodyFont(for: t), .foregroundColor: t.errorColor
        ]))
        scrollToBottom()
    }

    func appendToolUse(toolName: String, summary: String) {
        let t = theme
        // Do not call `endStreaming()` here — it clears `isStreaming`, so `onTurnComplete` would skip
        // updating `lastAssistantText` and `/copy` would miss everything after the tool.
        assistantStreamStorageStart = nil
        currentAssistantText = ""
        let mono = AgentResponseTypography.codeFont(for: t)
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: "  \(toolName.uppercased()) ", attributes: [
            .font: AgentResponseTypography.proseBoldFont(for: t), .foregroundColor: t.accentColor
        ]))
        block.append(NSAttributedString(string: "\(summary)\n", attributes: [
            .font: mono, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func appendToolResult(summary: String, isError: Bool) {
        let t = theme
        let labelColor = isError ? t.errorColor : t.successColor
        let prefix = isError ? "  FAIL " : "  DONE "
        let mono = AgentResponseTypography.codeFont(for: t)
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: prefix, attributes: [
            .font: AgentResponseTypography.proseBoldFont(for: t), .foregroundColor: labelColor
        ]))
        block.append(NSAttributedString(string: "\(summary.isEmpty ? "" : summary)\n", attributes: [
            .font: mono, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func replayHistory(_ messages: [AgentMessage]) {
        let t = theme
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        assistantTurnPlainTextForCopy = ""
        var lastAssistantReplay = ""
        for msg in messages {
            switch msg.role {
            case .user:
                appendUser(msg.text)
            case .assistant:
                lastAssistantReplay = msg.text
                textView.textStorage?.append(AgentResponseTypography.markdownAttributedString(msg.text + "\n", theme: t))
            case .error:
                appendError(msg.text)
            case .toolUse:
                let monoUse = AgentResponseTypography.codeFont(for: t)
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: monoUse, .foregroundColor: t.textDim
                ]))
            case .toolResult:
                let isErr = msg.text.hasPrefix("ERROR:")
                let monoRes = AgentResponseTypography.codeFont(for: t)
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: monoRes, .foregroundColor: isErr ? t.errorColor : t.textDim
                ]))
            }
        }
        lastAssistantText = lastAssistantReplay
        scrollToBottom()
    }

    private func scrollToBottom() {
        textView.scrollToEndOfDocument(nil)
    }
}
