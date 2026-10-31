import SwiftUI
import AppKit

struct SidebarView: View {
    let previewManager: PreviewManager
    /// 현재 활성 패널의 폴더. + 버튼이 추가할 대상입니다.
    var currentFolder: () -> URL
    var onSelectLocation: (URL) -> Void

    @StateObject private var favorites = FavoritesStore()
    @StateObject private var volumes = VolumesStore()
    @State private var isShowingServerPrompt = false
    @State private var serverAddress = ""
    @State private var alertMessage: String?
    @State private var pendingFavorite: FavoriteLocation?

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(favorites.items) { item in
                        Button(action: { open(item) }) {
                            Label(item.name, systemImage: item.icon)
                        }
                        .buttonStyle(.plain)
                        .help(item.path)
                        .contextMenu {
                            Button("즐겨찾기에서 제거") { favorites.remove(item) }
                        }
                    }
                    .onMove(perform: favorites.move)
                } header: {
                    HStack {
                        Text("즐겨찾기")
                        Spacer()
                        Button(action: addCurrentFolder) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("현재 폴더를 즐겨찾기에 추가")
                    }
                }

                Section {
                    ForEach(volumes.volumes) { volume in
                        HStack {
                            Button(action: { onSelectLocation(volume.url) }) {
                                Label(volume.name, systemImage: volume.isNetwork ? "network" : "externaldrive")
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button(action: { eject(volume) }) {
                                Image(systemName: "eject")
                            }
                            .buttonStyle(.plain)
                            .help("연결 해제")
                        }
                    }

                    Button(action: {
                        serverAddress = ""
                        isShowingServerPrompt = true
                    }) {
                        Label("서버에 연결…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("위치")
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: 340)
            .dropDestination(for: URL.self) { urls, _ in
                addDropped(urls)
            }

            Divider()

            PreviewArea(manager: previewManager)
                .frame(maxHeight: .infinity)
                .background(.ultraThinMaterial.opacity(0.8))
        }
        .onReceive(NotificationCenter.default.publisher(for: .addToFavorites)) { notification in
            if let url = notification.object as? URL {
                favorites.add(url)
            }
        }
        .onChange(of: volumes.volumes) { _, _ in
            openPendingFavoriteIfMounted()
        }
        .alert("서버에 연결", isPresented: $isShowingServerPrompt) {
            TextField("smb://서버/공유폴더", text: $serverAddress)
            Button("취소", role: .cancel) { }
            Button("연결") { connect(to: serverAddress) }
        } message: {
            Text("예: smb://192.168.0.10/share")
        }
        .alert("알림", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("확인", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func open(_ item: FavoriteLocation) {
        if FileManager.default.fileExists(atPath: item.path) {
            onSelectLocation(item.url)
        } else if let remount = item.remountURL.flatMap(URL.init(string:)) {
            // 연결이 끊긴 네트워크 폴더: 다시 연결되면 자동으로 엽니다.
            pendingFavorite = item
            NSWorkspace.shared.open(remount)
        } else {
            alertMessage = "폴더를 찾을 수 없습니다: \(item.path)"
        }
    }

    private func openPendingFavoriteIfMounted() {
        guard let item = pendingFavorite, FileManager.default.fileExists(atPath: item.path) else { return }
        pendingFavorite = nil
        onSelectLocation(item.url)
    }

    private func addCurrentFolder() {
        let url = currentFolder()
        if !favorites.add(url) {
            alertMessage = "이미 즐겨찾기에 있거나 추가할 수 없는 폴더입니다."
        }
    }

    private func addDropped(_ urls: [URL]) -> Bool {
        var added = false
        for url in urls where favorites.add(url) {
            added = true
        }
        return added
    }

    private func connect(to address: String) {
        guard let url = ServerAddress.url(from: address) else {
            alertMessage = "서버 주소가 올바르지 않습니다. 예: smb://서버/공유폴더"
            return
        }
        // macOS가 로그인 창을 띄우고, 연결되면 위치 목록에 자동으로 나타납니다.
        NSWorkspace.shared.open(url)
    }

    private func eject(_ volume: MountedVolume) {
        Task {
            if let message = await volumes.eject(volume) {
                alertMessage = message
            }
        }
    }
}
