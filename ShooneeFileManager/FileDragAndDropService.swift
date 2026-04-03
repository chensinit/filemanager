import Foundation
import AppKit
import UniformTypeIdentifiers

struct InternalFileDragPayload: Codable {
    let sourcePaneID: UUID
    let urls: [URL]
}

extension UTType {
    static let shooneeDraggedFiles = UTType(importedAs: "com.chensi.filemanager.dragged-files")
}

struct FileDropRequest {
    let urls: [URL]
    let isMove: Bool
}

struct FileDragAndDropService {
    @MainActor
    private static var localDragContext: LocalDragContext?
    
    @MainActor
    func makeDragProvider(
        for file: FileItem,
        selectedFiles: Set<FileItem>,
        paneID: UUID
    ) -> NSItemProvider {
        let dragURLs = draggedURLs(for: file, selectedFiles: selectedFiles)
        Self.localDragContext = LocalDragContext(sourcePaneID: paneID, urls: dragURLs, startedAt: Date())
        let provider = NSItemProvider(object: file.url as NSURL)
        provider.suggestedName = file.name
        
        if let data = try? JSONEncoder().encode(InternalFileDragPayload(sourcePaneID: paneID, urls: dragURLs)) {
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.shooneeDraggedFiles.identifier,
                visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        
        return provider
    }
    
    func loadDropRequest(
        from providers: [NSItemProvider],
        destinationPaneID: UUID
    ) async -> FileDropRequest? {
        if let localContext = await matchingLocalDragContext(for: providers, destinationPaneID: destinationPaneID) {
            return FileDropRequest(
                urls: localContext.urls,
                isMove: localContext.sourcePaneID != destinationPaneID
            )
        }
        
        if let payload = await loadInternalDragPayload(from: providers) {
            return FileDropRequest(
                urls: payload.urls,
                isMove: payload.sourcePaneID != destinationPaneID
            )
        }
        
        let urls = await loadFileURLs(from: providers)
        guard !urls.isEmpty else { return nil }
        return FileDropRequest(urls: urls, isMove: false)
    }
    
    private func draggedURLs(for file: FileItem, selectedFiles: Set<FileItem>) -> [URL] {
        let selectedURLs = selectedFiles.map(\.url)
        if selectedFiles.contains(file), !selectedURLs.isEmpty {
            return selectedURLs.sorted { $0.path < $1.path }
        }
        return [file.url]
    }
    
    @MainActor
    private func matchingLocalDragContext(
        for providers: [NSItemProvider],
        destinationPaneID: UUID
    ) async -> LocalDragContext? {
        guard let context = Self.localDragContext else { return nil }
        
        // Ignore stale drags so external drops cannot accidentally reuse old app state.
        guard Date().timeIntervalSince(context.startedAt) < 5 else {
            Self.localDragContext = nil
            return nil
        }
        
        guard let firstProviderURL = await loadFirstFileURL(from: providers) else {
            return nil
        }
        
        guard context.sourcePaneID != destinationPaneID else {
            return nil
        }
        
        let normalizedContextURLs = Set(context.urls.map(\.standardizedFileURL))
        guard normalizedContextURLs.contains(firstProviderURL.standardizedFileURL) else {
            return nil
        }
        
        Self.localDragContext = nil
        return context
    }
    
    private func loadInternalDragPayload(from providers: [NSItemProvider]) async -> InternalFileDragPayload? {
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.shooneeDraggedFiles.identifier) else { continue }
            do {
                let data = try await provider.loadDataRepresentation(forTypeIdentifier: UTType.shooneeDraggedFiles.identifier)
                return try JSONDecoder().decode(InternalFileDragPayload.self, from: data)
            } catch {
                continue
            }
        }
        return nil
    }
    
    private func loadFirstFileURL(from providers: [NSItemProvider]) async -> URL? {
        for provider in providers {
            if let url = await provider.loadFileURL() {
                return url
            }
        }
        return nil
    }
    
    private func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        
        for provider in providers {
            if let url = await provider.loadFileURL() {
                urls.append(url)
            }
        }
        
        return urls
    }
}

private struct LocalDragContext {
    let sourcePaneID: UUID
    let urls: [URL]
    let startedAt: Date
}

private extension NSItemProvider {
    func loadDataRepresentation(forTypeIdentifier typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = self.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }
    
    func loadFileURL() async -> URL? {
        if self.canLoadObject(ofClass: NSURL.self) {
            do {
                let object = try await loadNSURL()
                return object as URL
            } catch {
                return nil
            }
        }
        
        return nil
    }
    
    func loadNSURL() async throws -> NSURL {
        try await withCheckedThrowingContinuation { continuation in
            self.loadObject(ofClass: NSURL.self) { object, error in
                if let object = object as? NSURL {
                    continuation.resume(returning: object)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.coderInvalidValue))
                }
            }
        }
    }
}
