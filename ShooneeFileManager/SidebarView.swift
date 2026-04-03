import SwiftUI

struct SidebarView: View {
    let previewManager: PreviewManager
    var onSelectLocation: (URL) -> Void
    
    let favorites: [FavoriteLocation] = [
        FavoriteLocation(name: "Home", icon: "house", url: FileManager.default.homeDirectoryForCurrentUser),
        FavoriteLocation(name: "Downloads", icon: "arrow.down.circle", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")),
        FavoriteLocation(name: "Desktop", icon: "desktopcomputer", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")),
        FavoriteLocation(name: "Documents", icon: "doc.text", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")),
        FavoriteLocation(name: "Root", icon: "externaldrive", url: URL(fileURLWithPath: "/"))
    ]
    
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                List {
                    Section("Favorites") {
                        ForEach(favorites) { fav in
                            Button(action: { onSelectLocation(fav.url) }) {
                                Label(fav.name, systemImage: fav.icon)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(maxHeight: 220)
                
                Divider()
                
                PreviewArea(manager: previewManager, width: proxy.size.width)
                    .frame(maxHeight: .infinity)
                    .background(.ultraThinMaterial.opacity(0.8))
            }
        }
    }
}
