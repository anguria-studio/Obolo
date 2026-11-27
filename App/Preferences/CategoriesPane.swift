import SwiftUI
import OboloCore

/// Preferences → Categories: the category list, its colours and its order.
///
/// The categories belong to the *document*, not the settings — which is why a backup
/// carries the user's own categories, and why every change here goes through `AppModel`
/// rather than being held locally and saved on close.
struct CategoriesPane: View {

    let model: AppModel

    @State private var pendingCategoryDelete: OboloCore.Category?
    /// The category whose name field has the focus: set after an add, so the new row
    /// opens ready to be named.
    @FocusState private var focusedCategory: OboloCore.Category.ID?

    private var categories: [OboloCore.Category] {
        model.document.categories.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        PrefPage(tab: .categories) {
            categoriesSection
        }
        .confirmationDialog(
            pendingCategoryDelete.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(
                get: { pendingCategoryDelete != nil },
                set: { if !$0 { pendingCategoryDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let category = pendingCategoryDelete { deleteCategory(category) }
                pendingCategoryDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingCategoryDelete = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    // MARK: - Categories

    private var categoriesSection: some View {
        PrefSection("Categories") {
            CategoryList(
                categories: categories,
                count: { count(in: $0) },
                canDelete: { canDelete($0) },
                deleteHelp: { deleteHelp($0) },
                focus: $focusedCategory,
                onRename: { rename($0, to: $1) },
                onTint: { setTint($1, on: $0) },
                onDelete: { requestDelete($0) },
                onMove: { move(from: $0, to: $1) }
            )

            PrefButtonRow("Add category", help: "Add a category") { addCategory() }
        } footer: {
            PrefFootnote("Drag a category to change the order. If you delete a category, its subscriptions move to \(fallbackName).")
        }
    }

    // MARK: - Category edits

    private func count(in category: OboloCore.Category) -> Int {
        model.document.subscriptions.count { $0.categoryID == category.id }
    }

    private func rename(_ category: OboloCore.Category, to name: String) {
        mutateCategories { list in
            guard let index = list.firstIndex(where: { $0.id == category.id }) else { return }
            list[index].name = name
        }
    }

    private func setTint(_ tint: CategoryHue, on category: OboloCore.Category) {
        mutateCategories { list in
            guard let index = list.firstIndex(where: { $0.id == category.id }) else { return }
            list[index].tint = tint
        }
    }

    private func addCategory() {
        var list = categories
        let new = OboloCore.Category(
            name: "New category",
            tint: CategoryHue.roundRobin(list.count),
            sortOrder: (list.map(\.sortOrder).max() ?? -1) + 1
        )
        list.append(new)
        model.updateCategories(list)
        // Next turn of the run loop: the row has to exist before its field can take
        // the focus. The field selects its text on the way in, so typing replaces it.
        let id = new.id
        Task { @MainActor in
            await Task.yield()
            focusedCategory = id
        }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var list = categories
        list.move(fromOffsets: offsets, toOffset: destination)
        // `sortOrder` is a position, not an array index, so reordering rewrites it.
        for index in list.indices { list[index].sortOrder = index }
        model.updateCategories(list)
    }

    /// The fallback bucket is where a deleted category's subscriptions go, so it cannot
    /// itself be deleted — and neither can the last one standing.
    ///
    /// Both rules are `StoreDocument.removeCategory`'s, and this only has to agree with
    /// them well enough to disable a button. By ID, never by name: the user may rename
    /// the bucket, and a second category they happen to call "Other" is an ordinary one.
    private func canDelete(_ category: OboloCore.Category) -> Bool {
        category.id != OboloCore.Category.fallbackID
            && category.id != model.document.fallbackCategoryID
            && categories.count > 1
    }

    /// The delete button's tooltip, which for a category that has to stay says why.
    private func deleteHelp(_ category: OboloCore.Category) -> String {
        if canDelete(category) { return "Delete “\(category.name)”" }
        if categories.count <= 1 { return "The last category cannot be deleted." }
        return "Subscriptions from a deleted category move here, so it cannot be deleted."
    }

    private func requestDelete(_ category: OboloCore.Category) {
        guard canDelete(category) else { return }
        pendingCategoryDelete = category
    }

    /// What the bucket is actually called. Read from the document rather than from the
    /// constant, because the user may have renamed it and the alert has to name the place
    /// their subscriptions are really going.
    private var fallbackName: String {
        model.document.category(id: model.document.fallbackCategoryID)?.name
            ?? OboloCore.Category.fallbackName
    }

    private var deleteMessage: String {
        guard let category = pendingCategoryDelete else { return "" }
        let held = count(in: category)
        guard held > 0 else { return "This category has no subscriptions." }
        return held == 1
            ? "Its 1 subscription moves to \(fallbackName)."
            : "Its \(held) subscriptions move to \(fallbackName)."
    }

    private func deleteCategory(_ category: OboloCore.Category) {
        if focusedCategory == category.id { focusedCategory = nil }
        // One call, and the rule stays in `StoreDocument`: which categories may go, and
        // where their subscriptions land. The pane used to hand over a filtered list and
        // let the repair pass sort it out, which meant the "may it go" test lived here
        // as a name comparison as well as there as an ID one.
        model.removeCategory(id: category.id)
    }

    private func mutateCategories(_ change: (inout [OboloCore.Category]) -> Void) {
        var list = categories
        change(&list)
        model.updateCategories(list)
    }
}

// MARK: - Category list

/// The categories as card rows, reordered by dragging a row's grip.
///
/// Drawn by hand rather than as a `List`: a list well is the one thing the card system
/// has no place for. The drag is a plain gesture rather than a pasteboard drag, so
/// nothing can land in a name field, and the rows in between step aside while it moves.
/// The hairlines stay put and only the rows move: each row is exactly one `pitch` from
/// the next, so a row that steps aside lands squarely between two hairlines.
private struct CategoryList: View {
    let categories: [OboloCore.Category]
    let count: (OboloCore.Category) -> Int
    let canDelete: (OboloCore.Category) -> Bool
    let deleteHelp: (OboloCore.Category) -> String
    var focus: FocusState<OboloCore.Category.ID?>.Binding
    let onRename: (OboloCore.Category, String) -> Void
    let onTint: (OboloCore.Category, CategoryHue) -> Void
    let onDelete: (OboloCore.Category) -> Void
    let onMove: (IndexSet, Int) -> Void

    /// Compact like the app's own lists: Home's category list rows.
    static let rowHeight: CGFloat = 32
    private static let pitch: CGFloat = rowHeight
    private static let space = "CategoryList"

    @State private var dragged: OboloCore.Category.ID?
    @State private var dragOffset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sourceIndex: Int? {
        dragged.flatMap { id in categories.firstIndex { $0.id == id } }
    }

    /// Where the dragged row would land if it were let go now.
    private var targetIndex: Int? {
        guard let source = sourceIndex else { return nil }
        let steps = Int((dragOffset / Self.pitch).rounded())
        return min(max(source + steps, 0), categories.count - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                let isDragged = category.id == dragged
                CategoryRow(
                    category: category,
                    count: count(category),
                    canDelete: canDelete(category),
                    deleteHelp: deleteHelp(category),
                    isDragged: isDragged,
                    focus: focus,
                    onRename: { onRename(category, $0) },
                    onTint: { onTint(category, $0) },
                    onDelete: { onDelete(category) },
                    grip: AnyGesture(gripGesture(for: category).map { _ in () })
                )
                .frame(height: Self.rowHeight)
                .offset(y: isDragged ? dragOffset : shift(at: index))
                .zIndex(isDragged ? 1 : 0)
                .animation(isDragged || reduceMotion ? nil : .easeOut(duration: 0.15), value: targetIndex)
                .contextMenu { contextMenu(for: category, at: index) }
                .accessibilityAction(named: "Move up") { step(index, by: -1) }
                .accessibilityAction(named: "Move down") { step(index, by: 1) }
            }
        }
        .padding(.vertical, 6)
        .coordinateSpace(.named(Self.space))
    }

    /// How far a row that is not being dragged steps aside: one pitch towards the gap
    /// the dragged row left, for every row between that gap and where it would land.
    private func shift(at index: Int) -> CGFloat {
        guard let source = sourceIndex, let target = targetIndex else { return 0 }
        if source < target, (source + 1...target).contains(index) { return -Self.pitch }
        if target < source, (target..<source).contains(index) { return Self.pitch }
        return 0
    }

    private func gripGesture(for category: OboloCore.Category) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragged != category.id { dragged = category.id }
                guard let source = sourceIndex else { return }
                // Kept inside the list, so the row cannot be dragged off the card.
                let upper = CGFloat(categories.count - 1 - source) * Self.pitch
                let lower = -CGFloat(source) * Self.pitch
                dragOffset = min(max(value.translation.height, lower), upper)
            }
            .onEnded { _ in
                let source = sourceIndex
                let target = targetIndex
                // No animation: the reorder puts every row where it is already drawn.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if let source, let target, source != target {
                        onMove(IndexSet(integer: source), target > source ? target + 1 : target)
                    }
                    dragged = nil
                    dragOffset = 0
                }
            }
    }

    private func step(_ index: Int, by delta: Int) {
        let target = index + delta
        guard categories.indices.contains(target) else { return }
        onMove(IndexSet(integer: index), delta > 0 ? target + 1 : target)
    }

    @ViewBuilder
    private func contextMenu(for category: OboloCore.Category, at index: Int) -> some View {
        Button("Move Up") { step(index, by: -1) }
            .disabled(index == 0)
        Button("Move Down") { step(index, by: 1) }
            .disabled(index == categories.count - 1)
        if canDelete(category) {
            Divider()
            Button("Delete “\(category.name)”", role: .destructive) { onDelete(category) }
        }
    }
}

// MARK: - One category row

private struct CategoryRow: View {
    let category: OboloCore.Category
    let count: Int
    let canDelete: Bool
    let deleteHelp: String
    let isDragged: Bool
    var focus: FocusState<OboloCore.Category.ID?>.Binding
    let onRename: (String) -> Void
    let onTint: (CategoryHue) -> Void
    let onDelete: () -> Void
    let grip: AnyGesture<Void>

    @State private var isPickingTint = false
    @State private var draftName: String = ""
    @State private var isHoveringGrip = false
    @State private var isHovering = false

    /// Delete and the grip show on the row in hand: hovered, renamed or dragged.
    private var showsControls: Bool { isHovering || isDragged || isNameFocused }

    private var isNameFocused: Bool { focus.wrappedValue == category.id }

    var body: some View {
        HStack(spacing: 12) {
            // A popover of swatches rather than a `Menu` of names: the thing being
            // chosen is a colour, and an AppKit menu renders every glyph in one ink.
            Button { isPickingTint = true } label: {
                CategoryMarker(category.tint, size: 8)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dsFocusRing(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("Change colour")
            .accessibilityLabel("Colour: \(category.tint.displayName)")
            .popover(isPresented: $isPickingTint, arrowEdge: .bottom) {
                TintSwatchGrid(selected: category.tint) { tint in
                    onTint(tint)
                    isPickingTint = false
                }
            }
            .padding(.leading, -6)

            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(DSFonts.font(DSFonts.sansRegular, size: 13))
                .foregroundStyle(DS.Palette.ink)
                .focused(focus, equals: category.id)
                .onSubmit { commit() }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DS.Palette.bg300)
                        .opacity(isNameFocused ? 1 : 0)
                )
                .padding(.horizontal, -6)

            Text(count.formatted())
                .font(DSFonts.font(DSFonts.monoRegular, size: 12))
                .monospacedDigit()
                .foregroundStyle(DS.Palette.inkMuted)
                .accessibilityLabel(count == 1 ? "1 subscription" : "\(count) subscriptions")

            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(RowIconButtonStyle(isDestructive: true))
                .dsFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(showsControls ? 1 : 0)
                .disabled(!canDelete)
                .help(deleteHelp)
                .accessibilityLabel("Delete \(category.name)")

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isDragged || isHoveringGrip ? DS.Palette.ink : DS.Palette.inkDisabled)
                .frame(width: 20, height: 28)
                .opacity(showsControls ? 1 : 0)
                .contentShape(Rectangle())
                .onHover { isHoveringGrip = $0 }
                .pointerStyle(isDragged ? .grabActive : .grabIdle)
                .gesture(grip)
                .help("Drag to change the order")
                .accessibilityHidden(true)
                .padding(.trailing, -4)
        }
        .background {
            // Hover: the quiet fill the app's lists use.
            RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous)
                .fill(isHovering && !isDragged ? DS.Palette.bg300 : .clear)
                .padding(.horizontal, -8)
                .padding(.vertical, 2)
        }
        .onHover { isHovering = $0 }
        .background {
            // The row being dragged is lifted onto its own plate, wider than the row so
            // it reads as picked up, and opaque so the rows under it disappear.
            if isDragged {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Palette.bg300)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(DS.Palette.lineStrong, lineWidth: 1)
                    )
                    .padding(.horizontal, -10)
                    .padding(.vertical, 2)
            }
        }
        .onAppear { draftName = category.name }
        .onDisappear { commit() }
        .onChange(of: focus.wrappedValue) { wasFocused, isFocused in
            if wasFocused == category.id && isFocused != category.id { commit() }
        }
        // A rename that came from somewhere else — a restored backup, an import —
        // has to land in the field the user is looking at.
        .onChange(of: category.name) { _, newValue in
            if newValue != draftName { draftName = newValue }
        }
    }

    private func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != category.name else { return }
        onRename(trimmed)
    }
}

/// The twelve category hues as square swatches, six to a row.
private struct TintSwatchGrid: View {
    let selected: CategoryHue
    let choose: (CategoryHue) -> Void

    private let columns = Array(repeating: GridItem(.fixed(26), spacing: 4), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(CategoryHue.allCases, id: \.self) { tint in
                Button { choose(tint) } label: {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(DS.category(tint))
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .overlay {
                            if tint == selected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(DS.Palette.ink, lineWidth: 1.5)
                            }
                        }
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dsFocusRing(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .help(tint.displayName)
                .accessibilityLabel(tint.displayName)
                .accessibilityAddTraits(tint == selected ? .isSelected : [])
            }
        }
        .padding(10)
    }
}

// MARK: - Preview

#Preview("Categories") {
    CategoriesPane(model: .handoffPreview())
        .frame(width: PrefMetrics.width, height: 620)
}
