import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OboloCore

/// The route every CSV takes into the app.
///
/// Three doors — the Data pane's button, the ⌘I menu item, and a file dropped anywhere
/// on the window — all arrive here, and here they all do the same thing: read the file
/// into an `ImportPreview` and present it. **Nothing is written to the document by this
/// type.** The preview sheet is what applies it, after the user has looked at the table
/// and decided about missing categories.
///
/// An unreadable file, empty table or unrecognized subscription header opens an alert.
@MainActor
enum ImportCoordinator {

    /// The types the panel and the drop destination accept. `.plainText` is in the list
    /// because a `.csv` renamed by a mail client or exported by a spreadsheet often
    /// arrives typed as plain text, and refusing it would be pedantry.
    static let contentTypes: [UTType] = [.commaSeparatedText, .plainText, .text]

    // MARK: - Open panel

    /// Import CSV… — the Data pane's button and the File menu item.
    static func chooseAndPreview(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose a subscription CSV with a name column and either a price or a billing cycle."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        preview(url: url, model: model)
    }

    // MARK: - Drop

    /// `.onDrop(of: [.fileURL], isTargeted:)` — attached to the main window.
    ///
    /// Returns `true` when it took responsibility for a provider, which is what tells
    /// AppKit to accept the drag. The read itself is asynchronous, so the answer is
    /// given before the file has been looked at; a file that turns out not to be a CSV
    /// is reported in the alert rather than by refusing the drop, which would leave the
    /// user watching an item snap back with no explanation.
    @discardableResult
    static func handleDrop(providers: [NSItemProvider], model: AppModel) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in preview(url: url, model: model) }
        }
        return true
    }

    // MARK: - The shared middle

    /// Reads `url` and presents the preview sheet. Errors surface as an alert; the
    /// document is untouched either way.
    static func preview(url: URL, model: AppModel) {
        // A dropped or panel-chosen file is outside the sandbox container, so the
        // read has to happen inside the scope the security scope opens. Panel URLs
        // already carry the grant and answer `false` here, which is not an error.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let preview = try model.previewImport(url: url)
            guard !preview.isEmpty else {
                report(CSVImportError.empty, url: url)
                return
            }
            model.presentImportPreview(preview)
        } catch {
            report(error, url: url)
        }
    }

    // MARK: - Errors

    private static func report(_ error: any Error, url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Obolo cannot import “\(url.lastPathComponent)”"
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
