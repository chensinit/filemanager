import Foundation
import SwiftUI
import Combine

// 포커스 필드 식별자
enum FocusField: Hashable {
    case leftPane, rightPane
}

// 파일 정보를 담는 모델
struct FileItem: Identifiable, Equatable, Hashable {
    var id: String { url.path } // 경로 자체가 고유 ID (성능 향상)
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let date: Date
    
    // URL 기반으로 빠르게 비교
    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
    
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }
}

// 사이드바 즐겨찾기 모델
struct FavoriteLocation: Identifiable {
    let id = UUID()
    let name: String
    let icon: String  // icon이 두 번째
    let url: URL     // url이 세 번째
}

// 프리뷰 정보만 따로 배달해주는 고속 우편함
class PreviewManager: ObservableObject {
    @Published var selectedFile: FileItem? = nil
}

// 🚨 파일 중복 충돌 정보를 담는 모델
struct FileConflict: Identifiable {
    let id = UUID()
    let src: URL
    let dest: URL
}
