import SwiftUI

struct ProvidersPane: View {
    @Bindable private var credentials = FALCredentialState.shared
    @State private var draft = ""
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    var body: some View {
        SettingsSection(title: "Generation") {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                header
                keyField
                status
            }
        }
        .onAppear(perform: credentials.refresh)
        .onDisappear { draft = "" }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("fal.ai API Key")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Text("Use your own fal.ai account for generation. The key is stored only in the macOS Keychain.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keyField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            SecureField(credentials.hasKey ? "API key stored" : "Enter FAL API key", text: $draft)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .onSubmit(save)
                .disabled(isSaving)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.black.opacity(AppTheme.Opacity.muted))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(
                            isFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                            lineWidth: AppTheme.BorderWidth.thin
                        )
                )
                .animation(.easeOut(duration: AppTheme.Anim.hover), value: isFocused)

            trailingControl
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if !trimmedDraft.isEmpty {
            Button("Save", action: save)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
                .disabled(isSaving)
        } else if credentials.hasKey {
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .disabled(isSaving)
            .help("Remove API key")
        }
    }

    @ViewBuilder
    private var status: some View {
        if let error = credentials.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.Status.errorColor)
        } else if credentials.hasKey {
            Label("Stored in macOS Keychain", systemImage: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.Status.successColor)
        } else {
            Label("No API key stored", systemImage: "key.horizontal")
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let key = trimmedDraft
        guard !key.isEmpty, !isSaving else { return }
        draft = ""
        isFocused = false
        isSaving = true
        Task { @MainActor in
            _ = await credentials.save(key)
            isSaving = false
        }
    }

    private func remove() {
        guard !isSaving else { return }
        draft = ""
        isSaving = true
        Task { @MainActor in
            _ = await credentials.delete()
            isSaving = false
        }
    }
}
