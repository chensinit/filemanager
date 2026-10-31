import Foundation
import Combine
import SwiftUI
import AppKit // NSPasteboard 사용을 위해 추가

enum ConflictResolution {
    case replace, skip, cancel
}

class FilePaneViewModel: ObservableObject {
    static let cutFlagType = NSPasteboard.PasteboardType("com.apple.finder.node.cut")

    let paneID = UUID()
    private let fileSystemService: FileSystemService
    private let macSystemService: MacSystemService
    private let pasteboard: NSPasteboard
    @Published var currentPath: URL
    /// 검색과 정렬이 적용된, 화면에 보이는 목록입니다.
    @Published var files: [FileItem] = []
    @Published var selectedFiles: Set<FileItem> = []
    @Published var isLoading: Bool = false
    @Published var loadError: String? = nil
    @Published var errorMessage: String? = nil
    @Published var showsHiddenFiles = false
    @Published var searchText = "" {
        didSet { if searchText != oldValue { refreshVisibleFiles() } }
    }
    @Published private(set) var sortKey: FileSortKey = .name
    @Published private(set) var sortAscending = true
    /// 복사/이동 진행 상황. 작업 중이 아니면 nil입니다.
    @Published private(set) var transferStatus: String? = nil
    @Published private var backStack: [URL] = []
    @Published private var forwardStack: [URL] = []
    /// 우클릭 메뉴가 대상으로 삼는 표입니다.
    weak var menuTable: NSTableView?
    private var allFiles: [FileItem] = []
    private var loadedPath: URL? = nil
    private var watcher: DirectoryWatcher? = nil

    // 📁 새 폴더 생성 상태
    @Published var isShowingNewFolderAlert: Bool = false
    @Published var newFolderName: String = "새 폴더"
    
    // ✏️ 이름 변경 상태
    @Published var isShowingRenameAlert: Bool = false
    @Published var renameText: String = ""
    private var renameTarget: FileItem? = nil

    // 📋 붙여넣기 및 중복 경고 관련 상태
    @Published var isShowingConflictAlert = false
    @Published var pendingConflict: FileConflict? = nil
    @Published var isShowingDeleteConfirmation = false // 삭제 확인 팝업용
    private var loadGeneration = 0
    /// 값이 바뀌면 목록이 키보드 포커스를 가져갑니다.
    @Published private(set) var focusRequest = 0
    /// 왼쪽 패널은 →, 오른쪽 패널은 ←가 반대쪽 패널로 가는 키입니다.
    var oppositePaneKeyCode: UInt16 = 124
    private var activeBatch: TransferBatch? = nil

    init(
        initialPath: URL,
        fileSystemService: FileSystemService = FileSystemService(),
        macSystemService: MacSystemService = MacSystemService(),
        pasteboard: NSPasteboard = .general
    ) {
        self.pasteboard = pasteboard
        self.fileSystemService = fileSystemService
        self.macSystemService = macSystemService
        self.currentPath = initialPath
        self.watcher = DirectoryWatcher { [weak self] in
            _ = self?.loadFiles()
        }

        // 📡 전역 파일 시스템 변화 알림 구독
        NotificationCenter.default.addObserver(
            forName: .fileSystemChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.loadFiles()
            }
        }

        loadFiles()
    }

    @discardableResult
    func loadFiles() -> Task<Void, Never> {
        loadGeneration += 1
        let generation = loadGeneration
        let path = currentPath
        let includeHidden = showsHiddenFiles
        let service = fileSystemService
        // 같은 폴더의 자동 새로고침에서는 로딩 표시를 띄우지 않습니다.
        isLoading = path != loadedPath

        return Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try service.loadItems(at: path, includeHidden: includeHidden) }
            }.value

            // 그사이 다른 폴더로 이동했다면 늦게 도착한 결과는 버립니다.
            guard generation == self.loadGeneration else { return }
            self.isLoading = false

            if path != self.loadedPath {
                self.loadedPath = path
                self.watcher?.watch(path)
            }

            switch result {
            case .success(let newFiles):
                self.allFiles = newFiles
                self.loadError = nil
                self.refreshVisibleFiles()
            case .failure(let error):
                // 목록을 남겨두면 화면과 실제 경로가 달라져 붙여넣기가 엉뚱한 곳으로 갑니다.
                self.allFiles = []
                self.refreshVisibleFiles()
                self.loadError = Self.describe(error)
            }
        }
    }

    /// 검색어와 정렬을 적용해 화면에 보일 목록을 만듭니다. 폴더가 항상 먼저 옵니다.
    private func refreshVisibleFiles() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? allFiles : allFiles.filter { $0.name.localizedCaseInsensitiveContains(query) }
        let key = sortKey
        let ascending = sortAscending

        files = matching.sorted { lhs, rhs in
            if lhs.opensAsFolder != rhs.opensAsFolder { return lhs.opensAsFolder }

            let order: ComparisonResult
            switch key {
            case .name:
                order = lhs.name.localizedStandardCompare(rhs.name)
            case .date:
                order = lhs.date.compare(rhs.date)
            case .size:
                order = lhs.size == rhs.size ? .orderedSame : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
            }

            if order == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }

        let visible = Set(files)
        let validSelection = selectedFiles.intersection(visible)
        if validSelection != selectedFiles {
            selectedFiles = validSelection
        }
    }

    func setSort(_ key: FileSortKey, ascending: Bool) {
        sortKey = key
        sortAscending = ascending
        refreshVisibleFiles()
    }

    func toggleHiddenFiles() {
        showsHiddenFiles.toggle()
        loadFiles()
    }

    func navigateTo(_ url: URL) {
        guard url != currentPath else {
            loadFiles()
            return
        }
        backStack.append(currentPath)
        forwardStack.removeAll()
        moveTo(url)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        moveTo(target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        moveTo(target)
    }

    private func moveTo(_ url: URL) {
        currentPath = url
        searchText = ""
        loadFiles()
    }

    /// 입력한 경로가 실제 폴더일 때만 이동합니다. 아니면 현재 폴더를 유지하고 안내합니다.
    @discardableResult
    func navigateToTypedPath(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (trimmed as NSString).expandingTildeInPath

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "폴더를 찾을 수 없습니다: \(trimmed)"
            return false
        }

        navigateTo(URL(fileURLWithPath: path))
        return true
    }

    func goUp() {
        let parent = currentPath.deletingLastPathComponent()
        if parent.path.count >= 1 {
            navigateTo(parent)
        }
    }

    // 시스템 설정의 '전체 디스크 접근 권한' 화면을 즉시 여는 기능
    func openSystemPrivacySettings() {
        macSystemService.openSystemPrivacySettings()
    }

    // 현재 실행 중인 앱 파일을 파인더에서 바로 보여주는 기능 (드래그용)
    func revealAppInFinder() {
        macSystemService.revealAppInFinder()
    }

    // 파일 또는 폴더 열기 (실행)
    func openItem(_ item: FileItem) {
        if item.opensAsFolder {
            navigateTo(item.url)
        } else {
            macSystemService.openFile(item.url)
        }
    }

    func requestFocus() {
        focusRequest += 1
    }

    func isOppositePaneKey(_ keyCode: UInt16) -> Bool {
        keyCode == oppositePaneKeyCode
    }

    /// 선택 항목 중 화면에서 가장 위에 있는 항목을 돌려줍니다. Set은 순서가 없어 결과가 매번 달라집니다.
    func firstFile(in selection: Set<FileItem>) -> FileItem? {
        files.first { selection.contains($0) }
    }

    // MARK: - Clipboard Logic (Copy & Cut)

    func copySelection(isCut: Bool) {
        let urls = Array(selectedFiles.map { $0.url })
        guard !urls.isEmpty else { return }

        pasteboard.clearContents()

        // [1] Finder 호환성을 위해 NSURL 리스트로 등록
        let nsUrls = urls.map { $0 as NSURL }
        pasteboard.writeObjects(nsUrls)

        // [2] 잘라내기 여부는 클립보드에만 기록합니다.
        // 다른 앱이 클립보드를 쓰면 함께 사라지므로 복사가 이동으로 바뀌지 않습니다.
        if isCut {
            pasteboard.setString("1", forType: Self.cutFlagType)
        }
    }

    /// 클립보드 내용을 현재 경로에 붙여넣기 시도
    @discardableResult
    func pasteClipboard() -> Task<Void, Never> {
        // 📋 클립보드에서 URL 목록 추출 (Finder에서 복사해온 경우도 지원)
        let items = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) ?? []
        let urls = items.compactMap { $0 as? URL }.filter(\.isFileURL)
        guard !urls.isEmpty else { return Task {} }

        let isCut = pasteboard.string(forType: Self.cutFlagType) == "1"
        return transfer(urls, isMove: isCut, consumesCutClipboard: isCut)
    }

    // MARK: - File Transfer

    /// 여러 항목을 옮기거나 복사합니다. 대상을 주지 않으면 현재 폴더이고, 시작 시점에 고정됩니다.
    @discardableResult
    func transfer(_ urls: [URL], isMove: Bool, consumesCutClipboard: Bool = false, to destination: URL? = nil) -> Task<Void, Never> {
        guard activeBatch == nil else {
            errorMessage = "진행 중인 파일 작업이 끝난 뒤 다시 시도해 주세요."
            return Task {}
        }

        let target = destination ?? currentPath
        guard fileSystemService.itemExists(at: target) else {
            errorMessage = "대상 폴더를 찾을 수 없습니다: \(target.path)"
            return Task {}
        }

        activeBatch = TransferBatch(
            remaining: urls,
            destinationDirectory: target,
            isMove: isMove,
            consumesCutClipboard: consumesCutClipboard
        )
        return Task { await runActiveBatch() }
    }

    /// 이름 충돌 알림에서 사용자가 고른 처리를 적용하고 나머지 항목을 이어서 진행합니다.
    @discardableResult
    func resolveConflict(_ resolution: ConflictResolution) -> Task<Void, Never> {
        let conflict = pendingConflict
        pendingConflict = nil
        isShowingConflictAlert = false

        guard let conflict, activeBatch != nil else { return Task {} }

        return Task {
            switch resolution {
            case .replace:
                await perform(conflict.src, to: conflict.dest, isMove: conflict.isMove, overwrite: true)
            case .skip:
                activeBatch?.isComplete = false
            case .cancel:
                activeBatch?.isComplete = false
                activeBatch?.remaining = []
            }
            activeBatch?.remaining.removeAll { $0 == conflict.src }
            await runActiveBatch()
        }
    }

    /// 남은 항목을 취소합니다. 진행 중인 항목은 끝까지 처리합니다.
    func cancelTransfer() {
        guard var batch = activeBatch, !batch.remaining.isEmpty else { return }
        batch.remaining = Array(batch.remaining.prefix(1))
        batch.isComplete = false
        activeBatch = batch
    }
    
    private func runActiveBatch() async {
        while let batch = activeBatch, let src = batch.remaining.first {
            let done = batch.total - batch.remaining.count + 1
            transferStatus = "\(batch.isMove ? "이동" : "복사") 중 (\(done)/\(batch.total)): \(src.lastPathComponent)"
            
            var dest = batch.destinationDirectory.appendingPathComponent(src.lastPathComponent)

            if src.standardizedFileURL.path == dest.standardizedFileURL.path {
                if batch.isMove {
                    // 같은 폴더로의 이동은 할 일이 없습니다.
                    activeBatch?.remaining.removeFirst()
                    continue
                }
                dest = fileSystemService.uniqueCopyURL(for: src)
            } else if fileSystemService.itemExists(at: dest) {
                transferStatus = nil
                pendingConflict = FileConflict(src: src, dest: dest, isMove: batch.isMove)
                isShowingConflictAlert = true
                return
            }

            await perform(src, to: dest, isMove: batch.isMove, overwrite: false)
            activeBatch?.remaining.removeFirst()
        }

        finishActiveBatch()
    }

    private func perform(_ src: URL, to dest: URL, isMove: Bool, overwrite: Bool) async {
        let service = fileSystemService
        let result = await Task.detached(priority: .userInitiated) {
            Result { try service.transferItem(at: src, to: dest, isMove: isMove, overwrite: overwrite) }
        }.value

        if case .failure(let error) = result {
            activeBatch?.isComplete = false
            activeBatch?.failures.append("\(src.lastPathComponent): \(Self.describe(error))")
        }
    }

    private func finishActiveBatch() {
        guard let batch = activeBatch else { return }
        activeBatch = nil
        transferStatus = nil

        if !batch.failures.isEmpty {
            errorMessage = batch.failures.joined(separator: "\n")
        }

        // 잘라낸 항목을 모두 옮겼다면 클립보드를 비워 두 번째 붙여넣기 실패를 막습니다.
        if batch.consumesCutClipboard && batch.isComplete {
            pasteboard.clearContents()
        }

        loadFiles()
        NotificationCenter.default.post(name: .fileSystemChanged, object: nil)
    }

    /// 드롭된 항목을 대상 폴더(기본: 현재 폴더)로 가져옵니다. 이미 그 폴더에 있는 항목은 제외합니다.
    func handleDrop(_ urls: [URL], isMove: Bool, to destination: URL? = nil) -> Bool {
        let target = destination ?? currentPath
        let current = target.standardizedFileURL.path
        let incoming = Array(Set(urls))
            .filter { $0.deletingLastPathComponent().standardizedFileURL.path != current }
            .sorted { $0.path < $1.path }
        guard !incoming.isEmpty else { return false }

        transfer(incoming, isMove: isMove, to: target)
        return true
    }

    // MARK: - Trash / Delete

    /// 선택된 파일들을 휴지통으로 이동
    func deleteSelection() {
        let urls = Array(selectedFiles.map { $0.url })
        guard !urls.isEmpty else { return }

        Task {
            do {
                try await fileSystemService.recycle(urls)
                self.selectedFiles = []
            } catch {
                self.errorMessage = Self.describe(error)
            }

            // 📡 전역 알림 발송: "파일이 지워졌음!"
            NotificationCenter.default.post(name: .fileSystemChanged, object: nil)
        }
    }

    // MARK: - Rename
    
    func startRenaming(_ item: FileItem? = nil) {
        guard let target = item ?? firstFile(in: selectedFiles) else { return }
        renameTarget = target
        renameText = target.url.lastPathComponent
        isShowingRenameAlert = true
    }
    
    func commitRename() {
        isShowingRenameAlert = false
        guard let target = renameTarget else { return }
        renameTarget = nil
        
        do {
            try fileSystemService.renameItem(at: target.url, to: renameText)
            selectedFiles = []
            NotificationCenter.default.post(name: .fileSystemChanged, object: nil)
        } catch {
            errorMessage = Self.describe(error)
        }
    }
    
    func revealInFinder(_ items: [FileItem]) {
        macSystemService.reveal(items.map(\.url))
    }
    
    // MARK: - Folder Creation

    func startCreatingFolder() {
        newFolderName = "새 폴더"
        isShowingNewFolderAlert = true
    }

    func commitFolderCreation() {
        isShowingNewFolderAlert = false
        do {
            try fileSystemService.createFolder(named: newFolderName, in: currentPath)
            NotificationCenter.default.post(name: .fileSystemChanged, object: nil)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - Errors

    nonisolated private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let isPermissionError =
            (nsError.domain == NSCocoaErrorDomain && (nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError))
            || (nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EPERM) || nsError.code == Int(EACCES)))

        if isPermissionError {
            return "접근 권한이 없습니다. 시스템 설정의 개인정보 보호 및 보안에서 이 앱의 파일 접근 권한을 확인해 주세요."
        }
        return error.localizedDescription
    }
}

private struct TransferBatch {
    var remaining: [URL]
    let destinationDirectory: URL
    let isMove: Bool
    let consumesCutClipboard: Bool
    var failures: [String] = []
    var isComplete = true
    let total: Int
    
    init(remaining: [URL], destinationDirectory: URL, isMove: Bool, consumesCutClipboard: Bool) {
        self.remaining = remaining
        self.destinationDirectory = destinationDirectory
        self.isMove = isMove
        self.consumesCutClipboard = consumesCutClipboard
        self.total = remaining.count
    }
}

// MARK: - Notification Extension
extension Notification.Name {
    static let fileSystemChanged = Notification.Name("fileSystemChanged")
    static let addToFavorites = Notification.Name("addToFavorites")
}
