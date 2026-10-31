import Foundation
import AppKit
import Combine
import SwiftUI

/// 사용자가 관리하는 즐겨찾기 목록. UserDefaults에 저장됩니다.
final class FavoritesStore: ObservableObject {
    @Published private(set) var items: [FavoriteLocation]
    
    private let defaults: UserDefaults
    private let key: String
    
    init(defaults: UserDefaults = .standard, key: String = "favorites.v1") {
        self.defaults = defaults
        self.key = key
        
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([FavoriteLocation].self, from: data) {
            items = saved
        } else {
            items = Self.defaultItems
        }
    }
    
    private static var defaultItems: [FavoriteLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            FavoriteLocation(name: "Home", icon: "house", path: home.path),
            FavoriteLocation(name: "Downloads", icon: "arrow.down.circle", path: home.appendingPathComponent("Downloads").path),
            FavoriteLocation(name: "Desktop", icon: "desktopcomputer", path: home.appendingPathComponent("Desktop").path),
            FavoriteLocation(name: "Documents", icon: "doc.text", path: home.appendingPathComponent("Documents").path),
            FavoriteLocation(name: "Root", icon: "externaldrive", path: "/")
        ]
    }
    
    /// 폴더를 즐겨찾기에 추가합니다. 폴더가 아니거나 이미 있으면 false를 돌려줍니다.
    @discardableResult
    func add(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !items.contains(where: { $0.path == path }) else { return false }
        
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeURLForRemountingKey])
        let isNetwork = values?.volumeIsLocal == false
        items.append(FavoriteLocation(
            name: path == "/" ? "Root" : url.lastPathComponent,
            icon: isNetwork ? "network" : "folder",
            path: path,
            remountURL: values?.volumeURLForRemounting?.absoluteString
        ))
        save()
        return true
    }
    
    func remove(_ item: FavoriteLocation) {
        items.removeAll { $0.id == item.id }
        save()
    }
    
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        save()
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }
    }
}

/// 연결된 네트워크 드라이브와 외장 디스크 목록을 실시간으로 유지합니다.
final class VolumesStore: ObservableObject {
    @Published private(set) var volumes: [MountedVolume] = []
    
    private var observers: [NSObjectProtocol] = []
    
    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }
    
    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
    }
    
    func refresh() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        
        volumes = urls.filter { $0.path != "/" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return MountedVolume(
                url: url,
                name: values?.volumeLocalizedName ?? url.lastPathComponent,
                isNetwork: values?.volumeIsLocal == false
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    
    /// 볼륨 연결을 해제합니다. 실패하면 사용자에게 보여줄 문구를 돌려줍니다.
    func eject(_ volume: MountedVolume) async -> String? {
        let url = volume.url
        let result = await Task.detached(priority: .userInitiated) {
            Result { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
        }.value
        
        if case .failure(let error) = result {
            return error.localizedDescription
        }
        return nil
    }
}

enum ServerAddress {
    private static let supportedSchemes: Set<String> = ["smb", "afp", "nfs", "cifs"]
    
    /// 입력한 주소를 연결용 URL로 바꿉니다. `server/share`와 `\\server\share` 형식도 받습니다.
    static func url(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !text.isEmpty else { return nil }
        
        if text.hasPrefix("//") {
            text = "smb:" + text
        } else if !text.contains("://") {
            text = "smb://" + text
        }
        
        // 한글이나 공백만 인코딩하고 주소 구분 기호(:, /, @)는 그대로 둡니다.
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: ":/@")
        
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: encoded),
              let scheme = url.scheme?.lowercased(),
              supportedSchemes.contains(scheme),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}
