import SwiftUI

// MARK: - Slash Command Autocomplete Dropdown

struct SlashCommandAutocomplete: View {
    let matches: [SlashCommand]
    let selectedIndex: Int
    let onSelect: (SlashCommand) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "command")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Commands")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("↑↓ navigate")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.6))
                Text("↵ select")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .padding(.horizontal, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                            SlashCommandRow(
                                command: command,
                                isSelected: index == selectedIndex
                            )
                            .id(index)
                            .onTapGesture {
                                onSelect(command)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }
                .frame(maxHeight: 240)
                .onChange(of: selectedIndex) { _, newIndex in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 12, y: -4)
    }
}

struct SlashCommandRow: View {
    let command: SlashCommand
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            Image(systemName: iconForCommand(command))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : commandColor(command))
                .frame(width: 28, height: 28)
                .glassEffect(.regular, in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(command.trigger)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)

                if !command.expansion.isEmpty {
                    Text(command.expansion)
                        .font(.system(size: 11))
                        .foregroundStyle(
                            isSelected
                                ? Color.white.opacity(0.7)
                                : Color.secondary
                        )
                        .lineLimit(1)
                }
            }

            Spacer()

            if command.isBuiltIn {
                Text("built-in")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(
                        isSelected ? Color.white.opacity(0.6) : Color.secondary.opacity(0.5)
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Group {
                if isSelected {
                    Color.clear.glassEffect(.regular, in: .capsule)
                }
            }
        )
        .contentShape(Rectangle())
    }

    private func iconForCommand(_ command: SlashCommand) -> String {
        if let customIcon = command.icon, !customIcon.isEmpty {
            return customIcon
        }
        switch command.trigger {
        case "/summarize": return "doc.text"
        case "/explain": return "lightbulb"
        case "/translate": return "globe"
        case "/fix": return "wand.and.stars"
        case "/code": return "chevron.left.forwardslash.chevron.right"
        case "/rewrite": return "pencil.line"
        case "/bullets": return "list.bullet"
        case "/eli5": return "face.smiling"
        case "/pros-cons": return "plusminus"
        case "/clear": return "trash"
        case "/quit": return "power"
        case "/new": return "plus.message"
        default: return "command"
        }
    }

    private func commandColor(_ command: SlashCommand) -> Color {
        switch command.trigger {
        case "/summarize": return .blue
        case "/explain": return .yellow
        case "/translate": return .green
        case "/fix": return .purple
        case "/code": return .orange
        case "/rewrite": return .pink
        case "/bullets": return .cyan
        case "/eli5": return .mint
        case "/pros-cons": return .indigo
        case "/clear": return .red
        case "/quit": return .red
        case "/new": return .green
        default: return .accentColor
        }
    }
}

// MARK: - Commands Management View (Settings Tab / Sidebar Panel)

struct CommandsManagementView: View {
    @ObservedObject var commandManager = SlashCommandManager.shared
    @State private var newTrigger: String = ""
    @State private var newExpansion: String = ""
    @State private var newIcon: String = "command"
    @State private var editingCommand: SlashCommand? = nil
    @State private var editTrigger: String = ""
    @State private var editExpansion: String = ""
    @State private var editIcon: String = "command"
    @State private var isNewIconMenuOpen: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("AppTheme") private var appTheme: AppTheme = .default

    var body: some View {
        VStack(spacing: 0) {
            // Add new command section
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    // Icon picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Icon")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Menu {
                            ForEach(SlashCommand.availableIcons, id: \.symbol) { icon in
                                Button(action: { newIcon = icon.symbol }) {
                                    Label(icon.name, systemImage: icon.symbol)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: newIcon)
                                    .font(.system(size: 14))
                                    .frame(width: 20)
                                Image(systemName: isNewIconMenuOpen ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .focusable(false)
                        .focusEffectDisabled()
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isNewIconMenuOpen.toggle()
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        isNewIconMenuOpen = false
                                    }
                                }
                            })
                    }

                    // Trigger field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text("/")
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            TextField("shortcut", text: $newTrigger)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14, design: .monospaced))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                    }
                    .frame(maxWidth: .infinity)

                    // Expansion field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Expands to")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("What should it type...", text: $newExpansion)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                    }
                    .frame(maxWidth: .infinity)

                    // Add button
                    Button(action: addCommand) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: appTheme.colors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty)
                    .padding(.top, 18)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()
                .padding(.horizontal, 16)

            // Command list
            ScrollView {
                VStack(spacing: 2) {
                    // Custom commands first
                    let custom = commandManager.commands.filter { !$0.isBuiltIn }
                    if !custom.isEmpty {
                        SectionHeader(title: "Custom Commands")
                        ForEach(custom) { cmd in
                            CommandListRow(
                                command: cmd,
                                isEditing: editingCommand?.id == cmd.id,
                                editTrigger: $editTrigger,
                                editExpansion: $editExpansion,
                                editIcon: $editIcon,
                                onEdit: { startEditing(cmd) },
                                onSave: { saveEdit(cmd) },
                                onCancel: { cancelEdit() },
                                onDelete: { commandManager.deleteCommand(id: cmd.id) }
                            )
                        }
                    }

                    // Built-in commands
                    SectionHeader(title: "Built-in Commands")
                    ForEach(commandManager.commands.filter { $0.isBuiltIn }) { cmd in
                        CommandListRow(
                            command: cmd,
                            isEditing: editingCommand?.id == cmd.id,
                            editTrigger: $editTrigger,
                            editExpansion: $editExpansion,
                            editIcon: $editIcon,
                            onEdit: { startEditing(cmd) },
                            onSave: { saveEdit(cmd) },
                            onCancel: { cancelEdit() },
                            onDelete: nil  // can't delete built-ins
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .padding(.top, 44)
    }

    private func addCommand() {
        let trigger = newTrigger.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty else { return }
        commandManager.addCommand(trigger: trigger, expansion: newExpansion, icon: newIcon)
        newTrigger = ""
        newExpansion = ""
        newIcon = "command"
    }

    private func startEditing(_ cmd: SlashCommand) {
        editingCommand = cmd
        editTrigger = cmd.trigger
        editExpansion = cmd.expansion
        editIcon = cmd.icon ?? "command"
    }

    private func saveEdit(_ cmd: SlashCommand) {
        commandManager.updateCommand(
            id: cmd.id, trigger: editTrigger, expansion: editExpansion, icon: editIcon)
        editingCommand = nil
    }

    private func cancelEdit() {
        editingCommand = nil
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

struct CommandListRow: View {
    let command: SlashCommand
    let isEditing: Bool
    @Binding var editTrigger: String
    @Binding var editExpansion: String
    @Binding var editIcon: String
    let onEdit: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: (() -> Void)?
    @State private var isHovered = false
    @State private var isEditIconMenuOpen = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                // Editing mode - icon picker + side by side fields
                HStack(spacing: 8) {
                    // Icon picker
                    Menu {
                        ForEach(SlashCommand.availableIcons, id: \.symbol) { icon in
                            Button(action: { editIcon = icon.symbol }) {
                                Label(icon.name, systemImage: icon.symbol)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: editIcon)
                                .font(.system(size: 13))
                            Image(systemName: isEditIconMenuOpen ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 38, height: 28)
                        .glassEffect(.regular, in: .capsule)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .focusable(false)
                    .focusEffectDisabled()
                    .frame(width: 44)
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isEditIconMenuOpen.toggle()
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isEditIconMenuOpen = false
                                }
                            }
                        })

                    HStack(spacing: 2) {
                        Text("/")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        TextField("command", text: $editTrigger)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxWidth: 160)

                    TextField("Expansion text...", text: $editExpansion)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)

                    Button(action: onSave) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)

                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Display mode
                Image(systemName: iconForCommand(command))
                    .font(.system(size: 13))
                    .foregroundStyle(commandColor(command))
                    .frame(width: 26, height: 26)
                    .glassEffect(.regular, in: .circle)

                Text(command.trigger)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 120, alignment: .leading)

                if SlashCommandManager.actionCommands.contains(command.trigger) {
                    Text(actionDescription(command.trigger))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Text(command.expansion)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if isHovered {
                    HStack(spacing: 6) {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        if let onDelete = onDelete {
                            Button(action: onDelete) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
            Group {
                if isHovered {
                    Color.clear.glassEffect(.regular, in: .capsule)
                }
            }
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private func iconForCommand(_ command: SlashCommand) -> String {
        if let customIcon = command.icon, !customIcon.isEmpty {
            return customIcon
        }
        switch command.trigger {
        case "/summarize": return "doc.text"
        case "/explain": return "lightbulb"
        case "/translate": return "globe"
        case "/fix": return "wand.and.stars"
        case "/code": return "chevron.left.forwardslash.chevron.right"
        case "/rewrite": return "pencil.line"
        case "/bullets": return "list.bullet"
        case "/eli5": return "face.smiling"
        case "/pros-cons": return "plusminus"
        case "/clear": return "trash"
        case "/quit": return "power"
        case "/new": return "plus.message"
        default: return "command"
        }
    }

    private func commandColor(_ command: SlashCommand) -> Color {
        switch command.trigger {
        case "/summarize": return .blue
        case "/explain": return .yellow
        case "/translate": return .green
        case "/fix": return .purple
        case "/code": return .orange
        case "/rewrite": return .pink
        case "/bullets": return .cyan
        case "/eli5": return .mint
        case "/pros-cons": return .indigo
        case "/clear": return .red
        case "/quit": return .red
        case "/new": return .green
        default: return .accentColor
        }
    }

    private func actionDescription(_ trigger: String) -> String {
        switch trigger {
        case "/clear": return "Clears the current chat"
        case "/quit": return "Quits Prism"
        case "/new": return "Creates a new chat session"
        default: return "Action command"
        }
    }
}
