import SwiftUI
import AppKit

// MARK: - Building blocks for the step-by-step guides
//
// The Amazon Bedrock guide is written for someone who has never used the AWS CLI: every page has a
// heading, a plain-language lead, what to do, and — underneath — an aside that explains a term and a
// "stuck?" line that says what to try. These small views keep the pages consistent and short.

enum GuideTone {
    case info, success, warning, error

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .info: .accentColor
        case .success: Theme.successTint
        case .warning: Theme.noticeTint
        case .error: Theme.errorTint
        }
    }
}

/// A page's icon, drawn large above its heading.
struct GuideIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 60, height: 60)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)
    }
}

struct GuideHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
    }
}

struct GuideSubheading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.headline).padding(.top, 4)
    }
}

struct GuideLead: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct GuideParagraph: View {
    let text: String
    var secondary = false
    init(_ text: String, secondary: Bool = false) { self.text = text; self.secondary = secondary }
    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.callout)
            .foregroundStyle(secondary ? .secondary : .primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A coloured callout: a status, a warning, or a thing that went wrong.
struct GuideNote<Extra: View>: View {
    let tone: GuideTone
    var title: String?
    let text: String
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone.symbol).foregroundStyle(tone.tint).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(title).font(.callout.weight(.semibold)) }
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(tone.tint.opacity(0.25)))
    }
}

extension GuideNote where Extra == EmptyView {
    init(_ tone: GuideTone, _ text: String, title: String? = nil) {
        self.init(tone: tone, title: title, text: text, extra: { EmptyView() })
    }
}

extension GuideNote {
    init(_ tone: GuideTone, _ text: String, title: String? = nil, @ViewBuilder extra: @escaping () -> Extra) {
        self.init(tone: tone, title: title, text: text, extra: extra)
    }
}

/// "Working…" with a spinner.
struct GuideBusy: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

/// A selectable card: an icon, a title, a line of detail, a check when chosen.
struct GuideChoice: View {
    let systemImage: String
    let title: String
    let detail: String
    let selected: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium)).multilineTextAlignment(.leading)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Theme.hairline)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.10) : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A labelled control with an optional hint underneath.
struct GuideField<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout.weight(.semibold))
            content()
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Text to copy: a code, a link, a policy — selectable, with a Copy button.
struct GuideCopyable: View {
    let text: String
    var caption: String?
    var monospaced = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption { Text(caption).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            HStack(alignment: .top, spacing: 8) {
                Text(text)
                    .font(monospaced ? Theme.mono(11.5) : .callout)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
        }
    }
}

/// An icon-led list of short points (markdown allowed in the text).
struct GuideBullets: View {
    let items: [(icon: String, text: String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: items[index].icon)
                        .foregroundStyle(.tint)
                        .frame(width: 22)
                    Text(LocalizedStringKey(items[index].text))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A numbered list (markdown allowed in the text).
struct GuideSteps: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.accentColor, in: Circle())
                    Text(LocalizedStringKey(items[index]))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A small explanation of a term — "what does CLI mean?".
struct GuideAside: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label {
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lightbulb").foregroundStyle(.secondary)
        }
    }
}

/// "Stuck?" — what to try when the obvious thing does not work.
struct GuideStuck: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label {
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }
}

/// A text-styled button that looks like a link.
struct GuideLink: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.callout).underline()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}
