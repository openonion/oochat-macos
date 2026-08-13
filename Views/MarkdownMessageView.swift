import AppKit
import Foundation
import MarkdownUI
import SwiftMath
import SwiftUI

/// Normalizes supported agent output into Markdown understood by MarkdownUI.
enum MarkdownMessageNormalizer {
    static func normalize(_ content: String) -> String {
        let imageNormalized = normalizeImageTags(content)
        return normalizeStandaloneCode(imageNormalized)
    }

    private static func normalizeImageTags(_ content: String) -> String {
        guard let imageTagExpression = try? NSRegularExpression(
            pattern: #"<img\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else {
            return content
        }

        var result = content
        let matches = imageTagExpression.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )

        for match in matches.reversed() {
            guard let tagRange = Range(match.range, in: result) else {
                continue
            }

            let tag = String(result[tagRange])
            guard let source = attribute("src", in: tag), !source.isEmpty else {
                continue
            }

            let label = attribute("alt", in: tag)
                ?? attribute("title", in: tag)
                ?? "Image"
            let escapedLabel = label
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "]", with: "\\]")
            let decodedSource = source.replacingOccurrences(of: "&amp;", with: "&")

            result.replaceSubrange(
                tagRange,
                with: "![\(escapedLabel)](\(decodedSource))"
            )
        }

        return result
    }

    /// A model can occasionally return a complete source file without Markdown
    /// fences. Only wrap messages whose first meaningful line is a strong source
    /// marker, leaving ordinary prose and mixed prose/code responses untouched.
    private static func normalizeStandaloneCode(_ content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        let meaningfulLines = lines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard meaningfulLines.count >= 3,
              !containsFence(lines),
              let firstLine = meaningfulLines.first?.trimmingCharacters(
                in: .whitespaces
              ),
              let language = sourceLanguage(for: firstLine, lines: meaningfulLines),
              meaningfulLines.dropFirst().contains(where: { line in
                line.hasPrefix("    ") || line.hasPrefix("\t")
              })
        else {
            return content
        }

        return "```\(language)\n\(content.trimmingCharacters(in: .newlines))\n```"
    }

    private static func containsFence(_ lines: [String]) -> Bool {
        lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
        }
    }

    private static func sourceLanguage(
        for firstLine: String,
        lines: [String]
    ) -> String? {
        if firstLine.hasPrefix("def ")
            || firstLine.hasPrefix("async def ")
            || firstLine.hasPrefix("class ")
            || firstLine.hasPrefix("from ")
            || firstLine.hasPrefix("import ") {
            return "python"
        }
        if firstLine.hasPrefix("func ")
            || firstLine.hasPrefix("struct ")
            || firstLine.hasPrefix("protocol ")
            || firstLine.hasPrefix("extension ") {
            return "swift"
        }
        if firstLine.hasPrefix("function ")
            || firstLine.hasPrefix("const ")
            || firstLine.hasPrefix("let ")
            || firstLine.hasPrefix("var ") {
            return "javascript"
        }
        if firstLine.hasPrefix("#!/bin/bash")
            || firstLine.hasPrefix("#!/usr/bin/env bash") {
            return "bash"
        }
        let lastLine = lines.last?.trimmingCharacters(in: .whitespaces)
        if firstLine == "{" && lastLine == "}" {
            return "json"
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let expression = try? NSRegularExpression(
            pattern: #"\b\#(escapedName)\s*=\s*["']([^"']*)["']"#,
            options: [.caseInsensitive]
        ),
        let match = expression.firstMatch(
            in: tag,
            range: NSRange(tag.startIndex..., in: tag)
        ),
        let valueRange = Range(match.range(at: 1), in: tag)
        else {
            return nil
        }

        return String(tag[valueRange])
    }
}

enum MarkdownMessageBlock: Equatable {
    case markdown(String)
    case displayMath(String)
    case codeBlock(language: String?, content: String)
}

/// Separates display formulas from Markdown while leaving fenced code untouched.
enum MarkdownMathBlockParser {
    static func parse(_ content: String) -> [MarkdownMessageBlock] {
        let lines = content.components(separatedBy: "\n")
        var blocks: [MarkdownMessageBlock] = []
        var markdownLines: [String] = []
        var mathLines: [String] = []
        var mathClosingDelimiter: String?
        var fenceMarker: Character?
        var fenceOpeningLine: String?
        var currentFenceLanguage: String?
        var codeLines: [String] = []

        func flushMarkdown() {
            let markdown = markdownLines.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if !markdown.isEmpty {
                blocks.append(.markdown(markdown))
            }
            markdownLines.removeAll(keepingCapacity: true)
        }

        func flushMath() {
            let formula = mathLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !formula.isEmpty {
                blocks.append(.displayMath(formula))
            }
            mathLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let closing = mathClosingDelimiter {
                if let closingRange = trimmed.range(of: closing) {
                    mathLines.append(String(trimmed[..<closingRange.lowerBound]))
                    flushMath()
                    mathClosingDelimiter = nil
                    let remainder = String(trimmed[closingRange.upperBound...])
                    if !remainder.isEmpty {
                        markdownLines.append(remainder)
                    }
                } else {
                    mathLines.append(line)
                }
                continue
            }

            if let marker = fenceMarker {
                if isFenceLine(trimmed, marker: marker) {
                    blocks.append(
                        .codeBlock(
                            language: currentFenceLanguage,
                            content: codeLines.joined(separator: "\n")
                        )
                    )
                    fenceMarker = nil
                    fenceOpeningLine = nil
                    currentFenceLanguage = nil
                    codeLines.removeAll(keepingCapacity: true)
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if let marker = openingFenceMarker(in: trimmed) {
                flushMarkdown()
                fenceMarker = marker
                fenceOpeningLine = line
                currentFenceLanguage = parsedFenceLanguage(
                    in: trimmed,
                    marker: marker
                )
                continue
            }

            if let display = sameLineFormula(in: trimmed, opening: "$$", closing: "$$")
                ?? sameLineFormula(in: trimmed, opening: #"\["#, closing: #"\]"#) {
                flushMarkdown()
                blocks.append(.displayMath(display))
                continue
            }

            if trimmed.hasPrefix("$$") {
                flushMarkdown()
                mathClosingDelimiter = "$$"
                let remainder = String(trimmed.dropFirst(2))
                if !remainder.isEmpty {
                    mathLines.append(remainder)
                }
                continue
            }

            if trimmed.hasPrefix(#"\["#) {
                flushMarkdown()
                mathClosingDelimiter = #"\]"#
                let remainder = String(trimmed.dropFirst(2))
                if !remainder.isEmpty {
                    mathLines.append(remainder)
                }
                continue
            }

            markdownLines.append(line)
        }

        if let closing = mathClosingDelimiter {
            markdownLines.append(closing == "$$" ? "$$" : #"\["#)
            markdownLines.append(contentsOf: mathLines)
        }
        if fenceMarker != nil {
            if let fenceOpeningLine {
                markdownLines.append(fenceOpeningLine)
            }
            markdownLines.append(contentsOf: codeLines)
        }
        flushMarkdown()
        return blocks
    }

    private static func openingFenceMarker(in line: String) -> Character? {
        guard let first = line.first, first == "`" || first == "~" else {
            return nil
        }
        return line.prefix(while: { $0 == first }).count >= 3 ? first : nil
    }

    private static func isFenceLine(_ line: String, marker: Character) -> Bool {
        line.prefix(while: { $0 == marker }).count >= 3
    }

    private static func parsedFenceLanguage(
        in line: String,
        marker: Character
    ) -> String? {
        let markerCount = line.prefix(while: { $0 == marker }).count
        let language = line.dropFirst(markerCount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \Character.isWhitespace)
            .first
            .map(String.init)
        return language?.isEmpty == false ? language : nil
    }

    private static func sameLineFormula(
        in line: String,
        opening: String,
        closing: String
    ) -> String? {
        guard line.hasPrefix(opening), line.count >= opening.count + closing.count else {
            return nil
        }
        let bodyStart = line.index(line.startIndex, offsetBy: opening.count)
        guard let closingRange = line.range(of: closing, range: bodyStart..<line.endIndex),
              closingRange.upperBound == line.endIndex
        else {
            return nil
        }
        let formula = String(line[bodyStart..<closingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return formula.isEmpty ? nil : formula
    }
}

enum InlineMathSegment: Equatable {
    case text(String)
    case math(String)
}

struct InlineMathListItem: Equatable {
    let marker: String
    let content: String
    let indentation: Int
}

enum InlineMathMarkdownBlock: Equatable {
    case markdown(String)
    case list([InlineMathListItem])
}

/// Extracts list runs containing inline formulas so bullets and numbering can
/// be retained while the formulas are rendered outside MarkdownUI.
enum InlineMathListParser {
    static func parse(_ content: String) -> [InlineMathMarkdownBlock] {
        let lines = content.components(separatedBy: "\n")
        var blocks: [InlineMathMarkdownBlock] = []
        var markdownLines: [String] = []
        var index = 0

        func flushMarkdown() {
            let markdown = markdownLines.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if !markdown.isEmpty {
                blocks.append(.markdown(markdown))
            }
            markdownLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            guard listItem(from: lines[index]) != nil else {
                markdownLines.append(lines[index])
                index += 1
                continue
            }

            let runStart = index
            var items: [InlineMathListItem] = []
            while index < lines.count, let item = listItem(from: lines[index]) {
                items.append(item)
                index += 1
            }

            let containsFormula = items.contains { item in
                InlineMathParser.parse(item.content).contains { segment in
                    if case .math = segment { return true }
                    return false
                }
            }
            if containsFormula {
                flushMarkdown()
                blocks.append(.list(items))
            } else {
                markdownLines.append(contentsOf: lines[runStart..<index])
            }
        }

        flushMarkdown()
        return blocks
    }

    private static func listItem(from line: String) -> InlineMathListItem? {
        guard let expression = try? NSRegularExpression(
            pattern: #"^(\s*)([-+*]|\d+[.)])\s+(.+)$"#
        ),
        let match = expression.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ),
        let indentationRange = Range(match.range(at: 1), in: line),
        let markerRange = Range(match.range(at: 2), in: line),
        let contentRange = Range(match.range(at: 3), in: line)
        else {
            return nil
        }

        return InlineMathListItem(
            marker: String(line[markerRange]),
            content: String(line[contentRange]),
            indentation: line[indentationRange].reduce(into: 0) { count, character in
                count += character == "\t" ? 4 : 1
            }
        )
    }
}

/// Finds `$...$` formulas without treating escaped dollars, code spans, or prose prices as math.
enum InlineMathParser {
    static func parse(_ content: String) -> [InlineMathSegment] {
        var segments: [InlineMathSegment] = []
        var textStart = content.startIndex
        var index = content.startIndex
        var isInsideCodeSpan = false

        while index < content.endIndex {
            let character = content[index]
            if character == "`" && !isEscaped(index, in: content) {
                isInsideCodeSpan.toggle()
                index = content.index(after: index)
                continue
            }

            guard character == "$", !isInsideCodeSpan,
                  !isEscaped(index, in: content),
                  !isPartOfDoubleDollar(index, in: content),
                  let closing = closingDollar(after: index, in: content)
            else {
                index = content.index(after: index)
                continue
            }

            let formulaStart = content.index(after: index)
            let formula = String(content[formulaStart..<closing])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard looksLikeMath(formula) else {
                index = content.index(after: index)
                continue
            }

            if textStart < index {
                segments.append(.text(String(content[textStart..<index])))
            }
            segments.append(.math(formula))
            index = content.index(after: closing)
            textStart = index
        }

        if textStart < content.endIndex {
            segments.append(.text(String(content[textStart...])))
        }
        return segments.isEmpty ? [.text(content)] : segments
    }

    private static func closingDollar(after opening: String.Index, in content: String) -> String.Index? {
        var index = content.index(after: opening)
        while index < content.endIndex {
            if content[index] == "$",
               !isEscaped(index, in: content),
               !isPartOfDoubleDollar(index, in: content) {
                return index
            }
            index = content.index(after: index)
        }
        return nil
    }

    private static func isPartOfDoubleDollar(_ index: String.Index, in content: String) -> Bool {
        let previousIsDollar = index > content.startIndex
            && content[content.index(before: index)] == "$"
        let next = content.index(after: index)
        let nextIsDollar = next < content.endIndex && content[next] == "$"
        return previousIsDollar || nextIsDollar
    }

    private static func isEscaped(_ index: String.Index, in content: String) -> Bool {
        var cursor = index
        var slashCount = 0
        while cursor > content.startIndex {
            cursor = content.index(before: cursor)
            guard content[cursor] == "\\" else { break }
            slashCount += 1
        }
        return slashCount.isMultiple(of: 2) == false
    }

    private static func looksLikeMath(_ formula: String) -> Bool {
        guard !formula.isEmpty, !formula.contains("\n") else { return false }
        if formula.range(of: #"[\\^_={}+*/<>≤≥∑∫√±]"#, options: .regularExpression) != nil {
            return true
        }
        return formula.range(of: #"^[A-Za-z0-9.(),-]+$"#, options: .regularExpression) != nil
    }
}

/// Renders agent Markdown with the system body font and safe image markup.
struct MarkdownMessageView: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let markdown):
                    markdownView(markdown)
                case .displayMath(let formula):
                    DisplayMathView(formula: formula, fontSize: fontSize + 2)
                case .codeBlock(let language, let code):
                    CopyableCodeBlock(
                        language: language,
                        content: code,
                        fontSize: fontSize
                    )
                }
            }
        }
        .textSelection(.enabled)
        .id(fontSize)
    }

    /// MarkdownUI intentionally displays raw HTML instead of executing it.
    /// Convert image-only HTML emitted by some agents into safe Markdown images.
    private var normalizedContent: String {
        MarkdownMessageNormalizer.normalize(content)
    }

    private var blocks: [MarkdownMessageBlock] {
        MarkdownMathBlockParser.parse(normalizedContent)
    }

    @ViewBuilder
    private func markdownView(_ markdown: String) -> some View {
        let inlineBlocks = InlineMathListParser.parse(markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(inlineBlocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let fragment):
                    markdownFragmentView(fragment)
                case .list(let items):
                    InlineMathListView(items: items, fontSize: fontSize)
                }
            }
        }
    }

    @ViewBuilder
    private func markdownFragmentView(_ markdown: String) -> some View {
        let inlineSegments = InlineMathParser.parse(markdown)
        if isPlainMarkdown(markdown), inlineSegments.contains(where: { segment in
            if case .math = segment { return true }
            return false
        }) {
            InlineMathTextView(segments: inlineSegments, fontSize: fontSize)
        } else {
            Markdown(markdown)
                .markdownTheme(.basic)
                .markdownTextStyle {
                    FontFamily(.system())
                    FontSize(fontSize)
                }
                .lineSpacing(3)
        }
    }

    private func isPlainMarkdown(_ markdown: String) -> Bool {
        markdown.components(separatedBy: "\n").allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            let blockPrefixes = ["#", ">", "- ", "* ", "+ ", "```", "~~~", "|"]
            if blockPrefixes.contains(where: trimmed.hasPrefix) {
                return false
            }
            return trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) == nil
        }
    }
}

private struct InlineMathListView: View {
    let items: [InlineMathListItem]
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayMarker(item.marker))
                        .font(.system(size: fontSize))
                        .frame(minWidth: markerWidth, alignment: .trailing)

                    InlineMathTextView(
                        segments: InlineMathParser.parse(item.content),
                        fontSize: fontSize
                    )
                }
                .padding(.leading, CGFloat(item.indentation / 2) * 12)
            }
        }
    }

    private var markerWidth: CGFloat {
        let longest = items.map(\.marker.count).max() ?? 1
        return CGFloat(longest) * fontSize * 0.65
    }

    private func displayMarker(_ marker: String) -> String {
        ["-", "+", "*"].contains(marker) ? "•" : marker
    }
}

private struct InlineMathTextView: View {
    let segments: [InlineMathSegment]
    let fontSize: CGFloat

    var body: some View {
        composedText
            .font(.system(size: fontSize))
            .lineSpacing(3)
    }

    private var composedText: Text {
        segments.reduce(Text("")) { result, segment in
            switch segment {
            case .text(let markdown):
                return result + markdownText(markdown)
            case .math(let formula):
                if let image = MathFormulaRenderer.image(
                    formula: formula,
                    fontSize: fontSize,
                    mode: .text
                ) {
                    return result + Text(Image(nsImage: image))
                }
                return result + Text("$\(formula)$")
            }
        }
    }

    private func markdownText(_ markdown: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
            return Text(markdown)
        }
        return Text(attributed)
    }
}

private struct CopyableCodeBlock: View {
    let language: String?
    let content: String
    let fontSize: CGFloat
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.lowercased() ?? "code")
                    .font(.system(size: max(10, fontSize - 3), weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    didCopy = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: max(10, fontSize - 2), weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(didCopy ? Color.green : Color.secondary)
                .accessibilityLabel(didCopy ? "Code copied" : "Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.55)

            ScrollView(.horizontal) {
                Text(SyntaxHighlighter.highlight(content, language: language, fontSize: fontSize))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum SyntaxHighlighter {
    static func highlight(
        _ code: String,
        language: String?,
        fontSize: CGFloat
    ) -> AttributedString {
        let attributed = NSMutableAttributedString(string: code)
        let fullRange = NSRange(location: 0, length: attributed.length)
        let font = NSFont(name: AppTypography.monoFamilyName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        attributed.addAttributes(
            [.font: font, .foregroundColor: NSColor.labelColor],
            range: fullRange
        )

        let normalizedLanguage = language?.lowercased() ?? ""
        let keywords = keywordPattern(for: normalizedLanguage)
        apply(#"\b(?:\#(keywords))\b"#, color: .systemBlue, to: attributed)
        apply(#"\b(?:\d+(?:\.\d+)?)\b"#, color: .systemPink, to: attributed)
        apply(
            #"\b(?:def|func|function)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
            color: .systemRed,
            captureGroup: 1,
            to: attributed
        )
        apply(
            #"\b(?:print|sum|len|range|map|filter|reduce)(?=\s*\()"#,
            color: .systemOrange,
            to: attributed
        )
        apply(
            #"(?:\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*')"#,
            color: .systemTeal,
            to: attributed
        )
        apply(#"(?m)#.*$|(?m)//.*$"#, color: .secondaryLabelColor, to: attributed)
        return AttributedString(attributed)
    }

    private static func keywordPattern(for language: String) -> String {
        switch language {
        case "swift":
            return [
                "actor|as|async|await|break|case|catch|class|continue|default|defer|do|else|enum",
                "extension|false|for|func|guard|if|import|in|init|let|nil|private|protocol|public",
                "return|self|struct|switch|throw|throws|true|try|var|while"
            ].joined(separator: "|")
        case "javascript", "js", "typescript", "ts":
            return [
                "async|await|break|case|catch|class|const|continue|default|delete|do|else|export",
                "extends|false|finally|for|function|if|import|in|let|new|null|return|switch|throw",
                "true|try|typeof|undefined|var|while|yield"
            ].joined(separator: "|")
        default:
            return [
                "and|as|assert|async|await|break|class|continue|def|del|elif|else|except|False",
                "finally|for|from|global|if|import|in|is|lambda|None|nonlocal|not|or|pass|raise",
                "return|True|try|while|with|yield"
            ].joined(separator: "|")
        }
    }

    private static func apply(
        _ pattern: String,
        color: NSColor,
        captureGroup: Int = 0,
        to attributed: NSMutableAttributedString
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return
        }
        let fullRange = NSRange(location: 0, length: attributed.length)
        for match in expression.matches(in: attributed.string, range: fullRange) {
            let range = match.range(at: captureGroup)
            if range.location != NSNotFound {
                attributed.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
    }
}

private struct DisplayMathView: View {
    let formula: String
    let fontSize: CGFloat

    var body: some View {
        ScrollView(.horizontal) {
            if let image = MathFormulaRenderer.image(
                formula: formula,
                fontSize: fontSize,
                mode: .display
            ) {
                Image(nsImage: image)
                    .padding(.vertical, 6)
            } else {
                Text("$$\n\(formula)\n$$")
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Math formula: \(formula)")
        .contextMenu {
            Button("Copy formula") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(formula, forType: .string)
            }
        }
    }
}

private enum MathFormulaRenderer {
    static func image(
        formula: String,
        fontSize: CGFloat,
        mode: MTMathUILabelMode
    ) -> NSImage? {
        let renderer = MTMathImage(
            latex: formula,
            fontSize: fontSize,
            textColor: NSColor.labelColor,
            labelMode: mode,
            textAlignment: .left
        )
        return renderer.asImage().1
    }
}
