import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @State private var hasKey: Bool = false
    @State private var maskedKey: String = ""
    @State private var draft: String = ""
    @State private var codexStatus: AgentProviderAvailability = .loading
    @State private var codexPath: String?
    @FocusState private var isFocused: Bool

    private let consoleURL = URL(string: "https://console.anthropic.com/settings/keys")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: "AI Chat") {
                apiKeySection
                codexSection
            }
            SettingsSection(title: "Integrations") {
                mcpSection
            }
        }
        .onAppear {
            refresh()
            refreshCodex()
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            keyField
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Anthropic API Key")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Use your own API key for AI chat. Stored in the macOS Keychain.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: { NSWorkspace.shared.open(consoleURL, configuration: .init(), completionHandler: nil) }) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text("Get Anthropic API key")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.link)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .pointerStyle(.link)
            }
        }
    }

    private var keyField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            fieldBox
            trailingControl
        }
    }

    private var fieldBox: some View {
        SecureField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .onSubmit(save)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            )
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isFocused)
    }

    private var placeholder: String {
        hasKey ? maskedKey : "sk-ant-…"
    }

    @ViewBuilder
    private var trailingControl: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save", action: save)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help("Remove API key")
        }
    }

    private func refresh() {
        Task { @MainActor in
            let key = await Self.loadKey()
            applyKey(key)
        }
    }

    private func applyKey(_ key: String) {
        hasKey = !key.isEmpty
        maskedKey = mask(key)
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        draft = ""
        isFocused = false
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                AnthropicKeychain.save(key)
            }.value
            applyKey(key)
        }
    }

    private func remove() {
        draft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                AnthropicKeychain.delete()
            }.value
            applyKey("")
        }
    }

    private static func loadKey() async -> String {
        await Task.detached(priority: .utility) {
            AnthropicKeychain.load() ?? ""
        }.value
    }

    private func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
    }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Codex CLI")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Palmier uses your installed Codex CLI and its existing sign-in. Credentials stay with Codex.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill(codexStatus.canSend ? AppTheme.Status.successColor : AppTheme.Status.warningColor)
                    .frame(width: AppTheme.Spacing.smMd, height: AppTheme.Spacing.smMd)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(codexStatusLabel)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    if let codexPath {
                        Text(codexPath)
                            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Button("Choose…", action: chooseCodexExecutable)
                    .buttonStyle(.capsule(.secondary))
                    .help("Choose a Codex executable")
                if CodexExecutablePreference.overrideURL != nil {
                    Button("Use Automatic", action: clearCodexExecutableOverride)
                    .buttonStyle(.capsule(.secondary))
                    .help("Clear the Codex executable override")
                }
                if case .signedOut = codexStatus {
                    Button("Open Terminal") { openCodexLoginInTerminal() }
                        .buttonStyle(.capsule(.prominent))
                        .help("Open Terminal with Codex login instructions")
                }
            }
        }
        .padding(.top, AppTheme.Spacing.md)
    }

    private var codexStatusLabel: String {
        switch codexStatus {
        case .loading: "Checking…"
        case .available: "Installed and signed in"
        case .missingExecutable: "Not found"
        case .signedOut: "Installed, sign-in required"
        case .incompatible: "Incompatible"
        case .failed: "Unavailable"
        }
    }

    private func refreshCodex() {
        codexStatus = .loading
        Task {
            let located = await Task.detached(priority: .utility) {
                CodexExecutableLocator.locate()
            }.value
            codexPath = located.url?.path
            guard located.url != nil else {
                codexStatus = .missingExecutable
                return
            }
            do {
                try await CodexAppServer.shared.start()
                let account = try await CodexAppServer.shared.request(
                    method: "account/read",
                    params: .object(["refreshToken": .bool(false)])
                )
                guard let accountValue = account["account"], accountValue != .null else {
                    codexStatus = .signedOut
                    return
                }
                codexStatus = .available
            } catch CodexAppServerError.malformedResponse, CodexAppServerError.invalidJSON {
                codexStatus = .incompatible("Unsupported app-server response.")
            } catch {
                codexStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Codex"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let status = await Task.detached(priority: .utility) {
                CodexExecutableLocator.locate(
                    overrideURL: url,
                    environment: [:],
                    homeDirectory: URL(fileURLWithPath: "/__no_fallback__")
                )
            }.value
            guard status.url != nil else {
                codexStatus = .failed("The selected file is not executable.")
                return
            }
            await CodexAppServer.shared.shutdown()
            CodexExecutablePreference.overrideURL = url
            refreshCodex()
        }
    }

    private func openCodexLoginInTerminal() {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        )
        let script = "tell application \"Terminal\" to do script \"codex login\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    private func clearCodexExecutableOverride() {
        Task {
            await CodexAppServer.shared.shutdown()
            CodexExecutablePreference.overrideURL = nil
            refreshCodex()
        }
    }

    // MARK: - MCP server

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            mcpHeader
            mcpStatusRow
        }
    }

    private var mcpHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("MCP Server")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Lets external clients like Cursor, Claude Desktop, Claude Code, and Codex edit your timeline.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: openInstructions) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text("Setup instructions")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.link)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .pointerStyle(.link)
            }
        }
    }

    private var mcpStatusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill((appState.mcpService?.isRunning ?? false) ? AppTheme.Status.successColor : AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.Spacing.smMd, height: AppTheme.Spacing.smMd)

                if appState.mcpService?.isRunning ?? false {
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xxs) {
                        Text("Running on")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Text("127.0.0.1:\(String(MCPService.port))")
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                    }
                } else {
                    Text("Stopped")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .font(.system(size: AppTheme.FontSize.sm))

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { (appState.mcpService?.isRunning ?? false) },
                    set: { appState.setMCPEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel("MCP Server")
        }
        .padding(.top, AppTheme.Spacing.xs)
    }

    private func openInstructions() {
        HelpWindowController.shared.show(tab: .mcp)
    }
}
