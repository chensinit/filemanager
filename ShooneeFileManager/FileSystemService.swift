import Foundation
import AppKit

struct FileSystemService {
    private let fileManager: FileManager
    private let workspace: NSWorkspace
    
    init(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) {
        self.fileManager = fileManager
        self.workspace = workspace
    }
    
    func loadItems(at path: URL) throws -> [FileItem] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .localizedNameKey
        ]
        let contents = try fileManager.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        )
        
        return contents.compactMap { url -> FileItem? in
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
    }
    
    func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
    
    func transferItem(at src: URL, to dest: URL, isMove: Bool, overwrite: Bool) throws {
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
