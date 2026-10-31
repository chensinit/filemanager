import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 파일 목록. 클릭, ⌘/⇧ 선택, 더블클릭, 드래그, 방향키를 AppKit 기본 동작에 맡깁니다.
struct FileTableView: NSViewRepresentable {
    @ObservedObject var viewModel: FilePaneViewModel
    var onActivate: () -> Void
    var onRequestPaneSwitch: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = PaneTableView()
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.focusRingType = .none

        let nameColumn = NSTableColumn(identifier: Coordinator.nameColumn)
        nameColumn.title = "이름"
        nameColumn.resizingMask = .autoresizingMask
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: FileSortKey.name.rawValue, ascending: true)
        let dateColumn = NSTableColumn(identifier: Coordinator.dateColumn)
        dateColumn.title = "수정일"
        dateColumn.width = 130
        dateColumn.resizingMask = .userResizingMask
        dateColumn.sortDescriptorPrototype = NSSortDescriptor(key: FileSortKey.date.rawValue, ascending: false)
        let sizeColumn = NSTableColumn(identifier: Coordinator.sizeColumn)
        sizeColumn.title = "크기"
        sizeColumn.width = 80
        sizeColumn.resizingMask = .userResizingMask
        sizeColumn.sortDescriptorPrototype = NSSortDescriptor(key: FileSortKey.size.rawValue, ascending: false)
        table.addTableColumn(nameColumn)
        table.addTableColumn(dateColumn)
        table.addTableColumn(sizeColumn)
        table.sortDescriptors = [nameColumn.sortDescriptorPrototype!]

        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClickedRow(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.draggingDestinationFeedbackStyle = .regular
        table.viewModel = viewModel
        viewModel.menuTable = table

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // 창 도구 막대 때문에 내용 여백이 자동으로 바뀌지 않게 고정합니다.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? PaneTableView else { return }
        table.onActivate = onActivate
        table.onRequestPaneSwitch = onRequestPaneSwitch
        context.coordinator.apply(to: table)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        static let nameColumn = NSUserInterfaceItemIdentifier("name")
        static let dateColumn = NSUserInterfaceItemIdentifier("date")
        static let sizeColumn = NSUserInterfaceItemIdentifier("size")

        private let viewModel: FilePaneViewModel
        private var rows: [FileItem] = []
        private var rowSignature: [String] = []
        private var displayedPath: URL?
        private var focusRequest = 0
        private var isApplyingSelection = false

        init(viewModel: FilePaneViewModel) {
            self.viewModel = viewModel
        }

        /// ViewModel 상태를 표에 반영합니다.
        func apply(to table: PaneTableView) {
            let signature = viewModel.files.map { "\($0.id)|\($0.size)|\($0.date.timeIntervalSince1970)" }
            let pathChanged = displayedPath != viewModel.currentPath

            isApplyingSelection = true
            if signature != rowSignature {
                rows = viewModel.files
                rowSignature = signature
                table.reloadData()
            }

            let wanted = IndexSet(rows.indices.filter { viewModel.selectedFiles.contains(rows[$0]) })
            if table.selectedRowIndexes != wanted {
                table.selectRowIndexes(wanted, byExtendingSelection: false)
            }
            isApplyingSelection = false

            if pathChanged {
                displayedPath = viewModel.currentPath
                if !rows.isEmpty { table.scrollRowToVisible(0) }
            }

            if focusRequest != viewModel.focusRequest {
                focusRequest = viewModel.focusRequest
                table.focus()
            }
        }

        @objc func openClickedRow(_ sender: NSTableView) {
            guard rows.indices.contains(sender.clickedRow) else { return }
            viewModel.openItem(rows[sender.clickedRow])
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier else { return nil }
            let file = rows[row]
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? FileCellView)
                ?? FileCellView(identifier: identifier)

            switch identifier {
            case Self.nameColumn: cell.configureName(file)
            case Self.dateColumn: cell.configureDate(file)
            default: cell.configureSize(file)
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key.flatMap(FileSortKey.init(rawValue:)) else { return }
            viewModel.setSort(key, ascending: descriptor.ascending)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let table = notification.object as? NSTableView else { return }
            let selection = Set(table.selectedRowIndexes.filter { rows.indices.contains($0) }.map { rows[$0] })
            if viewModel.selectedFiles != selection {
                viewModel.selectedFiles = selection
            }
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            tableColumn?.identifier == Self.nameColumn ? rows[row].name : nil
        }

        // MARK: Drag & Drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            rows[row].url as NSURL
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            let dragged = draggedURLs(info)

            // 폴더 행 위에 놓으면 그 폴더로 들어갑니다.
            if dropOperation == .on, rows.indices.contains(row), rows[row].opensAsFolder,
               !dragged.contains(rows[row].url) {
                return info.draggingSource is PaneTableView ? .move : .copy
            }

            // 같은 패널의 빈 공간으로의 드롭은 할 일이 없습니다.
            if info.draggingSource as? NSTableView === tableView { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            return info.draggingSource is PaneTableView ? .move : .copy
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            let folder = rows.indices.contains(row) && rows[row].opensAsFolder ? rows[row].url : nil
            return viewModel.handleDrop(draggedURLs(info), isMove: info.draggingSource is PaneTableView, to: folder)
        }

        private func draggedURLs(_ info: NSDraggingInfo) -> [URL] {
            info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
        }

        // MARK: Context Menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table = viewModel.menuTable else { return }

            let row = table.clickedRow
            guard rows.indices.contains(row) else {
                add("붙여넣기", #selector(pasteHere), to: menu)
                add("새 폴더", #selector(newFolder), to: menu)
                return
            }

            // 선택되지 않은 행을 우클릭하면 그 행만 대상으로 삼습니다.
            if !table.selectedRowIndexes.contains(row) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }

            let selected = viewModel.selectedFiles
            add("열기", #selector(openSelection), to: menu)
            add("Finder에서 보기", #selector(revealSelection), to: menu)
            menu.addItem(.separator())
            if selected.count == 1 {
                add("이름 변경", #selector(renameSelection), to: menu)
            }
            add("복사", #selector(copySelection), to: menu)
            add("잘라내기", #selector(cutSelection), to: menu)
            add("붙여넣기", #selector(pasteHere), to: menu)
            if selected.contains(where: \.opensAsFolder) {
                menu.addItem(.separator())
                add("즐겨찾기에 추가", #selector(addSelectionToFavorites), to: menu)
            }
            menu.addItem(.separator())
            add("휴지통으로 이동", #selector(trashSelection), to: menu)
        }

        private func add(_ title: String, _ action: Selector, to menu: NSMenu) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        private var orderedSelection: [FileItem] {
            viewModel.files.filter { viewModel.selectedFiles.contains($0) }
        }

        @objc private func openSelection() { orderedSelection.forEach(viewModel.openItem) }
        @objc private func revealSelection() { viewModel.revealInFinder(orderedSelection) }
        @objc private func renameSelection() { viewModel.startRenaming() }
        @objc private func copySelection() { viewModel.copySelection(isCut: false) }
        @objc private func cutSelection() { viewModel.copySelection(isCut: true) }
        @objc private func pasteHere() { viewModel.pasteClipboard() }
        @objc private func newFolder() { viewModel.startCreatingFolder() }
        @objc private func trashSelection() { viewModel.isShowingDeleteConfirmation = true }
        @objc private func addSelectionToFavorites() {
            for file in orderedSelection where file.opensAsFolder {
                NotificationCenter.default.post(name: .addToFavorites, object: file.url)
            }
        }
    }
}

final class PaneTableView: NSTableView {
    weak var viewModel: FilePaneViewModel?
    var onActivate: (() -> Void)?
    var onRequestPaneSwitch: (() -> Void)?
    private var wantsFocus = false

    func focus() {
        if let window {
            window.makeFirstResponder(self)
        } else {
            wantsFocus = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus, let window {
            wantsFocus = false
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onActivate?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])

        switch event.keyCode {
        case 36, 76: // Return
            if let viewModel, let target = viewModel.firstFile(in: viewModel.selectedFiles) {
                viewModel.openItem(target)
                return
            }
        case 120: // F2
            if modifiers.isEmpty {
                viewModel?.startRenaming()
                return
            }
        case 51, 117: // Delete
            if modifiers.isEmpty || modifiers == .command {
                confirmDelete()
                return
            }
        case 123, 124: // ← →
            if modifiers.isEmpty, viewModel?.isOppositePaneKey(event.keyCode) == true {
                onRequestPaneSwitch?()
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    private func confirmDelete() {
        if viewModel?.selectedFiles.isEmpty == false {
            viewModel?.isShowingDeleteConfirmation = true
        }
    }

    @objc func copy(_ sender: Any?) { viewModel?.copySelection(isCut: false) }
    @objc func cut(_ sender: Any?) { viewModel?.copySelection(isCut: true) }
    @objc func paste(_ sender: Any?) { viewModel?.pasteClipboard() }
    @objc func delete(_ sender: Any?) { confirmDelete() }
}

private final class FileCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label

        if identifier == FileTableView.Coordinator.nameColumn {
            addSubview(icon)
            imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        } else {
            label.alignment = .right
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                label.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configureName(_ file: FileItem) {
        label.stringValue = file.name
        icon.image = Self.icon(for: file)
    }

    /// 파일을 직접 읽지 않고 종류로 아이콘을 고릅니다. 네트워크 폴더에서도 빠릅니다.
    private static func icon(for file: FileItem) -> NSImage {
        if file.isPackage {
            return NSWorkspace.shared.icon(forFile: file.url.path)
        }
        if file.isDirectory {
            return NSWorkspace.shared.icon(for: .folder)
        }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: file.url.pathExtension) ?? .data)
    }

    func configureDate(_ file: FileItem) {
        label.stringValue = Self.dateFormatter.string(from: file.date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    func configureSize(_ file: FileItem) {
        label.stringValue = file.opensAsFolder ? "" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
    }
}
