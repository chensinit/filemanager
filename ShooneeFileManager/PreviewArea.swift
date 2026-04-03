import SwiftUI
import AppKit
import QuickLookThumbnailing

struct PreviewArea: View {
    @ObservedObject var manager: PreviewManager
    let width: CGFloat
    
    @State private var thumbnail: NSImage?
    @State private var fileSize: String = ""
    @State private var modDate: String = ""
    @State private var isCalculating: Bool = false
    @State private var loadingTask: Task<Void, Never>? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let file = manager.selectedFile {
                    if isCalculating {
                        ProgressView().controlSize(.small)
                    } else if let img = thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .transition(.opacity)
                    } else {
                        Image(systemName: file.isDirectory ? "folder.fill" : "doc.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.accentColor.opacity(0.3))
                    }
                }
            }
            .frame(width: width, height: 350)
            .background(Color.accentColor.opacity(0.05))
            .clipped()
            
            Divider()
            
            VStack(spacing: 15) {
                if let file = manager.selectedFile {
                    Text(file.name)
                        .font(.title3.bold())
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.top, 15)
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 10) {
                        InfoRow(label: "Kind", value: file.isDirectory ? "Folder" : file.url.pathExtension.uppercased())
                        InfoRow(label: "Size", value: isCalculating ? "..." : fileSize)
                        InfoRow(label: "Modified", value: modDate)
                    }
                } else {
                    VStack {
                        Spacer().frame(height: 50)
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.2))
                        Text("Select items for preview")
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                }
                Spacer()
            }
            .padding()
            .frame(width: width)
        }
        .padding()
        .onChange(of: manager.selectedFile) { _, newValue in
            loadingTask?.cancel()
            
            if let file = newValue {
                loadHighPerformancePreview(for: file)
            } else {
                cleanup()
            }
        }
    }
    
    private func loadHighPerformancePreview(for file: FileItem) {
        isCalculating = true
        thumbnail = nil
        
        loadingTask = Task {
            let attr = try? FileManager.default.attributesOfItem(atPath: file.url.path)
            let size = attr?[.size] as? Int64 ?? 0
            let date = attr?[.modificationDate] as? Date ?? Date()
            
            let req = QLThumbnailGenerator.Request(
                fileAt: file.url,
                size: CGSize(width: 400, height: 400),
                scale: 2.0,
                representationTypes: .thumbnail
            )
            
            let generator = QLThumbnailGenerator.shared
            var fetchedThumbnail: NSImage? = nil
            
            if !Task.isCancelled && !file.isDirectory {
                do {
                    let thumb = try await generator.generateBestRepresentation(for: req)
                    fetchedThumbnail = thumb.nsImage
                } catch {
                    fetchedThumbnail = NSImage(contentsOf: file.url)
                }
            }
            
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.fileSize = formatSize(size)
                        self.modDate = formatDate(date)
                        self.thumbnail = fetchedThumbnail
                        self.isCalculating = false
                    }
                }
            }
        }
    }
    
    private func cleanup() {
        thumbnail = nil
        fileSize = ""
        modDate = ""
        isCalculating = false
    }
    
    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
