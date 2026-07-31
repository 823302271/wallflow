import AppKit
import CoreGraphics

final class WallpaperLibraryWindowController: NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate {
    private struct Row {
        let entry: WallpaperLibraryEntry?
        let title: String
        let kind: String
        let source: String
        /// Normalized source token for assignment comparison.
        let sourceToken: String
        let isAvailable: Bool
        /// Displays currently showing this wallpaper (localized names).
        let activeDisplayNames: [String]
    }

    private enum ImportAction: Int {
        case file = 1
        case url = 2
        case enginePack = 3
    }

    private let tableView = NSTableView()
    private let useButton = NSButton()
    private let removeButton = NSButton()
    private let revealButton = NSButton()
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var rows: [Row] = []
    private var displayOptions: [(target: DisplayWallpaperTarget, title: String)] = []
    private var activeAssignments: [CGDirectDisplayID: String] = [:]
    private let onUse: (WallpaperLibraryEntry?, DisplayWallpaperTarget) -> Void
    private let onLocateUnavailable: (WallpaperLibraryEntry) -> Void
    private let onRemove: (WallpaperLibraryEntry) -> Void
    private let onReveal: (WallpaperLibraryEntry) -> Void
    private let onImportFile: () -> Void
    private let onImportURL: () -> Void
    private let onImportEnginePack: () -> Void
    private let enginePackStatusLabel = NSTextField(labelWithString: "")

    init(
        entries: [WallpaperLibraryEntry],
        activeAssignments: [CGDirectDisplayID: String],
        displayOptions: [(target: DisplayWallpaperTarget, title: String)],
        enginePackInstalled: Bool,
        onUse: @escaping (WallpaperLibraryEntry?, DisplayWallpaperTarget) -> Void,
        onLocateUnavailable: @escaping (WallpaperLibraryEntry) -> Void,
        onRemove: @escaping (WallpaperLibraryEntry) -> Void,
        onReveal: @escaping (WallpaperLibraryEntry) -> Void,
        onImportFile: @escaping () -> Void,
        onImportURL: @escaping () -> Void,
        onImportEnginePack: @escaping () -> Void
    ) {
        self.onUse = onUse
        self.onLocateUnavailable = onLocateUnavailable
        self.onRemove = onRemove
        self.onReveal = onReveal
        self.onImportFile = onImportFile
        self.onImportURL = onImportURL
        self.onImportEnginePack = onImportEnginePack

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 820, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text(.libraryWindowTitle)
        window.minSize = NSSize(width: 680, height: 360)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContentView()
        update(
            entries: entries,
            activeAssignments: activeAssignments,
            displayOptions: displayOptions,
            enginePackInstalled: enginePackInstalled
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        entries: [WallpaperLibraryEntry],
        activeAssignments: [CGDirectDisplayID: String],
        displayOptions: [(target: DisplayWallpaperTarget, title: String)],
        enginePackInstalled: Bool
    ) {
        self.activeAssignments = activeAssignments
        self.displayOptions = displayOptions
        enginePackStatusLabel.stringValue = enginePackInstalled
            ? L10n.text(.libraryEnginePackInstalled)
            : L10n.text(.libraryEnginePackMissing)
        enginePackStatusLabel.textColor = enginePackInstalled
            ? .secondaryLabelColor
            : .systemOrange
        rebuildTargetPopup()

        let nameByDisplay = Dictionary(
            uniqueKeysWithValues: displayOptions.compactMap { option -> (CGDirectDisplayID, String)? in
                guard case .display(let id) = option.target else { return nil }
                return (id, option.title)
            }
        )

        let builtInNames = activeAssignments.compactMap { id, token -> String? in
            token == DisplayWallpaperStore.builtInToken ? nameByDisplay[id] : nil
        }
        let builtIn = Row(
            entry: nil,
            title: L10n.text(.nativeScene),
            kind: L10n.text(.libraryTypeBuiltIn),
            source: L10n.text(.libraryBuiltInSource),
            sourceToken: DisplayWallpaperStore.builtInToken,
            isAvailable: true,
            activeDisplayNames: builtInNames
        )
        rows = [builtIn] + entries.map { entry in
            let token = Self.normalizedSource(entry.sourceURL)
            let names = activeAssignments.compactMap { id, assigned -> String? in
                assigned == token ? nameByDisplay[id] : nil
            }
            return Row(
                entry: entry,
                title: entry.title,
                kind: localizedKind(entry.kind),
                source: displaySource(entry),
                sourceToken: token,
                isAvailable: entry.isAvailable,
                activeDisplayNames: names
            )
        }
        tableView.reloadData()
        if let currentRow = rows.firstIndex(where: { !$0.activeDisplayNames.isEmpty }) {
            tableView.selectRowIndexes(IndexSet(integer: currentRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(currentRow)
        } else if !rows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateActions()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row), let tableColumn else { return nil }
        let model = rows[row]
        switch tableColumn.identifier.rawValue {
        case "current":
            let cell = imageCell(identifier: tableColumn.identifier)
            cell.imageView?.image = model.activeDisplayNames.isEmpty
                ? nil
                : NSImage(
                    systemSymbolName: "checkmark.circle.fill",
                    accessibilityDescription: L10n.text(.libraryCurrent)
                )
            cell.toolTip = model.activeDisplayNames.isEmpty
                ? nil
                : model.activeDisplayNames.joined(separator: ", ")
            return cell
        case "type":
            return textCell(
                identifier: tableColumn.identifier,
                value: model.kind,
                color: .secondaryLabelColor
            )
        case "displays":
            let value = model.activeDisplayNames.isEmpty
                ? "—"
                : model.activeDisplayNames.joined(separator: ", ")
            return textCell(
                identifier: tableColumn.identifier,
                value: value,
                color: model.activeDisplayNames.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
            )
        case "source":
            return textCell(
                identifier: tableColumn.identifier,
                value: model.isAvailable
                    ? model.source
                    : "\(L10n.text(.libraryUnavailable)): \(model.source)",
                color: model.isAvailable ? .secondaryLabelColor : .systemRed
            )
        default:
            return textCell(
                identifier: tableColumn.identifier,
                value: model.title,
                color: model.isAvailable ? .labelColor : .secondaryLabelColor
            )
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActions()
    }

    @objc private func useSelectedWallpaper() {
        guard let row = selectedRow else { return }
        let target = selectedTarget()
        if isAssigned(row, to: target) { return }
        if row.isAvailable {
            onUse(row.entry, target)
        } else if let entry = row.entry {
            onLocateUnavailable(entry)
        }
    }

    @objc private func removeSelectedWallpaper() {
        guard let entry = selectedRow?.entry else { return }
        onRemove(entry)
    }

    @objc private func revealSelectedWallpaper() {
        guard let entry = selectedRow?.entry,
              entry.sourceURL.isFileURL,
              entry.isAvailable else {
            return
        }
        onReveal(entry)
    }

    @objc private func importSelected(_ sender: NSMenuItem) {
        switch ImportAction(rawValue: sender.tag) {
        case .file: onImportFile()
        case .url: onImportURL()
        case .enginePack: onImportEnginePack()
        case nil: break
        }
    }

    @objc private func showImportMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let fileItem = NSMenuItem(
            title: L10n.text(.openWallpaper),
            action: #selector(importSelected(_:)),
            keyEquivalent: ""
        )
        fileItem.target = self
        fileItem.tag = ImportAction.file.rawValue
        menu.addItem(fileItem)

        let urlItem = NSMenuItem(
            title: L10n.text(.openWallpaperURL),
            action: #selector(importSelected(_:)),
            keyEquivalent: ""
        )
        urlItem.target = self
        urlItem.tag = ImportAction.url.rawValue
        menu.addItem(urlItem)

        menu.addItem(.separator())
        let packItem = NSMenuItem(
            title: L10n.text(.libraryImportEnginePack),
            action: #selector(importSelected(_:)),
            keyEquivalent: ""
        )
        packItem.target = self
        packItem.tag = ImportAction.enginePack.rawValue
        menu.addItem(packItem)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.maxY + 4),
            in: sender
        )
    }

    @objc private func tableDoubleClicked() {
        useSelectedWallpaper()
    }

    @objc private func targetChanged() {
        updateActions()
    }

    private var selectedRow: Row? {
        guard rows.indices.contains(tableView.selectedRow) else { return nil }
        return rows[tableView.selectedRow]
    }

    private func selectedTarget() -> DisplayWallpaperTarget {
        let index = targetPopup.indexOfSelectedItem
        guard displayOptions.indices.contains(index) else { return .all }
        return displayOptions[index].target
    }

    private func isAssigned(_ row: Row, to target: DisplayWallpaperTarget) -> Bool {
        switch target {
        case .all:
            guard !activeAssignments.isEmpty else { return false }
            return activeAssignments.values.allSatisfy { $0 == row.sourceToken }
        case .display(let id):
            return activeAssignments[id] == row.sourceToken
        }
    }

    private func makeContentView() -> NSView {
        let contentView = NSView()
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 30
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClicked)

        addColumn(identifier: "current", title: "", width: 36, minWidth: 36, maxWidth: 36)
        addColumn(identifier: "title", title: L10n.text(.libraryColumnName), width: 200)
        addColumn(identifier: "type", title: L10n.text(.libraryColumnType), width: 80, minWidth: 70)
        addColumn(
            identifier: "displays",
            title: L10n.text(.libraryColumnDisplays),
            width: 140,
            minWidth: 100
        )
        addColumn(identifier: "source", title: L10n.text(.libraryColumnSource), width: 300)
        scrollView.documentView = tableView

        let importButton = makeImportButton()
        configureIconButton(
            revealButton,
            symbol: "folder",
            tooltip: L10n.text(.libraryReveal),
            action: #selector(revealSelectedWallpaper)
        )
        configureIconButton(
            removeButton,
            symbol: "trash",
            tooltip: L10n.text(.libraryRemove),
            action: #selector(removeSelectedWallpaper)
        )

        useButton.imagePosition = .imageLeading
        useButton.bezelStyle = .rounded
        useButton.target = self
        useButton.action = #selector(useSelectedWallpaper)

        let targetLabel = NSTextField(labelWithString: L10n.text(.libraryApplyTo))
        targetLabel.translatesAutoresizingMaskIntoConstraints = false
        targetPopup.translatesAutoresizingMaskIntoConstraints = false
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)
        targetPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttonBar = NSStackView(views: [
            importButton,
            revealButton,
            removeButton,
            targetLabel,
            targetPopup
        ])
        buttonBar.translatesAutoresizingMaskIntoConstraints = false
        buttonBar.orientation = .horizontal
        buttonBar.alignment = .centerY
        buttonBar.spacing = 8

        enginePackStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        enginePackStatusLabel.font = NSFont.systemFont(ofSize: 11)
        enginePackStatusLabel.lineBreakMode = .byTruncatingMiddle
        enginePackStatusLabel.toolTip = EngineAssetStore.shared.particleRootURL.path

        contentView.addSubview(scrollView)
        contentView.addSubview(buttonBar)
        contentView.addSubview(enginePackStatusLabel)
        contentView.addSubview(useButton)
        useButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: buttonBar.topAnchor, constant: -12),
            buttonBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            buttonBar.bottomAnchor.constraint(equalTo: enginePackStatusLabel.topAnchor, constant: -8),
            enginePackStatusLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: 16
            ),
            enginePackStatusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: useButton.leadingAnchor,
                constant: -12
            ),
            enginePackStatusLabel.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -12
            ),
            targetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            targetPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            useButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            useButton.centerYAnchor.constraint(equalTo: buttonBar.centerYAnchor),
            useButton.leadingAnchor.constraint(greaterThanOrEqualTo: buttonBar.trailingAnchor, constant: 12)
        ])
        return contentView
    }

    private func rebuildTargetPopup() {
        let previous = targetPopup.indexOfSelectedItem
        targetPopup.removeAllItems()
        for option in displayOptions {
            targetPopup.addItem(withTitle: option.title)
        }
        if displayOptions.indices.contains(previous) {
            targetPopup.selectItem(at: previous)
        } else if !displayOptions.isEmpty {
            targetPopup.selectItem(at: 0)
        }
    }

    private func makeImportButton() -> NSButton {
        let button = NSButton()
        configureIconButton(
            button,
            symbol: "plus",
            tooltip: L10n.text(.libraryImport),
            action: #selector(showImportMenu(_:))
        )
        return button
    }

    private func addColumn(
        identifier: String,
        title: String,
        width: CGFloat,
        minWidth: CGFloat = 120,
        maxWidth: CGFloat = .greatestFiniteMagnitude
    ) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.maxWidth = maxWidth
        tableView.addTableColumn(column)
    }

    private func configureIconButton(
        _ button: NSButton,
        symbol: String,
        tooltip: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func textCell(
        identifier: NSUserInterfaceItemIdentifier,
        value: String,
        color: NSColor
    ) -> NSTableCellView {
        let reuseIdentifier = NSUserInterfaceItemIdentifier("text-\(identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: reuseIdentifier, owner: self)
            as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(field)
            cell.textField = field
            cell.identifier = reuseIdentifier
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = value
        cell.textField?.textColor = color
        cell.toolTip = value
        return cell
    }

    private func imageCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let reuseIdentifier = NSUserInterfaceItemIdentifier("image-\(identifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: reuseIdentifier, owner: self)
            as? NSTableCellView ?? NSTableCellView()
        if cell.imageView == nil {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView
            cell.identifier = reuseIdentifier
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                imageView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        return cell
    }

    private func updateActions() {
        guard let row = selectedRow else {
            useButton.isEnabled = false
            removeButton.isEnabled = false
            revealButton.isEnabled = false
            return
        }
        let target = selectedTarget()
        let alreadyAssigned = isAssigned(row, to: target)
        let primaryAction = row.isAvailable ? L10n.text(.libraryUse) : L10n.text(.libraryLocate)
        useButton.title = primaryAction
        useButton.image = NSImage(
            systemSymbolName: row.isAvailable ? "play.fill" : "folder.badge.questionmark",
            accessibilityDescription: primaryAction
        )
        useButton.isEnabled = !alreadyAssigned && (row.isAvailable || row.entry != nil)
        removeButton.isEnabled = row.entry != nil
        revealButton.isEnabled = row.entry?.sourceURL.isFileURL == true && row.isAvailable
    }

    private func localizedKind(_ rawValue: String) -> String {
        switch WallpaperProject.Kind(rawValue: rawValue) {
        case .web: L10n.text(.libraryTypeWeb)
        case .scene: L10n.text(.libraryTypeScene)
        case .video: L10n.text(.libraryTypeVideo)
        case .builtIn, nil: L10n.text(.libraryTypeBuiltIn)
        }
    }

    private func displaySource(_ entry: WallpaperLibraryEntry) -> String {
        let url = entry.sourceURL
        if url.isFileURL {
            return url.path
        }
        return url.absoluteString
    }

    private static func normalizedSource(_ url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }
}
