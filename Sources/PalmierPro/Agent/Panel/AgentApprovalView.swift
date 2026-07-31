import SwiftUI

struct AgentApprovalView: View {
    let request: AgentApprovalRequest
    let onDecision: (AgentApprovalDecision) -> Void
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: icon)
                    .foregroundStyle(AppTheme.Status.warningColor)
                Text(title)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
            }
            Button {
                showsDetail.toggle()
            } label: {
                Text(request.summary)
                    .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(showsDetail ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(showsDetail ? "Collapse approval details" : "Expand approval details")

            if let reason = request.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(showsDetail ? nil : 2)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Button("Deny") { onDecision(.deny) }
                    .buttonStyle(.capsule(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .help("Deny this Codex request")
                Button("Allow once") { onDecision(.allowOnce) }
                    .buttonStyle(.capsule(.prominent))
                    .help("Allow only this Codex request")
                if request.allowsSessionDecision {
                    Button("Allow for session") { onDecision(.allowForSession) }
                        .buttonStyle(.capsule(.secondary))
                        .help("Allow matching requests for this Codex session")
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .strokeBorder(AppTheme.Status.warningColor.opacity(AppTheme.Opacity.medium))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex approval request")
    }

    private var title: String {
        switch request.kind {
        case .command: "Codex wants to run a command"
        case .fileChange: "Codex wants to change files"
        case .permission: "Codex requests permission"
        case .elicitation: "Codex requests input"
        }
    }

    private var icon: String {
        switch request.kind {
        case .command: "terminal"
        case .fileChange: "doc.badge.ellipsis"
        case .permission: "lock.open"
        case .elicitation: "questionmark.bubble"
        }
    }
}
