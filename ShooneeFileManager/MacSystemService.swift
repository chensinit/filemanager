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

    /// 전체 디스크 접근 권한이 있어야만 읽을 수 있는 시스템 파일로 실제 권한을 확인합니다.
    func hasFullDiskAccess() -> Bool {
        let probe = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        guard fileManager.fileExists(atPath: probe) else { return true }

        guard let handle = FileHandle(forReadingAtPath: probe) else { return false }
        try? handle.close()
        return true
    }

    func openSystemPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        workspace.open(url)
    }

    func revealAppInFinder() {
        workspace.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func reveal(_ urls: [URL]) {
        workspace.activateFileViewerSelecting(urls)
    }
    
    func openFile(_ url: URL) {
        workspace.open(url)
    }
}
