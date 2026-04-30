import SwiftUI

// MARK: - Models

private struct HelpSection: Identifiable {
    let id = UUID()
    let title: String
    let body: AttributedString
}

// MARK: - Markdown loader / parser

private enum HelpMarkdown {

    static func load() -> String {
        guard let url = Bundle.main.url(forResource: "Help", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return stripHTMLComments(raw)
    }

    private static func stripHTMLComments(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<!--"),
              let end = result.range(of: "-->", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sections(from markdown: String) -> [HelpSection] {
        let lines = markdown.components(separatedBy: "\n")
        var sections: [HelpSection] = []
        var currentTitle = ""
        var currentBody: [String] = []

        func flush() {
            let bodyText = currentBody.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if currentTitle.isEmpty && bodyText.isEmpty { return }
            sections.append(HelpSection(title: currentTitle, body: parseInline(bodyText)))
        }

        for line in lines {
            if line.hasPrefix("## ") {
                flush()
                currentTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentBody = []
            } else {
                currentBody.append(line)
            }
        }
        flush()
        return sections
    }

    private static func parseInline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attr = try? AttributedString(markdown: text, options: options) {
            return attr
        }
        return AttributedString(text)
    }
}

// MARK: - View

struct HelpView: View {
    private let sections: [HelpSection] = HelpMarkdown.sections(from: HelpMarkdown.load())

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if !section.title.isEmpty {
                            Text(section.title)
                                .font(.title3.bold())
                                .padding(.top, 4)
                        }
                        Text(section.body)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 500, height: 650)
    }
}

#Preview { HelpView() }
