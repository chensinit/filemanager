import Foundation
import SwiftUI
import Combine

// 포커스 필드 식별자
enum FocusField: Hashable {
    case leftPath, rightPath
    
    var pane: ActivePane {
        self == .leftPath ? .left : .right
    }
}

// 파일 정보를 담는 모델
nonisolated struct FileItem: Identifiable, Equatable, Hashable {
    var id: String { url.path } // 경로 자체가 고유 ID (성능 향상)
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let date: Date
    /// .app 같은 패키지. 폴더이지만 파일처럼 엽니다.
    var isPackage = false
    
    var opensAsFolder: Bool { isDirectory && !isPackage }
    
    // URL 기반으로 빠르게 비교
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
    
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }
}

nonisolated enum FileSortKey: String {
    case name, date, size
}

// 사이드바 즐겨찾기 모델
struct FavoriteLocation: Identifiable, Codable, Equatable {
    var id: String { path }
    let name: String
    let icon: String
    let path: String
    /// 네트워크 폴더를 다시 연결할 때 쓰는 주소입니다.
    var remountURL: String? = nil
    
    var url: URL { URL(fileURLWithPath: path) }
}

// 연결된 네트워크 드라이브 또는 외장 디스크
struct MountedVolume: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isNetwork: Bool
}

// 프리뷰 정보만 따로 배달해주는 고속 우편함
class PreviewManager: ObservableObject {
    @Published var selectedFile: FileItem? = nil
}

// 🚨 파일 중복 충돌 정보를 담는 모델
nonisolated struct FileConflict: Identifiable {
    let id = UUID()
    let src: URL
    let dest: URL
    let isMove: Bool
}
