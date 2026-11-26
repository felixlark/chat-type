import AppKit
import AVFoundation
import ApplicationServices
import Combine
import SwiftUI

extension PreferencesView {
    func settingsCard<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: SettingsLayout.cardSpacing) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(SettingsTypography.sectionTitle)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(SettingsTypography.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                content()
            }
            .font(SettingsTypography.body)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func setupRow(title: String, status: SetupStatus) -> some View {
        setupRow(title: title, status: status) {
            EmptyView()
        }
    }

    func compactSetupTile(title: String, status: SetupStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                title,
                systemImage: status.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(SettingsTypography.rowTitle)
            .foregroundStyle(status.isReady ? Color.green : Color.orange)
            Text(status.title)
                .font(SettingsTypography.detail)
                .foregroundStyle(.secondary)
            Text(status.subtitle)
                .font(SettingsTypography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func setupRow<Actions: View>(
        title: String,
        status: SetupStatus,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status.isReady ? .green : .orange)
                .font(.system(size: 14))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsTypography.rowTitle)
                Text(status.title)
                    .font(SettingsTypography.bodyEmphasis)
                Text(status.subtitle)
                    .font(SettingsTypography.detail)
                    .foregroundStyle(.secondary)
                actions()
            }
        }
    }

    func permissionSetupSection(
        title: String,
        status: SetupStatus,
        detail: String?,
        actions: [PermissionRepairAction]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            setupRow(title: title, status: status)

            if let detail, !detail.isEmpty, status.isReady == false {
                Text(detail)
                    .font(SettingsTypography.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(actions) { action in
                        repairActionButton(action)
                    }
                }
            }
        }
    }

    @MainActor
    func performRepairAction(_ action: PermissionRepairAction) {
        switch action.kind {
        case .guidedAccessibilityAccess:
            AccessibilityPermission.guideAccess()
        case .openSettings(let destination):
            _ = destination.open()
        case .refreshStatus:
            permissionRefreshNonce += 1
        }
    }

    @ViewBuilder
    func repairActionButton(_ action: PermissionRepairAction) -> some View {
        switch action.prominence {
        case .primary:
            Button(action.title) {
                performRepairAction(action)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .secondary:
            Button(action.title) {
                performRepairAction(action)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        case .utility:
            Button(action.title) {
                performRepairAction(action)
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
        }
    }
}
