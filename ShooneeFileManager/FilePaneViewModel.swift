import Foundation
import Combine
import SwiftUI
import AppKit // NSPasteboard 사용을 위해 추가

class FilePaneViewModel: ObservableObject {
    @Published var currentPath: URL
    @Published var files: [FileItem] = []
    @Published var selectedFiles: Set<FileItem> = []
    @Published var isLoading: Bool = false
    
    // 📁 새 폴더 생성 상태
    @Published var isShowingNewFolderAlert: Bool = false
    @Published var newFolderName: String = "새 폴더"
    
    init(initialPath: URL) {
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
    
    func loadFiles() {
        isLoading = true
        let path = currentPath
        Task {
            do {
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .localizedNameKey]
                let contents = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
                
                let newFiles = contents.compactMap { url -> FileItem? in
                    let resourceValues = try? url.resourceValues(forKeys: Set(keys))
                    return FileItem(
                        url: url,
                        name: resourceValues?.localizedName ?? url.lastPathComponent,
                        isDirectory: resourceValues?.isDirectory ?? false,
                        size: Int64(resourceValues?.fileSize ?? 0),
                        date: resourceValues?.contentModificationDate ?? Date()
                    )
                }.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                
                await MainActor.run {
                    self.files = newFiles
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
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "파일 매니저 앱의 정상 작동을 위해 '홈' 또는 관리할 상위 폴더를 선택하여 접근 권한을 허용해 주세요."
        panel.prompt = "접근 허용"
        
        // 초기 위치를 홈으로 설정
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        
        if panel.runModal() == .OK {
            if let url = panel.url {
                navigateTo(url)
                completion(url)
            }
        }
    }
    
    // 시스템 설정의 '전체 디스크 접근 권한' 화면을 즉시 여는 기능
    func openSystemPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
    
    // 현재 실행 중인 앱 파일을 파인더에서 바로 보여주는 기능 (드래그용)
    func revealAppInFinder() {
        let appUrl = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([appUrl])
    }
    
    // 파일 또는 폴더 열기 (실행)
    func openItem(_ item: FileItem) {
        if item.isDirectory {
            navigateTo(item.url)
        } else {
            // macOS 시스템 기본 앱으로 실행 (압축 파일, 실행 파일 등)
            NSWorkspace.shared.open(item.url)
        }
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
                if FileManager.default.fileExists(atPath: destURL.path) {
                    await MainActor.run {
                        self.pendingConflict = FileConflict(src: srcURL, dest: destURL)
                        // TODO: 잘라내기 시의 충돌 정보도 담아야 하지만, 일단 복사와 동일하게 처리
                        self.isShowingConflictAlert = true
                    }
                    return 
                }
                
                await performPaste(src: srcURL, dest: destURL, isCut: actualIsCut)
            }
            await MainActor.run { 
                self.loadFiles() 
                // 잘라내기 작업 완료 후 상태 초기화
                if actualIsCut { self.isCutOperation = false }
                
                // 📡 전역 알림 발송: "파일이 옮겨졌거나 복사되었음!"
                NotificationCenter.default.post(name: .fileSystemChanged, object: nil)
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
            if overwrite && FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            
            if isCut {
                // ✂️ 잘라내기: 파일 이동 (Move)
                try FileManager.default.moveItem(at: src, to: dest)
            } else {
                // 📋 복사: 파일 복제 (Copy)
                try FileManager.default.copyItem(at: src, to: dest)
            }
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
    
    // MARK: - Trash / Delete
    
    /// 선택된 파일들을 휴지통으로 이동
    func deleteSelection() {
        let urls = Array(selectedFiles.map { $0.url })
        guard !urls.isEmpty else { return }
        
        // macOS 표준 휴지통 이동 함수 (사용자가 원하면 되돌리기 가능하도록)
        NSWorkspace.shared.recycle(urls) { (newURLs, error) in
            if let error = error {
                print("❌ Delete failed: \(error.localizedDescription)")
            } else {
                print("🗑 Moved \(urls.count) items to trash")
                DispatchQueue.main.async {
                    self.loadFiles()
                    self.selectedFiles = []
                    
                    // 📡 전역 알림 발송: "파일이 지워졌음!"
                    NotificationCenter.default.post(name: .fileSystemChanged, object: nil)
                }
            }
        }
    }
    
    // MARK: - Folder Creation
    
    func startCreatingFolder() {
        newFolderName = "새 폴더"
        isShowingNewFolderAlert = true
    }
    
    func commitFolderCreation() {
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "새 폴더" : trimmedName
        
        var targetURL = currentPath.appendingPathComponent(finalName)
        var counter = 2
        while FileManager.default.fileExists(atPath: targetURL.path) {
            targetURL = currentPath.appendingPathComponent("\(finalName) \(counter)")
            counter += 1
        }
        
        do {
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
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
}

// MARK: - Notification Extension
extension Notification.Name {
    static let fileSystemChanged = Notification.Name("fileSystemChanged")
}
