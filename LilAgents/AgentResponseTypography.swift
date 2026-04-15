import AppKit

/// Typography + lightweight Markdown → `NSAttributedString` for the dock chat transcript.
/// Keeps `TerminalView` focused on layout; all assistant-facing styles live here.
enum AgentResponseTypography {

    // MARK: - Fonts

    /// Body copy for agent prose: use system sans when the theme terminal font is monospace (e.g. Midnight).
    static func proseBodyFont(for theme: PopoverTheme) -> NSFont {
        if isMonospaceFamily(theme.font) {
            return .systemFont(ofSize: theme.font.pointSize, weight: .regular)
        }
        return theme.font
    }

    static func proseBoldFont(for theme: PopoverTheme) -> NSFont {
        if isMonospaceFamily(theme.fontBold) {
            return .systemFont(ofSize: theme.fontBold.pointSize, weight: .semibold)
        }
        return theme.fontBold
    }

    static func codeFont(for theme: PopoverTheme) -> NSFont {
        .monospacedSystemFont(ofSize: max(theme.font.pointSize - 1, 10), weight: .regular)
    }

    private static func isMonospaceFamily(_ font: NSFont) -> Bool {
        let n = font.fontName.lowercased()
        return n.contains("mono") || n.contains("menlo") || n.contains("courier") || n.contains("consolas")
    }

    // MARK: - Markdown

    /// Plain transcript fallback when Markdown parsing yields nothing (e.g. chunk is only suppressed HR lines).
    static func plainAttributedString(_ text: String, theme: PopoverTheme) -> NSAttributedString {
        let body = proseBodyFont(for: theme)
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.12
        p.paragraphSpacing = 2
        return NSAttributedString(string: text, attributes: [
            .font: body, .foregroundColor: theme.textPrimary, .paragraphStyle: p
        ])
    }

    static func markdownAttributedString(_ text: String, theme: PopoverTheme) -> NSAttributedString {
        let body = proseBodyFont(for: theme)
        let bold = proseBoldFont(for: theme)
        var result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeLines: [String] = []

        for (i, line) in lines.enumerated() {
            let isLast = i == lines.count - 1
            let suffix = isLast ? "" : "\n"

            if line.hasPrefix("```") {
                if inCodeBlock {
                    appendCodeBlock(&result, lines: codeLines, theme: theme, body: body)
                    inCodeBlock = false
                    codeLines = []
                } else {
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            // Horizontal rules: suppressed — they add visual noise to conversational chat.
            if isHorizontalRule(line) {
                continue
            }

            // Empty lines → paragraph break spacer (breathing room between ideas).
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !isLast {
                    result.append(paragraphSpacer(body: body))
                }
                continue
            }

            if line.hasPrefix("> ") {
                let inner = String(line.dropFirst(2))
                appendBlockquoteLine(&result, inner: inner + suffix, theme: theme, body: body, bold: bold)
                continue
            }

            if line.hasPrefix("### ") {
                appendHeading(&result, text: String(line.dropFirst(4)) + suffix, level: 3, theme: theme, body: body, bold: bold)
            } else if line.hasPrefix("## ") {
                appendHeading(&result, text: String(line.dropFirst(3)) + suffix, level: 2, theme: theme, body: body, bold: bold)
            } else if line.hasPrefix("# ") {
                appendHeading(&result, text: String(line.dropFirst(2)) + suffix, level: 1, theme: theme, body: body, bold: bold)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = String(line.dropFirst(2))
                appendBulletItem(&result, content: content + suffix, theme: theme, body: body, bold: bold)
            } else if let num = numberedListPrefix(line) {
                let content = String(line.dropFirst(num.count + 2))
                appendNumberedItem(&result, number: num, content: content + suffix, theme: theme, body: body, bold: bold)
            } else {
                result.append(renderInlineMarkdown(line + suffix, theme: theme, body: body, bold: bold))
            }
        }

        if inCodeBlock, !codeLines.isEmpty {
            appendCodeBlock(&result, lines: codeLines, theme: theme, body: body)
        }

        if result.length == 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return plainAttributedString(text, theme: theme)
        }
        return result
    }

    // MARK: - Block helpers

    private static func isHorizontalRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" })
    }

    private static func numberedListPrefix(_ line: String) -> String? {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber {
            idx = line.index(after: idx)
        }
        guard idx > line.startIndex, idx < line.endIndex, line[idx] == "." else { return nil }
        let afterDot = line.index(after: idx)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return String(line[..<idx])
    }

    /// Small blank-line spacer — adds paragraph breathing room without inserting visible content.
    private static func paragraphSpacer(body: NSFont) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = 0
        p.paragraphSpacingBefore = 0
        p.minimumLineHeight = body.pointSize * 0.55
        p.maximumLineHeight = body.pointSize * 0.55
        return NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: p])
    }

    private static func appendBlockquoteLine(
        _ result: inout NSMutableAttributedString,
        inner: String,
        theme: PopoverTheme,
        body: NSFont,
        bold: NSFont
    ) {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 2
        p.paragraphSpacing = 4
        p.headIndent = 14
        p.firstLineHeadIndent = 14
        result.append(renderInlineMarkdown(
            inner,
            theme: theme,
            body: body,
            bold: bold,
            overrideColor: theme.textDim,
            extraParagraph: p
        ))
    }

    private static func appendHeading(
        _ result: inout NSMutableAttributedString,
        text: String,
        level: Int,
        theme: PopoverTheme,
        body: NSFont,
        bold: NSFont
    ) {
        // Size bumps are distinct enough to read but not screaming-large in a small panel.
        let bumps: [CGFloat] = [5, 3, 1.5]
        let bump = bumps[min(level - 1, 2)]
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = level == 1 ? 12 : 9
        p.paragraphSpacing = 5
        p.lineHeightMultiple = 1.15
        let weight: NSFont.Weight = level == 1 ? .bold : .semibold
        let font = NSFont.systemFont(ofSize: body.pointSize + bump, weight: weight)
        // H1 uses textPrimary so it doesn't compete with accent chrome; H2/H3 use accent lightly.
        let color = level == 1 ? theme.textPrimary : theme.accentColor
        result.append(renderInlineMarkdown(text, theme: theme, body: body, bold: bold, overrideBodyFont: font, overrideColor: color, extraParagraph: p))
    }

    private static func appendCodeBlock(
        _ result: inout NSMutableAttributedString,
        lines: [String],
        theme: PopoverTheme,
        body: NSFont
    ) {
        let mono = codeFont(for: theme)
        let codeText = lines.joined(separator: "\n")
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 10
        p.paragraphSpacing = 10
        p.headIndent = 10
        p.firstLineHeadIndent = 10
        p.lineHeightMultiple = 1.25
        result.append(NSAttributedString(string: codeText + "\n", attributes: [
            .font: mono,
            .foregroundColor: theme.textPrimary,
            .backgroundColor: theme.inputBg,
            .paragraphStyle: p
        ]))
    }

    /// Bullet item with hanging indent so wrapped lines align to the text, not the bullet.
    private static func appendBulletItem(
        _ result: inout NSMutableAttributedString,
        content: String,
        theme: PopoverTheme,
        body: NSFont,
        bold: NSFont
    ) {
        let indent: CGFloat = 16
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 0
        p.headIndent = indent
        p.paragraphSpacing = 3
        p.lineHeightMultiple = 1.32
        let tab = NSTextTab(textAlignment: .natural, location: indent)
        p.tabStops = [tab]
        let bulletChar = "\t•\t"
        let marker = NSAttributedString(string: bulletChar, attributes: [
            .font: body, .foregroundColor: theme.accentColor, .paragraphStyle: p
        ])
        result.append(marker)
        result.append(renderInlineMarkdown(content, theme: theme, body: body, bold: bold, extraParagraph: p))
    }

    /// Numbered list item with hanging indent matching the bullet style.
    private static func appendNumberedItem(
        _ result: inout NSMutableAttributedString,
        number: String,
        content: String,
        theme: PopoverTheme,
        body: NSFont,
        bold: NSFont
    ) {
        let indent: CGFloat = 20
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = 0
        p.headIndent = indent
        p.paragraphSpacing = 3
        p.lineHeightMultiple = 1.32
        let tab = NSTextTab(textAlignment: .natural, location: indent)
        p.tabStops = [tab]
        let marker = NSAttributedString(string: "\t\(number).\t", attributes: [
            .font: bold, .foregroundColor: theme.accentColor, .paragraphStyle: p
        ])
        result.append(marker)
        result.append(renderInlineMarkdown(content, theme: theme, body: body, bold: bold, extraParagraph: p))
    }

    // MARK: - Inline Markdown

    private static func renderInlineMarkdown(
        _ text: String,
        theme: PopoverTheme,
        body: NSFont,
        bold: NSFont,
        overrideBodyFont: NSFont? = nil,
        overrideColor: NSColor? = nil,
        extraParagraph: NSParagraphStyle? = nil
    ) -> NSAttributedString {
        let baseFont = overrideBodyFont ?? body
        let baseColor = overrideColor ?? theme.textPrimary
        let result = NSMutableAttributedString()
        var i = text.startIndex

        let bodyParagraph: NSParagraphStyle = {
            if let p = extraParagraph { return p }
            let m = NSMutableParagraphStyle()
            m.lineHeightMultiple = 1.32
            m.paragraphSpacing = 6
            return m
        }()
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont, .foregroundColor: baseColor, .paragraphStyle: bodyParagraph
        ]

        while i < text.endIndex {
            if text[i] == "`" {
                let afterTick = text.index(after: i)
                if afterTick < text.endIndex, let closeIdx = text[afterTick...].firstIndex(of: "`") {
                    let code = String(text[afterTick..<closeIdx])
                    let codeFont = codeFont(for: theme)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: codeFont,
                        .foregroundColor: theme.accentColor,
                        .backgroundColor: theme.inputBg,
                        .paragraphStyle: bodyParagraph
                    ]
                    result.append(NSAttributedString(string: code, attributes: attrs))
                    i = text.index(after: closeIdx)
                    continue
                }
            }
            if text[i] == "*",
               text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*" {
                let start = text.index(i, offsetBy: 2)
                if start < text.endIndex, let range = text.range(of: "**", range: start..<text.endIndex) {
                    let boldText = String(text[start..<range.lowerBound])
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: bold, .foregroundColor: baseColor, .paragraphStyle: bodyParagraph
                    ]
                    result.append(NSAttributedString(string: boldText, attributes: attrs))
                    i = range.upperBound
                    continue
                }
            }
            // Single *italic*
            if text[i] == "*" {
                let after = text.index(after: i)
                if after < text.endIndex, text[after] != "*",
                   let closeStar = text[after...].firstIndex(of: "*"),
                   closeStar > after,
                   text.index(after: closeStar) >= text.endIndex || text[text.index(after: closeStar)] != "*" {
                    let italicText = String(text[after..<closeStar])
                    let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: italicFont,
                        .foregroundColor: baseColor.withAlphaComponent(0.88),
                        .paragraphStyle: bodyParagraph
                    ]
                    result.append(NSAttributedString(string: italicText, attributes: attrs))
                    i = text.index(after: closeStar)
                    continue
                }
            }
            // _italic_
            if text[i] == "_" {
                let after = text.index(after: i)
                if after < text.endIndex, text[after] != "_",
                   let closeU = text[after...].firstIndex(of: "_"),
                   closeU > after,
                   text.index(after: closeU) >= text.endIndex || text[text.index(after: closeU)] != "_" {
                    let italicText = String(text[after..<closeU])
                    let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: italicFont,
                        .foregroundColor: baseColor.withAlphaComponent(0.88),
                        .paragraphStyle: bodyParagraph
                    ]
                    result.append(NSAttributedString(string: italicText, attributes: attrs))
                    i = text.index(after: closeU)
                    continue
                }
            }
            if text[i] == "[" {
                let afterBracket = text.index(after: i)
                if afterBracket < text.endIndex,
                   let closeBracket = text[afterBracket...].firstIndex(of: "]") {
                    let parenStart = text.index(after: closeBracket)
                    if parenStart < text.endIndex && text[parenStart] == "(" {
                        let afterParen = text.index(after: parenStart)
                        if afterParen < text.endIndex,
                           let closeParen = text[afterParen...].firstIndex(of: ")") {
                            let linkText = String(text[afterBracket..<closeBracket])
                            let urlStr = String(text[afterParen..<closeParen])
                            var attrs: [NSAttributedString.Key: Any] = [
                                .font: baseFont,
                                .foregroundColor: theme.accentColor,
                                .underlineStyle: NSUnderlineStyle.single.rawValue,
                                .paragraphStyle: bodyParagraph
                            ]
                            if let url = URL(string: urlStr) {
                                attrs[.link] = url
                                attrs[.cursor] = NSCursor.pointingHand
                            }
                            result.append(NSAttributedString(string: linkText, attributes: attrs))
                            i = text.index(after: closeParen)
                            continue
                        }
                    }
                }
            }
            if text[i] == "h" {
                let remaining = String(text[i...])
                if remaining.hasPrefix("https://") || remaining.hasPrefix("http://") {
                    var j = i
                    while j < text.endIndex && !text[j].isWhitespace && text[j] != ")" && text[j] != ">" {
                        j = text.index(after: j)
                    }
                    let urlStr = String(text[i..<j])
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: baseFont,
                        .foregroundColor: theme.accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .paragraphStyle: bodyParagraph
                    ]
                    if let url = URL(string: urlStr) {
                        attrs[.link] = url
                    }
                    result.append(NSAttributedString(string: urlStr, attributes: attrs))
                    i = j
                    continue
                }
            }
            result.append(NSAttributedString(string: String(text[i]), attributes: defaultAttrs))
            i = text.index(after: i)
        }
        return result
    }
}
