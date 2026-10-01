import Foundation

/// Writing-script variant of a TTML's lyrics. Apple TTML keeps one script in the
/// `<p>` body and embeds the other as word-timed replacement text under
/// `<translations>`, keyed to each line's `itunes:key`.
enum LyricScript: String, CaseIterable, Sendable {
    case original
    case simplified
    case traditional

    /// Maps a BCP-47 tag like `zh-Hans-CN` or `zh-TW` to a script variant.
    /// Foreign-language replacements are real translations, not script variants.
    init?(languageTag: String) {
        let tag = languageTag.lowercased()
        func matches(_ roots: String...) -> Bool {
            roots.contains { tag == $0 || tag.hasPrefix($0 + "-") }
        }
        if matches("zh-hans", "zh-cn", "zh-sg", "zh-my") {
            self = .simplified
        } else if matches("zh-hant", "zh-tw", "zh-hk", "zh-mo") {
            self = .traditional
        } else {
            return nil
        }
    }
}

/// A language track actually carried by the file. An untagged body is original.
struct LyricLanguage: Hashable, Identifiable, Sendable {
    static let original = LyricLanguage(languageTag: nil)
    let languageTag: String?
    var id: String { languageTag ?? "original" }

    init(languageTag: String?) {
        let tag = languageTag?.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").lowercased()
        self.languageTag = tag?.isEmpty == false ? tag : nil
    }
}

struct ParsedTTML: Sendable {
    let lines: [LyricLine]
    /// Scripts this file can render: the body plus every mapped replacement block.
    let availableScripts: [LyricScript]
    var availableLanguages: [LyricLanguage] = [.original]
    var selectedLanguage: LyricLanguage = .original
}

/// Reads the timed text in a local TTML file into the same line/word model as KSC and enhanced LRC.
/// Metadata, translations and romanization are auxiliary tracks, not part of the sung line.
enum TTMLLyricsParser {
    static func parse(_ data: Data, script: LyricScript = .original, languageTag: String? = nil) -> ParsedTTML {
        let document = Document()
        let parser = XMLParser(data: data)
        parser.delegate = document
        parser.shouldResolveExternalEntities = false
        guard parser.parse(),
              let root = document.root.children.first(where: { $0.name == "tt" }),
              let body = root.children.first(where: { $0.name == "body" }) else {
            return ParsedTTML(lines: [], availableScripts: [.original])
        }

        var paragraphs: [Element] = []
        findParagraphs(in: body, into: &paragraphs)
        let duetSides = performerSides(in: root, paragraphs: paragraphs)
        let bodyLanguage = LyricLanguage(languageTag: body.attributes["lang"] ?? root.attributes["lang"])
        let replacements = replacementTexts(in: root, paragraphs: paragraphs)
        let availableLanguages = [bodyLanguage] + replacements.keys.sorted()
            .map { LyricLanguage(languageTag: $0) }.filter { $0 != bodyLanguage }
        let requestedLanguage = LyricLanguage(languageTag: languageTag)
        let selectedLanguage: LyricLanguage
        if languageTag != nil {
            selectedLanguage = availableLanguages.contains(requestedLanguage) ? requestedLanguage : bodyLanguage
        } else if script != .original,
                  let matchingLanguage = availableLanguages.first(where: {
                      $0.languageTag.flatMap(LyricScript.init(languageTag:)) == script
                  }) {
            selectedLanguage = matchingLanguage
        } else {
            selectedLanguage = bodyLanguage
        }
        let lines = paragraphs.enumerated().compactMap { index, paragraph -> (Int, LyricLine)? in
            // Replacement text reuses the line's own timing and performer, so
            // lines without a matching entry simply keep the original words.
            var source = paragraph
            if selectedLanguage != bodyLanguage,
               let key = paragraph.attributes["key"],
               let replacement = replacements[selectedLanguage.id]?[key] {
                source = replacedParagraph(for: paragraph, with: replacement)
            }
            guard let line = line(from: source, duetSide: source.attributes["agent"].flatMap { duetSides[$0] }) else { return nil }
            return (index, line)
        }.sorted {
            $0.1.startTime == $1.1.startTime ? $0.0 < $1.0 : $0.1.startTime < $1.1.startTime
        }.map(\.1)
        let availableScripts = LyricScript.allCases.filter { candidate in
            candidate == .original || availableLanguages.contains {
                $0.languageTag.flatMap(LyricScript.init(languageTag:)) == candidate
            }
        }
        return ParsedTTML(lines: lines, availableScripts: availableScripts,
                          availableLanguages: availableLanguages, selectedLanguage: selectedLanguage)
    }

    private static func replacementTexts(in root: Element, paragraphs: [Element]) -> [String: [String: Element]] {
        guard let head = root.children.first(where: { $0.name == "head" }) else { return [:] }
        var blocks: [Element] = []
        findElements(named: "translations", in: head, into: &blocks)
        let keyedParagraphs = Dictionary(paragraphs.compactMap { paragraph in
            paragraph.attributes["key"].map { ($0, paragraph) }
        }, uniquingKeysWith: { first, _ in first })
        var result: [String: [String: Element]] = [:]
        for block in blocks {
            for translation in block.children where translation.name == "translation" {
                guard translation.attributes["type"] == "replacement",
                      let lang = translation.attributes["lang"],
                      let target = LyricLanguage(languageTag: lang).languageTag else { continue }
                for text in translation.children where text.name == "text" {
                    if let key = text.attributes["for"], let paragraph = keyedParagraphs[key],
                       line(from: replacedParagraph(for: paragraph, with: text), duetSide: nil) != nil {
                        result[target, default: [:]][key] = text
                    }
                }
            }
        }
        return result
    }

    private static func replacedParagraph(for paragraph: Element, with text: Element) -> Element {
        let replacement = Element(name: "p", attributes: paragraph.attributes)
        replacement.parts = text.parts
        return replacement
    }

    private static func findElements(named name: String, in element: Element, into found: inout [Element]) {
        for child in element.children {
            if child.name == name { found.append(child) }
            else { findElements(named: name, in: child, into: &found) }
        }
    }

    private static func findParagraphs(in element: Element, into paragraphs: inout [Element]) {
        for child in element.children {
            if child.name == "p" { paragraphs.append(child) }
            else { findParagraphs(in: child, into: &paragraphs) }
        }
    }

    private static func performerSides(in root: Element, paragraphs: [Element]) -> [String: LyricDuetSide] {
        let referenced = Set(paragraphs.compactMap { $0.attributes["agent"] })
        guard referenced.count >= 2 else { return [:] }

        var agents: [Element] = []
        if let head = root.children.first(where: { $0.name == "head" }) {
            findAgents(in: head, into: &agents)
        }
        let groupIDs = Set(agents.filter { $0.attributes["type"] == "group" }.compactMap { $0.attributes["id"] })
        let eligible = referenced.filter { !groupIDs.contains($0) && $0 != "v1000" }
        guard eligible.count >= 2 else { return [:] }

        // Performer definitions give the stable v1/v2 order even if v2 sings first.
        var ordered = agents.compactMap { $0.attributes["id"] }.filter { eligible.contains($0) }
        ordered.append(contentsOf: eligible.filter { !ordered.contains($0) }.sorted())
        guard ordered.count >= 2 else { return [:] }
        return [ordered[0]: .left, ordered[1]: .right]
    }

    private static func findAgents(in element: Element, into agents: inout [Element]) {
        for child in element.children {
            if child.name == "agent" { agents.append(child) }
            else { findAgents(in: child, into: &agents) }
        }
    }

    private static func line(from paragraph: Element, duetSide: LyricDuetSide?) -> LyricLine? {
        var pieces: [Piece] = []
        collect(paragraph, inheritedTiming: nil, into: &pieces)
        guard !pieces.isEmpty else { return nil }

        // Whitespace between timed spans is part of the line; formatting newlines are not.
        let text = pieces.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let timedPieces = pieces.filter { $0.timing != nil }
        let start = time(paragraph.attributes["begin"]) ?? timedPieces.compactMap { $0.timing?.start }.min()
        guard let start, start.isFinite, start >= 0 else { return nil }
        let explicitEnd = endTime(of: paragraph.attributes, start: start)
        let lastTimedEnd = timedPieces.compactMap { $0.timing?.end }.max()
        let end = explicitEnd ?? lastTimedEnd
        guard end == nil || end! >= start else { return nil }

        var segments: [LyricTimingSegment] = []
        var pendingPrefix = ""
        var allTextTimed = !timedPieces.isEmpty
        for piece in pieces {
            if let timing = piece.timing {
                guard timing.start >= start, timing.end >= timing.start else {
                    allTextTimed = false
                    break
                }
                segments.append(LyricTimingSegment(
                    text: pendingPrefix + piece.text,
                    startOffset: timing.start - start,
                    duration: timing.end - timing.start
                ))
                pendingPrefix = ""
            } else if piece.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if segments.isEmpty { pendingPrefix += piece.text }
                else {
                    let previous = segments.removeLast()
                    segments.append(LyricTimingSegment(
                        text: previous.text + piece.text,
                        startOffset: previous.startOffset,
                        duration: previous.duration
                    ))
                }
            } else {
                allTextTimed = false
            }
        }
        if !pendingPrefix.isEmpty, !segments.isEmpty {
            let first = segments.removeFirst()
            segments.insert(LyricTimingSegment(
                text: pendingPrefix + first.text,
                startOffset: first.startOffset,
                duration: first.duration
            ), at: 0)
        }
        if allTextTimed && !segments.isEmpty {
            // Keep the karaoke renderer's invariant: segment text must exactly equal line text.
            let leading = segments[0].text.prefix(while: { $0.isWhitespace }).count
            if leading > 0 {
                let first = segments.removeFirst()
                segments.insert(LyricTimingSegment(
                    text: String(first.text.dropFirst(leading)),
                    startOffset: first.startOffset,
                    duration: first.duration
                ), at: 0)
            }
            let trailing = segments[segments.count - 1].text.reversed().prefix(while: { $0.isWhitespace }).count
            if trailing > 0 {
                let last = segments.removeLast()
                segments.append(LyricTimingSegment(
                    text: String(last.text.dropLast(trailing)),
                    startOffset: last.startOffset,
                    duration: last.duration
                ))
            }
        }
        if segments.map(\.text).joined() != text { allTextTimed = false }
        return LyricLine(text: text, startTime: start, endTime: end,
                         timingSegments: allTextTimed ? segments : nil, duetSide: duetSide)
    }

    private static func collect(_ element: Element, inheritedTiming: Timing?, into pieces: inout [Piece]) {
        let role = element.attributes["role"]
        if role == "x-translation" || role == "x-roman" { return }
        // Ruby annotation text is pronunciation, while the base is already in the sung line.
        if element.attributes["ruby"] == "text" || element.attributes["ruby"] == "textContainer" { return }
        let timing: Timing?
        if element.name == "span", let begin = time(element.attributes["begin"]),
           let end = endTime(of: element.attributes, start: begin), end >= begin {
            timing = Timing(start: begin, end: end)
        } else {
            timing = inheritedTiming
        }
        for part in element.parts {
            switch part {
            case .text(let raw):
                if raw.contains("\n") && raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let normalized = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                if !normalized.isEmpty { pieces.append(Piece(text: normalized, timing: element.name == "p" ? nil : timing)) }
            case .child(let child):
                collect(child, inheritedTiming: timing, into: &pieces)
            }
        }
    }

    private static func endTime(of attributes: [String: String], start: TimeInterval) -> TimeInterval? {
        if let end = time(attributes["end"]) { return end }
        if let duration = time(attributes["dur"]) { return start + duration }
        return nil
    }

    private static func time(_ raw: String?) -> TimeInterval? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let result: Double?
        if value.hasSuffix("ms") {
            result = Double(value.dropLast(2)).map { $0 / 1000 }
        } else if value.hasSuffix("s") {
            result = Double(value.dropLast())
        } else {
            let fields = value.split(separator: ":", omittingEmptySubsequences: false)
            if fields.count == 3, let hours = Double(fields[0]), let minutes = Double(fields[1]),
               let seconds = Double(fields[2]), minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 {
                result = hours * 3600 + minutes * 60 + seconds
            } else if fields.count == 2, let minutes = Double(fields[0]),
                      let seconds = Double(fields[1]), seconds >= 0, seconds < 60 {
                result = minutes * 60 + seconds
            } else if fields.count == 1 {
                result = Double(value)
            } else {
                result = nil
            }
        }
        guard let result, result.isFinite, result >= 0 else { return nil }
        return result
    }

    private struct Timing { let start: TimeInterval; let end: TimeInterval }
    private struct Piece { let text: String; let timing: Timing? }

    private final class Element {
        enum Part { case text(String), child(Element) }
        let name: String
        let attributes: [String: String]
        var parts: [Part] = []
        var children: [Element] { parts.compactMap { if case .child(let child) = $0 { child } else { nil } } }

        init(name: String, attributes: [String: String] = [:]) {
            self.name = name
            self.attributes = attributes
        }
    }

    private final class Document: NSObject, XMLParserDelegate {
        let root = Element(name: "document")
        private var stack: [Element] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            let attributes = Dictionary(attributeDict.map { (String($0.key.split(separator: ":").last ?? ""), $0.value) },
                                        uniquingKeysWith: { first, _ in first })
            let element = Element(name: String(elementName.split(separator: ":").last ?? ""), attributes: attributes)
            (stack.last ?? root).parts.append(.child(element))
            stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.parts.append(.text(string))
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let text = String(data: CDATABlock, encoding: .utf8) { stack.last?.parts.append(.text(text)) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if !stack.isEmpty { stack.removeLast() }
        }
    }
}
