import SwiftUI

struct VocabularyPane: View {
    @Environment(AppModel.self) private var app
    @State private var newWord = ""
    @State private var find = ""
    @State private var replace = ""
    @Namespace private var chips

    var body: some View {
        SettingsPage {
            Section {
                HStack(spacing: 8) {
                    InsetField(prompt: "Add a name, product or term", text: $newWord, onSubmit: addWord)
                    GlassIconButton(systemImage: "plus", help: "Add word", size: 30, action: addWord)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if !app.vocabulary.words.isEmpty {
                    GlassEffectContainer(spacing: 6) {
                        FlowLayout(spacing: 6) {
                            ForEach(app.vocabulary.words, id: \.self) { word in
                                WordChip(word: word) { app.vocabulary.removeWord(word) }
                                    .glassEffectID(word, in: chips)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .motion(value: app.vocabulary.words)
                }
            } header: {
                Text("Custom Words")
            } footer: {
                Text("Names and jargon Apple Speech and Whisper should spell your way.")
            }

            Section {
                HStack(spacing: 8) {
                    InsetField(prompt: "When Kaze hears…", text: $find, onSubmit: addReplacement)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    InsetField(prompt: "…write", text: $replace, onSubmit: addReplacement)
                    GlassIconButton(systemImage: "plus", help: "Add replacement", size: 30, action: addReplacement)
                        .disabled(find.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                ForEach(app.vocabulary.replacements) { item in
                    ReplacementRow(item: item) { app.vocabulary.removeReplacement(item) }
                }
            } header: {
                Text("Replacements")
            } footer: {
                Text("Fixes a word or phrase in every dictation, e.g. \"kaze app\" → \"Kaze\".")
            }
        }
    }

    private func addWord() {
        app.vocabulary.addWord(newWord)
        newWord = ""
    }

    private func addReplacement() {
        app.vocabulary.addReplacement(find: find, replace: replace)
        find = ""
        replace = ""
    }
}

/// A left-aligned, label-less text field on a quiet inset.
private struct InsetField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.plain)
            .onSubmit(onSubmit)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WordChip: View {
    let word: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(word)
                .font(.callout)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.45)
            .help("Remove")
        }
        .padding(.leading, 11)
        .padding(.trailing, 6)
        .frame(height: 28)
        .glassEffect(.regular, in: .capsule)
        .onHover { hovering = $0 }
        .motion(.kazeQuick, value: hovering)
    }
}

private struct ReplacementRow: View {
    let item: Replacement
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(item.find)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(item.replace.isEmpty ? "removed" : item.replace)
                .foregroundStyle(item.replace.isEmpty ? .tertiary : .primary)
                .italic(item.replace.isEmpty)
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Remove")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .motion(.kazeQuick, value: hovering)
    }
}

/// Wraps children onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += size.width + (row.indices.isEmpty ? 0 : spacing)
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
