import Foundation
import AppKit

struct MacSystemService {
    private let workspace: NSWorkspace
    private let fileManager: FileManager
    
    init(
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default
    ) {
        self.workspace = workspace
        self.fileManager = fileManager
    }
    
    func requestDirectoryAccess() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "파일 매니저 앱의 정상 작동을 위해 '홈' 또는 관리할 상위 폴더를 선택하여 접근 권한을 허용해 주세요."
        panel.prompt = "접근 허용"
        panel.directoryURL = fileManager.homeDirectoryForCurrentUser
        
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
    
    func openSystemPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        workspace.open(url)
    }
    
    func revealAppInFinder() {
        workspace.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    
    func openFile(_ url: URL) {
        workspace.open(url)
    }
}
