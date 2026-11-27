import AppKit
import SwiftUI
import OboloCore

/// Shows recovery options in the main window when the app cannot read the data file.
///
/// There is no way to dismiss it, and that is the point. The empty list underneath was
/// made up by the app and every save is blocked while this is up, so the only ways on
/// are the real answers: put a backup in its place, look at the file, or accept the
/// empty list and carry on.
struct RecoveryPanel: View {
    let recovery: AppModel.StoreRecovery
    let model: AppModel

    @State private var isRestoreOpen = false
    @State private var picked: BackupEntry?
    @State private var actionError: String?

    /// Where the file is decides the sentence: a file that could not be moved is the
    /// original, still at the path the app reads on every launch.
    private var message: String {
        switch recovery.fileState {
        case .movedAside:
            "The file was moved aside untouched, so nothing is lost. Restore a backup, or start with an empty list."
        case .leftInPlace:
            "The file was left untouched, so nothing is lost. Restore a backup, or start with an empty list."
        case .newerVersion(let error):
            error.localizedDescription
        }
    }

    private var path: String {
        (recovery.path.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(spacing: 0) {
            WarningIcon()
                .foregroundStyle(DS.Palette.warning)
                .frame(width: 28, height: 28)

            Text(recovery.newerVersion == nil ? "Obolo couldn't read your data" : "Update Obolo to open your data")
                .dsStyle(.heading)
                .foregroundStyle(DS.Palette.ink)
                .padding(.top, 14)

            Text(message)
                .dsStyle(.bodySmall)
                .foregroundStyle(DS.Palette.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Text(path)
                .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                .foregroundStyle(DS.Palette.inkDisabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .padding(.top, 10)

            if let actionError {
                Text(actionError)
                    .font(DSFonts.font(DSFonts.sansRegular, size: 12))
                    .foregroundStyle(DS.Palette.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            HStack(spacing: 8) {
                if recovery.newerVersion == nil {
                    Button("Restore a backup") { isRestoreOpen.toggle() }
                        .buttonStyle(DSPrimaryButtonStyle(height: 32))
                        .dsFocusRing(Capsule())
                        .popover(isPresented: $isRestoreOpen, arrowEdge: .bottom) {
                            RestoreBackupMenu(
                                model: model,
                                picked: $picked,
                                isOpen: $isRestoreOpen,
                                onFailed: { actionError = $0 }
                            )
                        }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([recovery.path])
                }
                .buttonStyle(DSSecondaryButtonStyle(height: 32))
                .dsFocusRing(Capsule())
            }
            .fixedSize()
            .padding(.top, 20)

            if recovery.newerVersion == nil {
                Button("Continue with an empty list", action: carryOn)
                    .buttonStyle(.plain)
                    .font(DSFonts.font(DSFonts.sansRegular, size: 13))
                    .foregroundStyle(DS.Palette.inkMuted)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .dsFocusRing(Capsule())
                    .padding(.top, 10)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsPanel()
        .accessibilityIdentifier("store.recovery")
    }

    /// Continue, which can be refused: the unreadable file has to be out of the store's
    /// path before an empty document is written there.
    private func carryOn() {
        do {
            try model.continueAfterRecovery()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// MARK: - Restore

/// The restore popover, here and in Settings › Data: the backups Obolo keeps, newest
/// first with how many subscriptions each holds, and "Choose a file" for one saved
/// elsewhere. Picking one turns the popover into its confirmation, since a restore
/// replaces everything and cannot be undone.
struct RestoreBackupMenu: View {
    let model: AppModel
    /// The backup being confirmed; `nil` shows the list.
    @Binding var picked: BackupEntry?
    @Binding var isOpen: Bool
    var onRestored: (BackupEntry) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }

    @State private var entries: [BackupEntry] = []
    @State private var isRestoring = false

    var body: some View {
        Group {
            if let picked {
                confirmation(picked)
            } else {
                list
            }
        }
        .frame(width: 320)
        .background(DS.Palette.bg300)
        .onAppear { entries = BackupLibrary.entries(besideStoreAt: model.storeURL) }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Backups")
                .dsLabel()
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

            if entries.isEmpty {
                Text("Obolo has kept no backups on this Mac.")
                    .dsStyle(.bodySmall)
                    .foregroundStyle(DS.Palette.inkMuted)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            ForEach(entries) { entry in
                Button { picked = entry } label: {
                    HStack(spacing: 10) {
                        Text(entry.when(now: model.today, calendar: model.calendar))
                            .font(DSFonts.font(DSFonts.sansRegular, size: 14))
                            .foregroundStyle(DS.Palette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let count = entry.countText {
                            Text(count)
                                .dsStyle(.labelSmall)
                                .foregroundStyle(DS.Palette.inkDisabled)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PopoverRowStyle())
                .dsFocusRing(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            PopoverDivider()

            Button(action: chooseFile) {
                Text("Choose a file")
                    .font(DSFonts.font(DSFonts.sansRegular, size: 14))
                    .foregroundStyle(DS.Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowStyle())
            .dsFocusRing(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(6)
    }

    private func confirmation(_ entry: BackupEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.question(now: model.today, calendar: model.calendar))
                .font(DSFonts.font(DSFonts.sansMedium, size: 15))
                .foregroundStyle(DS.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("It replaces your subscriptions, categories, exchange rates and settings. You can't undo this.")
                .dsStyle(.bodySmall)
                .foregroundStyle(DS.Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { picked = nil }
                    .buttonStyle(DSSecondaryButtonStyle(height: 30))
                    .dsFocusRing(Capsule())
                    .keyboardShortcut(.cancelAction)
                Button { restore(entry) } label: {
                    Text("Restore")
                        .dsStyle(.button)
                        .foregroundStyle(DS.Palette.dangerInk)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Capsule().fill(DS.Palette.danger))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .dsFocusRing(Capsule())
                .disabled(isRestoring)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// Any backup file, through the open panel. The popover may close behind the panel,
    /// so the pick is handed back through the binding and the popover reopened on it.
    private func chooseFile() {
        guard let url = BackupFile.chooseToRestore() else { return }
        picked = BackupLibrary.entry(for: url, isChosenFile: true)
        isOpen = true
    }

    private func restore(_ entry: BackupEntry) {
        isRestoring = true
        Task {
            defer { isRestoring = false }
            do {
                try await model.restore(from: entry.url)
                picked = nil
                isOpen = false
                onRestored(entry)
            } catch let error as AppModel.RecoveryError {
                // Already a whole sentence, about the unreadable file in the way.
                picked = nil
                isOpen = false
                onFailed(error.localizedDescription)
            } catch {
                picked = nil
                isOpen = false
                onFailed("Obolo cannot restore that backup. \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Previews

#Preview("Recovery") {
    let model = AppModel.handoffPreview()
    RecoveryPanel(
        recovery: AppModel.StoreRecovery(
            path: URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support/Obolo/obolo.json"),
            fileState: .leftInPlace,
            error: "The data couldn’t be read."
        ),
        model: model
    )
    .padding(8)
    .frame(width: 640, height: 588)
    .background(DS.Palette.bg100)
}

#Preview("Restore · confirm") {
    @Previewable @State var picked: BackupEntry? = BackupEntry(
        url: URL(fileURLWithPath: "/tmp/backup.json"),
        date: Calendar.current.date(byAdding: .day, value: -1, to: .now)!,
        subscriptionCount: 16
    )
    @Previewable @State var isOpen = true
    RestoreBackupMenu(model: .handoffPreview(), picked: $picked, isOpen: $isOpen)
}

#Preview("Restore · list") {
    @Previewable @State var picked: BackupEntry?
    @Previewable @State var isOpen = true
    RestoreBackupMenu(model: .handoffPreview(), picked: $picked, isOpen: $isOpen)
}
