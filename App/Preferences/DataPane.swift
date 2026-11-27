import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OboloCore

/// Preferences → Data: getting the list in, getting it out, and where it lives.
///
/// The distinction the pane has to make clear is between a **CSV**, which is the list of
/// subscriptions in a form a spreadsheet can read, and a **backup**, which is the whole
/// document — settings, categories, rates and all — and is the thing Restore puts back.
struct DataPane: View {

    let model: AppModel

    /// The restore popover, the same one the recovery panel uses.
    @State private var isRestoreOpen = false
    @State private var pickedBackup: BackupEntry?
    @State private var message: String?
    @State private var messageIsError = false
    @State private var showCloudSyncConfirmation = false
    @State private var showCloudAccountConfirmation = false
    @State private var pendingCloudConflict: SyncConflict?
    @State private var cloudSyncActionInProgress = false

    var body: some View {
        PrefPage(tab: .data) {
            cloudSync
            csv
            backup
            store
        }
        .confirmationDialog(
            "Start iCloud sync?",
            isPresented: $showCloudSyncConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Sync") { enableCloudSync() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Obolo first makes a local backup. It then merges this Mac with your private iCloud data. If the same item changed in both places, Obolo asks you which version to keep.")
        }
        .confirmationDialog(
            "Continue with this iCloud account?",
            isPresented: $showCloudAccountConfirmation,
            titleVisibility: .visible
        ) {
            Button("Continue") { approveCloudAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Obolo first makes a new local backup. It then merges the data on this Mac with the private Obolo data in the current iCloud account.")
        }
        .confirmationDialog(
            pendingCloudConflict.map(conflictTitle) ?? "Resolve sync conflict?",
            isPresented: Binding(
                get: { pendingCloudConflict != nil },
                set: { if !$0 { pendingCloudConflict = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Keep This Mac") { resolvePendingConflict(.local) }
            Button("Use iCloud") { resolvePendingConflict(.remote) }
            Button("Cancel", role: .cancel) { pendingCloudConflict = nil }
        } message: {
            if let conflict = pendingCloudConflict {
                Text("This Mac: \(conflictValue(conflict.local))\n\niCloud: \(conflictValue(conflict.remote))")
            }
        }
    }

    // MARK: - CSV

    private var csv: some View {
        PrefSection("Spreadsheet") {
            PrefRow(
                "Import CSV",
                "Obolo reads your own export or an export from this app. You see each row before Obolo adds it."
            ) {
                Button("Import") { ImportCoordinator.chooseAndPreview(model: model) }
                    .prefButton()
            }

            PrefRow(
                "Export CSV",
                "Obolo exports each field, including the fields that a spreadsheet has no column for."
            ) {
                Button("Export") { exportCSV() }
                    .prefButton()
            }
        } footer: {
            PrefFootnote("You can also drop a CSV anywhere on the Obolo window.")
        }
    }

    // MARK: - Backup

    private var backup: some View {
        PrefSection("Backup") {
            PrefRow(
                "Back up",
                "Obolo writes the full document to one file: subscriptions, categories, rates and all settings."
            ) {
                Button("Back up") { backUp() }
                    .prefButton()
            }

            PrefRow(
                "Restore",
                "Obolo replaces all your current data with the contents of a backup."
            ) {
                Button("Restore", role: .destructive) { isRestoreOpen.toggle() }
                    .prefButton(destructive: true)
                    .popover(isPresented: $isRestoreOpen, arrowEdge: .bottom) {
                        RestoreBackupMenu(
                            model: model,
                            picked: $pickedBackup,
                            isOpen: $isRestoreOpen,
                            onRestored: { entry in
                                report("Obolo restored \(itemCountTitle) from \(entry.isChosenFile ? entry.url.lastPathComponent : "the backup").")
                            },
                            onFailed: { report($0, isError: true) }
                        )
                    }
            }
        } footer: {
            PrefFootnote("A backup does not include the logos. Fetch the logos again after a restore.")
        }
    }

    // MARK: - iCloud

    private var cloudSync: some View {
        PrefSection("iCloud") {
            PrefRow(
                "Sync with iCloud",
                "Keep subscriptions, categories, manual rates and selected data settings in your private iCloud database."
            ) {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { model.isCloudSyncEnabled },
                    set: { enabled in
                        if enabled {
                            showCloudSyncConfirmation = true
                        } else {
                            disableCloudSync()
                        }
                    }
                ))
                .prefSwitch()
                .disabled(cloudSyncActionInProgress || model.storeRecovery != nil)
                .accessibilityIdentifier("data.cloudSyncToggle")
            }

            // The sync's details, only while there is a sync to describe: on, or a
            // start that failed and still has something to say.
            if cloudSyncIsActive {
                PrefRow("Status") {
                    HStack(spacing: 8) {
                        if cloudSyncShowsProgress {
                            ProgressView()
                                .controlSize(.small)
                        }
                        PrefValue(cloudSyncStatusText)
                    }
                }

                if let date = model.cloudSyncStatus.lastSuccessfulSyncAt {
                    PrefRow("Last successful sync") {
                        PrefValue(date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            if let backupURL = model.cloudSyncBackupURL {
                PrefRow("Safety backup", backupURL.lastPathComponent, isMonoDescription: true) {
                    showInFinderButton(backupURL)
                }
            }

            ForEach(model.cloudSyncStatus.conflicts) { conflict in
                PrefRow(conflictTitle(conflict), "Select the version that Obolo must keep.") {
                    Button("Review") { pendingCloudConflict = conflict }
                        .prefButton()
                }
            }

            // An account change, a removed private zone, or a sync state that Obolo
            // cannot read. The footnote says which.
            if model.cloudSyncStatus.requiresAccountApproval {
                PrefRow(
                    "Sync is paused",
                    "Check the current iCloud account before you continue."
                ) {
                    Button("Continue") { showCloudAccountConfirmation = true }
                        .prefButton()
                        .disabled(cloudSyncActionInProgress)
                }
            } else if model.cloudSyncStatus.phase == .paused {
                PrefRow(
                    "Sync is paused",
                    "Check your iCloud account or network connection."
                ) {
                    Button("Try Again") { retryCloudSync() }
                        .prefButton()
                        .disabled(cloudSyncActionInProgress)
                }
            } else if cloudSyncHasUnappliedChanges {
                // The note below says why: a newer schema, or a save that failed.
                PrefRow(
                    "iCloud changes did not apply",
                    "Check the note below, then try again."
                ) {
                    Button("Try Again") { retryCloudSync() }
                        .prefButton()
                        .disabled(cloudSyncActionInProgress)
                }
            }
        } footer: {
            ForEach(Array(cloudSyncLines.enumerated()), id: \.offset) { _, line in
                PrefFootnote(line.text, isError: line.isError)
            }
        }
    }

    private var cloudSyncIsActive: Bool {
        model.isCloudSyncEnabled || model.cloudSyncStatus.phase != .disabled
    }

    /// A remote batch did not apply while the session itself works ("Needs attention"
    /// under a syncing or current status). Try Again starts a new session, and the start
    /// gives the kept batch to the app again.
    private var cloudSyncHasUnappliedChanges: Bool {
        guard model.cloudSyncRemoteChangesError != nil else { return false }
        return model.cloudSyncStatus.phase == .syncing
            || model.cloudSyncStatus.phase == .current
    }

    private var cloudSyncShowsProgress: Bool {
        guard !model.cloudSyncNeedsAttention else { return false }
        return model.cloudSyncStatus.phase == .preparing
            || model.cloudSyncStatus.phase == .syncing
    }

    private var cloudSyncStatusText: String {
        if model.cloudSyncNeedsAttention { return "Needs attention" }
        return switch model.cloudSyncStatus.phase {
        case .disabled: "Off"
        case .preparing: "Preparing"
        case .syncing:
            model.cloudSyncStatus.pendingChangeCount == 0
                ? "Syncing"
                : "Syncing \(model.cloudSyncStatus.pendingChangeCount) changes"
        case .current: "Up to date"
        case .paused: "Paused"
        case .failed: "Needs attention"
        }
    }

    private var cloudSyncLines: [(text: String, isError: Bool)] {
        // The status message and the errors the model recorded, once each
        // (`AppModel.cloudSyncNotes`).
        var lines = model.cloudSyncNotes.map { (text: $0.text, isError: $0.isError) }
        lines.append((
            "Turning sync off keeps the data on this Mac and in iCloud.",
            false
        ))
        return lines
    }

    private func enableCloudSync() {
        cloudSyncActionInProgress = true
        Task {
            defer { cloudSyncActionInProgress = false }
            do {
                try await model.enableCloudSync()
            } catch {
                report(error.localizedDescription, isError: true)
            }
        }
    }

    private func disableCloudSync() {
        cloudSyncActionInProgress = true
        Task {
            await model.disableCloudSync()
            cloudSyncActionInProgress = false
        }
    }

    private func approveCloudAccount() {
        cloudSyncActionInProgress = true
        Task {
            defer { cloudSyncActionInProgress = false }
            do {
                try await model.approveCurrentCloudSyncAccount()
            } catch {
                report(error.localizedDescription, isError: true)
            }
        }
    }

    private func retryCloudSync() {
        cloudSyncActionInProgress = true
        Task {
            await model.retryCloudSync()
            cloudSyncActionInProgress = false
        }
    }

    private func resolvePendingConflict(_ choice: SyncConflictChoice) {
        guard let conflict = pendingCloudConflict else { return }
        pendingCloudConflict = nil
        Task {
            await model.resolveCloudSyncConflict(conflict.recordID, choice: choice)
        }
    }

    private func conflictTitle(_ conflict: SyncConflict) -> String {
        switch conflict.local ?? conflict.remote ?? conflict.base {
        case .subscription(let subscription):
            return "Subscription: \(subscription.name)"
        case .category(let category):
            return "Category: \(category.name)"
        case .preferences:
            return "Data settings"
        case .manualRate(let currency, _):
            return "Exchange rate: \(currency)"
        case nil:
            return "Deleted item"
        }
    }

    private func conflictValue(_ record: SyncRecord?) -> String {
        switch record {
        case .subscription(let subscription):
            return "\(subscription.name), \(subscription.currency) \(subscription.price)"
        case .category(let category):
            return category.name
        case .preferences(let value):
            return "Base currency \(value.preferences.baseCurrency)"
        case .manualRate(let currency, let rate):
            return "\(currency) \(rate.value)"
        case nil:
            return "Deleted"
        }
    }

    // MARK: - Store

    private var store: some View {
        PrefSection("On this Mac") {
            PrefRow(
                itemCountTitle,
                "\(model.document.categories.count) categories · \(model.document.rates.rates.count) exchange rate\(model.document.rates.rates.count == 1 ? "" : "s")"
            )

            PrefRow("Stored at", model.storeURL.path(percentEncoded: false), isMonoDescription: true) {
                showInFinderButton(model.storeURL)
            }

            // The same state the main window's banner shows, for the user who opened
            // Settings to look for it. The banner carries the actions; this row carries
            // the file, because this is the pane about where the data lives.
            if let recovery = model.storeRecovery {
                PrefRow(
                    recovery.fileState == .movedAside
                        ? "Unreadable file moved to"
                        : "Unreadable file left at",
                    recovery.path.path(percentEncoded: false),
                    isMonoDescription: true
                ) {
                    showInFinderButton(recovery.path)
                }
                .accessibilityIdentifier("data.recoveryRow")
            }
        } footer: {
            // The save error is the one piece of app state with nowhere else to go: the
            // app keeps running on the in-memory document, so without a line here a
            // failed write is silent.
            ForEach(Array(storeLines.enumerated()), id: \.offset) { _, line in
                PrefFootnote(line.text, isError: line.isError)
            }
        }
    }

    private var storeLines: [(text: String, isError: Bool)] {
        var lines: [(text: String, isError: Bool)] = []
        if let recovery = model.storeRecovery {
            lines.append((
                "Obolo could not read your data. \(recovery.error) Obolo saves nothing until you restore a backup or select Continue in the main window.",
                true
            ))
        }
        if let saveError = model.saveError { lines.append((saveError, true)) }
        if let deviceStateError = model.deviceStateError {
            lines.append((deviceStateError, true))
        }
        if let message { lines.append((message, messageIsError)) }
        return lines
    }

    /// The button on each row whose description is a file.
    private func showInFinderButton(_ url: URL) -> some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .prefButton()
    }

    private var itemCountTitle: String {
        let count = model.document.subscriptions.count
        return count == 1 ? "1 subscription" : "\(count) subscriptions"
    }

    // MARK: - Actions

    /// The File menu's panel and write (`CSVExportPanel`), with the result reported
    /// in this pane instead of in an alert.
    private func exportCSV() {
        do {
            guard let url = try CSVExportPanel.export(model: model) else { return }
            report("Obolo exported \(itemCountTitle) to \(url.lastPathComponent).")
        } catch {
            report("Obolo cannot export the file. \(error.localizedDescription)", isError: true)
        }
    }

    private func backUp() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Obolo \(Date().formatted(.iso8601.year().month().day())).json"
        panel.prompt = "Back up"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                // Flushes the debounced save first, so the backup is what is on screen
                // rather than what was on screen 250 ms ago.
                try await model.backup(to: url)
                report("Obolo wrote the backup to \(url.lastPathComponent).")
            } catch let error as AppModel.RecoveryError {
                // Already a whole sentence about why there is nothing to back up. The
                // "Obolo cannot write the backup" preamble below would only bury it.
                report(error.localizedDescription, isError: true)
            } catch {
                report("Obolo cannot write the backup. \(error.localizedDescription)", isError: true)
            }
        }
    }

    private func report(_ text: String, isError: Bool = false) {
        message = text
        messageIsError = isError
    }
}

// MARK: - Parts

/// The open panel behind "Choose a file" in the restore popover, which this pane and
/// the main window's recovery panel share. One place, so the two cannot come to offer
/// different file types or a different prompt.
enum BackupFile {
    @MainActor
    static func chooseToRestore() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Restore"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

// MARK: - Preview

#Preview("Data") {
    DataPane(model: .handoffPreview())
        .frame(width: PrefMetrics.width, height: 700)
}
