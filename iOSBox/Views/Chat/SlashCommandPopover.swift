import SwiftUI

struct SlashCommandPopover: View {
    let query: String
    let presets: [AssistantPreset]
    let onSelectCommand: (SlashPromptCommand) -> Void
    let onSelectPreset: (AssistantPreset) -> Void

    private var filteredCommands: [SlashPromptCommand] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bare = q.hasPrefix("/") ? String(q.dropFirst()) : q
        guard !bare.isEmpty else { return SlashPromptCommand.builtIns }
        return SlashPromptCommand.builtIns.filter {
            $0.command.lowercased().contains(q) ||
                $0.title.lowercased().contains(bare) ||
                $0.subtitle.lowercased().contains(bare)
        }
    }

    private var filteredPresets: [AssistantPreset] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let bare = q.hasPrefix("/") ? String(q.dropFirst()) : q
        guard !bare.isEmpty else { return Array(presets.prefix(5)) }
        return presets.filter { $0.name.lowercased().contains(bare) }
    }

    var body: some View {
        if !filteredCommands.isEmpty || !filteredPresets.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredCommands) { cmd in
                        Button {
                            onSelectCommand(cmd)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: cmd.symbol)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(cmd.command)
                                            .font(.caption.monospaced().weight(.semibold))
                                            .foregroundStyle(Color.accentColor)
                                        Text(cmd.title)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.primary)
                                    }
                                    Text(cmd.subtitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if !filteredPresets.isEmpty {
                        Divider().padding(.horizontal, 10)
                        ForEach(filteredPresets) { preset in
                            Button {
                                onSelectPreset(preset)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(preset.iconEmoji)
                                        .font(.subheadline)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("切换助手 · \(preset.name)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        if !preset.subtitle.isEmpty {
                                            Text(preset.subtitle)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        }
    }
}
