import SwiftUI
import DSHCore

/// Renders markdown blocks. Everything stays selectable.
struct MarkdownView: View {
    let source: String
    /// Tool cards and results are already code; skip block parsing for them.
    var monospaced = false

    var body: some View {
        if monospaced {
            Text(source)
                .font(Theme.codeFont)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Markdown.parse(source)) { block in
                    BlockView(block: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(Markdown.inline(text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let text):
            Text(Markdown.inline(text))
                .font(headingFont(level))
                .bold()
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let language, let text):
            CodeBlock(language: language, text: text)

        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(Markdown.inline(text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
                Text(Markdown.inline(text))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .body
        }
    }
}

/// A fenced code block with a language tag and copy affordance.
private struct CodeBlock: View {
    let language: String?
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let language {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyToPasteboard(text)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Copy")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(Theme.codeFont)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.surfaceStrong, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A pipe table. Columns size to their content and the whole grid scrolls
/// sideways rather than squeezing the transcript.
private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        Text(Markdown.inline(header.indices.contains(column) ? header[column] : ""))
                            .font(.callout.weight(.semibold))
                    }
                }
                Divider().gridCellColumns(columnCount)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            Text(Markdown.inline(row.indices.contains(column) ? row[column] : ""))
                                .font(.callout)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(10)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
    }
}
