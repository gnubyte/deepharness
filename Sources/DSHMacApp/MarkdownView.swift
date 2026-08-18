import SwiftUI
import DSHKit

/// Renders markdown blocks. Everything stays selectable.
struct MarkdownView: View {
    let source: String
    /// Tool cards and results are already code; skip block parsing for them.
    var monospaced = false

    var body: some View {
        if monospaced {
            Text(source)
                .font(.system(.callout, design: .monospaced))
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
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
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
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}
