import Foundation
import Combine
import SwiftUI
import AppKit // NSPasteboard 사용을 위해 추가

class FilePaneViewModel: ObservableObject {
    let paneID = UUID()
    private let fileSystemService: FileSystemService
    private let dragAndDropService: FileDragAndDropService
    private let macSystemService: MacSystemService
    @Published var currentPath: URL
    @Published var files: [FileItem] = []
    @Published var selectedFiles: Set<FileItem> = []
    @Published var isLoading: Bool = false
    
    // 📁 새 폴더 생성 상태
    @Published var isShowingNewFolderAlert: Bool = false
    @Published var newFolderName: String = "새 폴더"
    
    init(
        initialPath: URL,
        fileSystemService: FileSystemService = FileSystemService(),
        dragAndDropService: FileDragAndDropService = FileDragAndDropService(),
        macSystemService: MacSystemService = MacSystemService()
    ) {
        self.fileSystemService = fileSystemService
        self.dragAndDropService = dragAndDropService
        self.macSystemService = macSystemService
        self.currentPath = initialPath
        
        // 📡 전역 파일 시스템 변화 알림 구독
        NotificationCenter.default.addObserver(
            forName: .fileSystemChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadFiles()
        }
        
        loadFiles()
    }
    
    // 📋 붙여넣기 및 중복 경고 관련 상태
    @Published var isShowingConflictAlert = false
    @Published var pendingConflict: FileConflict? = nil
    @Published var isShowingDeleteConfirmation = false // 삭제 확인 팝업용
    private var isCutOperation: Bool = false // '잘라내기' 상태인지 내부 기록
    private var selectionAnchor: FileItem? = nil
    
    func loadFiles() {
        isLoading = true
        let path = currentPath
        Task {
            do {
                let newFiles = try fileSystemService.loadItems(at: path)
                
                await MainActor.run {
                    self.files = newFiles
                    let validSelection = Set(newFiles.filter { self.selectedFiles.contains($0) })
                    self.selectedFiles = validSelection
                    if let selectionAnchor, !validSelection.contains(selectionAnchor) {
                        self.selectionAnchor = validSelection.first
                    }
                    self.isLoading = false
                }
            } catch {
                print("Error loading \(path.path): \(error)")
                await MainActor.run {
                    self.isLoading = false
                    
                    // 🛑 네비게이션 시에 자동으로 팝업을 띄우지 않습니다.
                    // 권한 부족 시에는 목록만 비워두고 침묵합니다.
                }
            }
        }
    }
    
    func navigateTo(_ url: URL) {
        currentPath = url
        loadFiles()
    }
    
    func goUp() {
        let parent = currentPath.deletingLastPathComponent()
        if parent.path.count >= 1 {
            navigateTo(parent)
        }
    }
    
    // 앱 실행 시 또는 필요 시 파일 접근 권한을 한 번에 얻기 위한 로직
    func requestAccess(completion: @escaping (URL) -> Void = { _ in }) {
        if let url = macSystemService.requestDirectoryAccess() {
            navigateTo(url)
            completion(url)
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
        if item.isDirectory {
            navigateTo(item.url)
        } else {
            macSystemService.openFile(item.url)
        }
    }
    
    func clearSelection() {
        selectedFiles = []
        selectionAnchor = nil
    }
    
    func replaceSelection(with newSelection: Set<FileItem>) {
        selectedFiles = newSelection
        selectionAnchor = newSelection.first
    }
    
    func updateSelection(for file: FileItem, isCommandPressed: Bool, isShiftPressed: Bool) {
        if isCommandPressed {
            if selectedFiles.contains(file) {
                selectedFiles.remove(file)
            } else {
                selectedFiles.insert(file)
            }
            selectionAnchor = file
            return
        }
        
        if isShiftPressed,
           let anchor = selectionAnchor,
           let startIdx = files.firstIndex(of: anchor),
           let endIdx = files.firstIndex(of: file) {
            let rangeStart = min(startIdx, endIdx)
            let rangeEnd = max(startIdx, endIdx)
            selectedFiles = Set(files[rangeStart...rangeEnd])
            return
        }
        
        selectedFiles = [file]
        selectionAnchor = file
    }
    
    func prepareSelectionForDrag(on file: FileItem) {
        if selectedFiles.contains(file), !selectedFiles.isEmpty {
            selectionAnchor = file
            return
        }
        
        selectedFiles = [file]
        selectionAnchor = file
    }
    
    // MARK: - Clipboard Logic (Copy & Cut)
    
    func copySelection(isCut: Bool) {
        let urls = Array(selectedFiles.map { $0.url })
        guard !urls.isEmpty else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        // [1] Finder 호환성을 위해 NSURL 리스트로 등록
        let nsUrls = urls.map { $0 as NSURL }
        pasteboard.writeObjects(nsUrls)
        
        // [2] '잘라내기'인 경우 Finder 전용 플래그 심기
        if isCut {
            let cutFlagType = NSPasteboard.PasteboardType("com.apple.finder.node.cut")
            pasteboard.setString("1", forType: cutFlagType)
        }
        
        self.isCutOperation = isCut
        print("✅ \(isCut ? "Cut" : "Copy") \(urls.count) items to clipboard")
    }
    
    /// 클립보드 내용을 현재 경로에 붙여넣기 시도
    func pasteClipboard() {
        let pasteboard = NSPasteboard.general
        
        // 📋 클립보드에서 URL 목록 추출 (Finder에서 복사해온 경우도 지원)
        guard let items = pasteboard.readObjects(forClasses: [NSURL.self], options: nil), !items.isEmpty else {
            return
        }
        
        let urls = items.compactMap { $0 as? URL }
        
        // ✂️ '잘라내기' 여부 확인 (내부 변수 또는 클립보드 플래그)
        let cutFlagType = NSPasteboard.PasteboardType("com.apple.finder.node.cut")
        let actualIsCut = (pasteboard.string(forType: cutFlagType) == "1") || self.isCutOperation
        
        Task {
            for srcURL in urls {
                let destURL = currentPath.appendingPathComponent(srcURL.lastPathComponent)
                
                // 파일 중복 확인 (잘라내기 시에도 이름 같으면 알림)
                if fileSystemService.itemExists(at: destURL) {
                    await MainActor.run {
                        self.pendingConflict = FileConflict(src: srcURL, dest: destURL, isMove: actualIsCut)
                        // TODO: 잘라내기 시의 충돌 정보도 담아야 하지만, 일단 복사와 동일하게 처리
                        self.isShowingConflictAlert = true
                    }
                    return 
                }
                
                await performPaste(src: srcURL, dest: destURL, isCut: actualIsCut)
            }
            await MainActor.run { 
                self.finishFileTransfer(isCut: actualIsCut)
            }
        }
    }
    
    /// 실제 파일 복사/이동 작업 수행
    func performPaste(src: URL, dest: URL, isCut: Bool = false, overwrite: Bool = false) async -> (success: Bool, error: String) {
        let srcAccess = src.startAccessingSecurityScopedResource()
        defer { if srcAccess { src.stopAccessingSecurityScopedResource() } }
        
        let destAccess = currentPath.startAccessingSecurityScopedResource()
        defer { if destAccess { currentPath.stopAccessingSecurityScopedResource() } }
        
        do {
            try fileSystemService.transferItem(at: src, to: dest, isMove: isCut, overwrite: overwrite)
            return (true, "")
        } catch {
            let nsError = error as NSError
            let code = nsError.code
            if nsError.domain == NSCocoaErrorDomain && (code == 257 || code == 256 || code == 513 || code == 512) {
                await MainActor.run {
                    self.requestAccess { grantedURL in
                        self.currentPath = grantedURL
                        self.pasteClipboard()
                    }
                }
                return (false, "Permission Required")
            }
            return (false, error.localizedDescription)
        }
    }

    func dragProvider(for file: FileItem) -> NSItemProvider {
        dragAndDropService.makeDragProvider(for: file, selectedFiles: selectedFiles, paneID: paneID)
    }
    
    func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        
        Task {
            guard let request = await dragAndDropService.loadDropRequest(from: providers, destinationPaneID: paneID) else { return }
            await importDroppedURLs(request.urls, isMove: request.isMove)
        }
        
        return true
    }
    
    private func importDroppedURLs(_ urls: [URL], isMove: Bool) async {
        let uniqueURLs = Array(Set(urls)).sorted { $0.path < $1.path }
        
        for srcURL in uniqueURLs {
            let destURL = currentPath.appendingPathComponent(srcURL.lastPathComponent)
            
            if srcURL.standardizedFileURL == destURL.standardizedFileURL {
                continue
            }
            
            if fileSystemService.itemExists(at: destURL) {
                await MainActor.run {
                    self.pendingConflict = FileConflict(src: srcURL, dest: destURL, isMove: isMove)
                    self.isShowingConflictAlert = true
                }
                return
            }
            
            let result = await performPaste(src: srcURL, dest: destURL, isCut: isMove)
            guard result.success else { return }
        }
        
        await MainActor.run {
            self.finishFileTransfer(isCut: isMove)
        }
    }
    
    // MARK: - Trash / Delete
    
    /// 선택된 파일들을 휴지통으로 이동
    func deleteSelection() {
        let urls = Array(selectedFiles.map { $0.url })
        guard !urls.isEmpty else { return }
        
        Task {
            do {
                try await fileSystemService.recycle(urls)
                print("🗑 Moved \(urls.count) items to trash")
                await MainActor.run {
                    self.loadFiles()
                    self.selectedFiles = []
                    
                    // 📡 전역 알림 발송: "파일이 지워졌음!"
                    NotificationCenter.default.post(name: .fileSystemChanged, object: nil)
                }
            } catch {
                print("❌ Delete failed: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Folder Creation
    
    func startCreatingFolder() {
        newFolderName = "새 폴더"
        isShowingNewFolderAlert = true
    }
    
    func commitFolderCreation() {
        do {
            try fileSystemService.createFolder(named: newFolderName, in: currentPath)
            DispatchQueue.main.async {
                self.isShowingNewFolderAlert = false
                self.loadFiles()
            }
        } catch {
            print("❌ Folder creation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.isShowingNewFolderAlert = false
            }
        }
    }
    
    @MainActor
    func finishFileTransfer(isCut: Bool) {
        loadFiles()
        if isCut {
            isCutOperation = false
        }
        NotificationCenter.default.post(name: .fileSystemChanged, object: nil)
    }
}

// MARK: - Notification Extension
extension Notification.Name {
    static let fileSystemChanged = Notification.Name("fileSystemChanged")
}
