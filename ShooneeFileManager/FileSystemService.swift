import Foundation
import AppKit

nonisolated enum FileOperationError: LocalizedError {
    case destinationInsideSource(String)
    case sourceInsideDestination(String)
    case invalidName
    case nameAlreadyExists(String)
    
    var errorDescription: String? {
        switch self {
        case .destinationInsideSource(let name):
            return "'\(name)' 폴더를 자기 자신의 안으로 옮기거나 복사할 수 없습니다."
        case .sourceInsideDestination(let name):
            return "'\(name)' 항목을 자신이 들어 있는 폴더 위에 덮어쓸 수 없습니다."
        case .invalidName:
            return "사용할 수 없는 이름입니다."
        case .nameAlreadyExists(let name):
            return "'\(name)' 이름이 이미 사용 중입니다."
        }
    }
}

// 파일 작업은 UI를 막지 않도록 메인 스레드 밖에서 실행합니다.
nonisolated struct FileSystemService {
    private let fileManager: FileManager
    private let workspace: NSWorkspace
    
    init(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) {
        self.fileManager = fileManager
        self.workspace = workspace
    }
    
    func loadItems(at path: URL, includeHidden: Bool = false) throws -> [FileItem] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .localizedNameKey,
            .isPackageKey
        ]
        let contents = try fileManager.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: keys,
            options: includeHidden ? [] : .skipsHiddenFiles
        )
        
        return contents.compactMap { url -> FileItem? in
            let resourceValues = try? url.resourceValues(forKeys: Set(keys))
            return FileItem(
                url: url,
                name: resourceValues?.localizedName ?? url.lastPathComponent,
                isDirectory: resourceValues?.isDirectory ?? false,
                size: Int64(resourceValues?.fileSize ?? 0),
                date: resourceValues?.contentModificationDate ?? Date(),
                isPackage: resourceValues?.isPackage ?? false
            )
        }
    }
    
    /// 이름을 바꾸고 새 URL을 돌려줍니다.
    @discardableResult
    func renameItem(at url: URL, to proposedName: String) throws -> URL {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw FileOperationError.invalidName
        }
        
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        // 대소문자만 바꾸는 경우는 같은 파일로 잡히므로 허용합니다.
        let isCaseChangeOnly = name.lowercased() == url.lastPathComponent.lowercased()
        if itemExists(at: target) && !isCaseChangeOnly {
            throw FileOperationError.nameAlreadyExists(name)
        }
        
        if name != url.lastPathComponent {
            try fileManager.moveItem(at: url, to: target)
        }
        return target
    }
    
    func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
    
    func transferItem(at src: URL, to dest: URL, isMove: Bool, overwrite: Bool) throws {
        let srcPath = src.standardizedFileURL.path
        let destPath = dest.standardizedFileURL.path
        
        // 자기 자신을 덮어쓰면 원본이 삭제되므로 어떤 경우에도 진행하지 않습니다.
        if srcPath == destPath { return }
        if destPath.hasPrefix(srcPath + "/") {
            throw FileOperationError.destinationInsideSource(src.lastPathComponent)
        }
        if overwrite && srcPath.hasPrefix(destPath + "/") {
            throw FileOperationError.sourceInsideDestination(src.lastPathComponent)
        }
        
        if overwrite && itemExists(at: dest) {
            try replaceItemSafely(at: dest, with: src, deleteSourceOnSuccess: isMove)
        } else {
            if isMove {
                try fileManager.moveItem(at: src, to: dest)
            } else {
                try fileManager.copyItem(at: src, to: dest)
            }
        }
    }
    
    /// 같은 폴더에 복사할 때 쓸 겹치지 않는 이름을 만듭니다. (예: a.txt → a 복사본.txt)
    func uniqueCopyURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var counter = 1
        
        while true {
            let suffix = counter == 1 ? " 복사본" : " 복사본 \(counter)"
            var candidate = directory.appendingPathComponent(base + suffix)
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !itemExists(at: candidate) { return candidate }
            counter += 1
        }
    }
    
    @MainActor
    func recycle(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.recycle(urls) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    func createFolder(named proposedName: String, in directory: URL) throws {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "새 폴더" : trimmedName
        
        var targetURL = directory.appendingPathComponent(finalName)
        var counter = 2
        
        while itemExists(at: targetURL) {
            targetURL = directory.appendingPathComponent("\(finalName) \(counter)")
            counter += 1
        }
        
        try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true, attributes: nil)
    }
    
    private func replaceItemSafely(at dest: URL, with src: URL, deleteSourceOnSuccess: Bool) throws {
        let parentDirectory = dest.deletingLastPathComponent()
        let stagedURL = uniqueReplacementURL(in: parentDirectory, basedOn: dest, suffix: "staged")
        let backupURL = uniqueReplacementURL(in: parentDirectory, basedOn: dest, suffix: "backup")
        
        try fileManager.copyItem(at: src, to: stagedURL)
        
        do {
            try fileManager.moveItem(at: dest, to: backupURL)
            
            do {
                try fileManager.moveItem(at: stagedURL, to: dest)
                
                if deleteSourceOnSuccess {
                    try fileManager.removeItem(at: src)
                }
                
                if itemExists(at: backupURL) {
                    try fileManager.removeItem(at: backupURL)
                }
            } catch {
                if itemExists(at: backupURL) {
                    try? fileManager.moveItem(at: backupURL, to: dest)
                }
                if itemExists(at: stagedURL) {
                    try? fileManager.removeItem(at: stagedURL)
                }
                throw error
            }
        } catch {
            if itemExists(at: stagedURL) {
                try? fileManager.removeItem(at: stagedURL)
            }
            throw error
        }
    }
    
    private func uniqueReplacementURL(in directory: URL, basedOn destination: URL, suffix: String) -> URL {
        let baseName = destination.lastPathComponent
        return directory.appendingPathComponent(".\(baseName).shoonee.\(suffix).\(UUID().uuidString)")
    }
}
