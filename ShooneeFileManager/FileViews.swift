import SwiftUI
import AppKit // NSImage 사용을 위해 필요
import UniformTypeIdentifiers

// MARK: - Sidebar View
struct SidebarView: View {
    let previewManager: PreviewManager // @ObservedObject 제거 (불필요한 재계산 방지)
    var onSelectLocation: (URL) -> Void
    
    let favorites: [FavoriteLocation] = [
        FavoriteLocation(name: "Home", icon: "house", url: FileManager.default.homeDirectoryForCurrentUser),
        FavoriteLocation(name: "Downloads", icon: "arrow.down.circle", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")),
        FavoriteLocation(name: "Desktop", icon: "desktopcomputer", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")),
        FavoriteLocation(name: "Documents", icon: "doc.text", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")),
        FavoriteLocation(name: "Root", icon: "externaldrive", url: URL(fileURLWithPath: "/"))
    ]
    
    var body: some View {
        // 📊 GeometryReader로 현재 사이드바 너비를 실시간 캡처!
        GeometryReader { proxy in
            VStack(spacing: 0) {
                // [Top] 즐겨찾기 (내용만큼만 차지하게 유동적 조절)
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
                .frame(maxHeight: 220) // 즐겨찾기 영역 제한하여 프리뷰에 더 많은 공간 제공
                
                Divider()
                
                // [Bottom] ✨ 현재 사이드바 너비(proxy.size.width)를 프리뷰에 강하게 주입!
                PreviewArea(manager: previewManager, width: proxy.size.width)
                    .frame(maxHeight: .infinity) // 🚀 위로 쭉 늘어납니다!
                    .background(.ultraThinMaterial.opacity(0.8))
            }
        }
    }
}

// MARK: - File Pane View
struct FilePaneView: View {
    @ObservedObject var viewModel: FilePaneViewModel
    let previewManager: PreviewManager
    var isFocused: Bool // 현재 시스템 포커스를 가지고 있는지 여부
    @FocusState.Binding var focusedField: FocusField? // FocusState 연동
    var focusTarget: FocusField
    var onFocus: () -> Void
    var onRequestPaneSwitch: ((ActivePane) -> Void)? = nil
    @State private var pathInput: String = ""
    
    // 더블 클릭 정밀 판정용 타이머
    @State private var lastClickTime: Date = .distantPast
    @State private var lastClickedFile: FileItem? = nil
    
    // 🚩 전용 플래그들
    @State private var isHandlingManualClick: Bool = false // 시스템 간섭 방지
    @State private var hasToggledThisClick: Bool = false   // 1회 클릭당 1회 처리 보장
    
    var body: some View {
        VStack(spacing: 0) {
            // [1] Toolbar
            toolbarArea
                .onTapGesture { onFocus() }
            
            // [2] List Area (💎 드래그 박스 선택 복구)
            ZStack {
                // 리스트 아래 빈 공간 클릭 감지 (리스트가 짧은 경우 빈 공간 클릭 시 선택 해제 용도)
                Color(NSColor.textBackgroundColor)
                    .onTapGesture {
                        onFocus()
                        viewModel.selectedFiles = []
                        previewManager.selectedFile = nil
                    }
                
                // 💎 시스템 바인딩을 프록시로 감싸서 '수동 클릭' 신호를 필터링함!
                List(viewModel.files, selection: Binding(
                    get: { viewModel.selectedFiles },
                    set: { newValue in
                        if !isHandlingManualClick {
                            viewModel.selectedFiles = newValue
                        }
                    }
                )) { file in
                    FileRow(file: file)
                        .onDrag {
                            viewModel.dragProvider(for: file)
                        }
                        .tag(file)
                        .contentShape(Rectangle())
                        // ⚡️ 즉시 선택 + 더블 클릭 통합 핸들러 (0ms 반응)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    isHandlingManualClick = true
                                    
                                    // 🛑 중복 처리 방지: 이번 클릭에서 이미 액션을 했다면 스킵!
                                    guard !hasToggledThisClick else { return }
                                    hasToggledThisClick = true 
                                    
                                    // 🎨 하이라이트 & 포커스 즉시 반영
                                    onFocus()
                                    
                                    let isCmd = NSEvent.modifierFlags.contains(.command)
                                    let isShift = NSEvent.modifierFlags.contains(.shift)
                                    
                                    if isCmd {
                                        if viewModel.selectedFiles.contains(file) {
                                            viewModel.selectedFiles.remove(file)
                                        } else {
                                            viewModel.selectedFiles.insert(file)
                                        }
                                        lastClickedFile = file
                                    } else if isShift, let anchor = lastClickedFile, 
                                              let startIdx = viewModel.files.firstIndex(of: anchor), 
                                              let endIdx = viewModel.files.firstIndex(of: file) {
                                        let rangeStart = min(startIdx, endIdx)
                                        let rangeEnd = max(startIdx, endIdx)
                                        viewModel.selectedFiles = Set(viewModel.files[rangeStart...rangeEnd])
                                    } else {
                                        viewModel.selectedFiles = [file]
                                        lastClickedFile = file
                                    }
                                }
                                .onEnded { _ in
                                    hasToggledThisClick = false // 🏳️ 클릭 종료: 깃발 초기화
                                    
                                    // ⏱️ 더블 클릭 판정
                                    let now = Date()
                                    let interval = now.timeIntervalSince(lastClickTime)
                                    if interval < 0.38 && lastClickedFile?.url == file.url {
                                        viewModel.openItem(file) // 🚀 통일된 실행 로직 호출
                                        lastClickTime = .distantPast
                                        lastClickedFile = nil
                                    } else {
                                        lastClickTime = now
                                    }
                                    
                                    // 💎 애니메이션 없이 즉시 프리뷰 갱신 (진동 방지)
                                    var transaction = Transaction()
                                    transaction.animation = nil
                                    withTransaction(transaction) {
                                        previewManager.selectedFile = file
                                    }
                                    isHandlingManualClick = false 
                                }
                        )
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden) 
                .focused($focusedField, equals: focusTarget)
                .onDrop(of: [UTType.fileURL.identifier, UTType.shooneeDraggedFiles.identifier], isTargeted: nil) { providers in
                    onFocus()
                    return viewModel.handleDroppedProviders(providers)
                }
                // 좌우 방향키로 패널(리스트) 간 포커스 전환
                .onKeyPress(.leftArrow) {
                    if focusTarget == .rightPane {
                        onRequestPaneSwitch?(.left)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.rightArrow) {
                    if focusTarget == .leftPane {
                        onRequestPaneSwitch?(.right)
                        return .handled
                    }
                    return .ignored
                }
                // 🚀 엔터(Enter) 키로 파일 실행 또는 폴더 진입
                .onKeyPress(.return) {
                    // 다중 선택 시 첫 번째 대상을 우선 처리하거나, 현재 선호되는 항목을 실행
                    if let target = viewModel.selectedFiles.first {
                        viewModel.openItem(target)
                        return .handled
                    }
                    return .ignored
                }
            }
            .contentShape(Rectangle())
            // ⚡️ 초강력 즉시 포커스 엔진: TapGesture 대신 Drag(minDist: 0)를 써서 마우스 버튼이 '닿는 순간' 판을 바꿈!
            // 이 방식은 리스트의 빈 영역뿐만 아니라 아이템 위를 누를 때도 row 제스처와 '동시에' 실행되어 가장 반응이 빠릅니다.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        onFocus()
                    }
            )
            .overlay {
                if viewModel.isLoading {
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 선택이 바뀔 때 프리뷰만 갱신
        .onChange(of: viewModel.selectedFiles) { _, newValue in
            if let first = newValue.first {
                previewManager.selectedFile = first
            } else {
                previewManager.selectedFile = nil
            }
        }
        // 🚨 중복 파일 확인 경고장 (Windows 스타일)
        .alert("Conflict", isPresented: $viewModel.isShowingConflictAlert, presenting: viewModel.pendingConflict) { conflict in
            Button("Keep Existing", role: .cancel) { }
            Button("Replace (Overwrite)", role: .destructive) {
                Task {
                    await viewModel.performPaste(src: conflict.src, dest: conflict.dest, isCut: conflict.isMove, overwrite: true)
                    await MainActor.run {
                        viewModel.loadFiles()
                    }
                }
            }
        } message: { Text("A file named '\($0.dest.lastPathComponent)' already exists. Do you want to replace it?") }
        // 🗑 삭제 확인 알림창
        .alert("Trash Files", isPresented: $viewModel.isShowingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                viewModel.deleteSelection()
            }
        } message: {
            let count = viewModel.selectedFiles.count
            Text("Are you sure you want to move \(count) selected item\(count > 1 ? "s" : "") to the Trash?")
        }
        // 📁 새 폴더 생성 팝업창
        .alert("새 폴더 만들기", isPresented: $viewModel.isShowingNewFolderAlert) {
            TextField("새 폴더", text: $viewModel.newFolderName)
            Button("취소", role: .cancel) { viewModel.isShowingNewFolderAlert = false }
            Button("만들기") { viewModel.commitFolderCreation() }
        }
    }
    
    // 툴바 영역 분리 (가독성 용이)
    private var toolbarArea: some View {
        VStack(spacing: 8) {
            // [Top] 툴 버튼들 (아이콘만)
            HStack(spacing: 16) {
                Button(action: { viewModel.startCreatingFolder() }) {
                    Image(systemName: "folder.badge.plus")
                }
                .help("새 폴더")
                
                Divider()
                    .frame(height: 14)
                
                Button(action: { viewModel.copySelection(isCut: false) }) {
                    Image(systemName: "doc.on.doc")
                }
                .help("복사")
                
                Button(action: { viewModel.copySelection(isCut: true) }) {
                    Image(systemName: "scissors")
                }
                .help("잘라내기")
                
                Button(action: { viewModel.pasteClipboard() }) {
                    Image(systemName: "doc.on.clipboard")
                }
                .help("붙여넣기")
                
                Button(action: { viewModel.isShowingDeleteConfirmation = true }) {
                    Image(systemName: "trash")
                }
                .help("삭제 (휴지통)")
                .disabled(viewModel.selectedFiles.isEmpty) // 💡 선택된 파일이 없을 때 비활성화
                
                Spacer()
                
                Button(action: { /* 리스트 모드 */ }) {
                    Image(systemName: "list.bullet")
                }
                .help("리스트 모드")
                
                Button(action: { /* 아이콘 모드 */ }) {
                    Image(systemName: "square.grid.2x2")
                }
                .help("아이콘 모드")
            }
            .buttonStyle(.plain)
            .font(.system(size: 16))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
            
            // [Bottom] 주소 표시줄 영역
            HStack {
                Button(action: viewModel.goUp) {
                    Image(systemName: "arrow.up.circle").font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.currentPath.path == "/")
                
                TextField("Path", text: $pathInput, onCommit: {
                    let url = URL(fileURLWithPath: pathInput)
                    viewModel.navigateTo(url)
                })
                .textFieldStyle(.roundedBorder)
                .onAppear { pathInput = viewModel.currentPath.path }
                .onChange(of: viewModel.currentPath) { _, newValue in
                    pathInput = newValue.path
                }
                
                Button(action: viewModel.loadFiles) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.thinMaterial)
    }
}

import QuickLookThumbnailing

// MARK: - Preview Area
struct PreviewArea: View {
    @ObservedObject var manager: PreviewManager //Binding 대신 매니저를 직접 관찰
    let width: CGFloat // 📏 실시간 사이드바 너비를 주입받음
    
    @State private var thumbnail: NSImage?
    @State private var fileSize: String = ""
    @State private var modDate: String = ""
    @State private var isCalculating: Bool = false
    @State private var loadingTask: Task<Void, Never>? = nil 
    
    var body: some View {
        VStack(spacing: 0) {
            // [Fixed Container] 🖼️ 너비 300px, 높이 350px로 완전 고정! (No Jump!)
            ZStack {
                if let file = manager.selectedFile {
                    if isCalculating {
                        ProgressView().controlSize(.small)
                    } else if let img = thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit) // 🖼️ 가로 너비(300px)에 맞춰 전체 모습이 보이게!
                            .transition(.opacity)
                    } else {
                        Image(systemName: file.isDirectory ? "folder.fill" : "doc.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.accentColor.opacity(0.3))
                    }
                }
            }
            .frame(width: width, height: 350) // 📏 300px 대신 'width'로 박제! 시스템은 더 이상 흔들지 않습니다.
            .background(Color.accentColor.opacity(0.05))
            .clipped()
            
            Divider()
            
            // [Metadata Area] ℹ️ 하단 정보 (사이드바 너비 300px에 맞춰 자동 정렬)
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
                    // 미선택 시 문구 (위치 고정)
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
            .frame(width: width) // ✨ 300px 대신 'width'로 박제!
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
    
    // 고성능 비동기 프리뷰 로드 (QuickLook & Cancelation 지원)
    private func loadHighPerformancePreview(for file: FileItem) {
        isCalculating = true
        thumbnail = nil
        
        loadingTask = Task {
            // 1. 기본 메타데이터 로드
            let attr = try? FileManager.default.attributesOfItem(atPath: file.url.path)
            let size = attr?[.size] as? Int64 ?? 0
            let date = attr?[.modificationDate] as? Date ?? Date()
            
            // 2. 고성능 썸네일 생성 (QuickLook 사용)
            let req = QLThumbnailGenerator.Request(
                fileAt: file.url,
                size: CGSize(width: 400, height: 400),
                scale: 2.0,
                representationTypes: .thumbnail
            )
            
            let generator = QLThumbnailGenerator.shared
            var fetchedThumbnail: NSImage? = nil
            
            // 🛑 폴더일 경우에는 썸네일 생성을 시도하지 않습니다. (시스템의 권한 팝업 방지)
            if !Task.isCancelled && !file.isDirectory {
                do {
                    let thumb = try await generator.generateBestRepresentation(for: req)
                    fetchedThumbnail = thumb.nsImage
                } catch {
                    // 실패 시 일반 이미지 로드 시도
                    fetchedThumbnail = NSImage(contentsOf: file.url)
                }
            }
            
            // UI 업데이트 전 취소 여부 최종 확인
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
    
    private func isAudioFile(_ file: FileItem) -> Bool {
        let exts = ["mp3", "wav", "m4a", "aac"]
        return exts.contains(file.url.pathExtension.lowercased())
    }
}

// MARK: - Components & Helpers
struct AudioControlsView: View {
    var body: some View {
        HStack(spacing: 20) {
            Button(action: {}) { Image(systemName: "backward.fill") }
            Button(action: {}) { Image(systemName: "play.circle.fill").font(.title) }
            Button(action: {}) { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.plain)
        .padding(.top, 5)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label + ":").bold()
            Spacer()
            Text(value)
        }
    }
}

struct FileRow: View {
    let file: FileItem
    var body: some View {
        HStack {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundColor(file.isDirectory ? .blue : .secondary)
            Text(file.name)
            Spacer()
            if !file.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - View Modifiers
extension View {
    func onDoubleClick(perform action: @escaping () -> Void) -> some View {
        modifier(DoubleTapModifier(action: action))
    }
}

struct DoubleTapModifier: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.simultaneousGesture(TapGesture(count: 2).onEnded(action))
    }
}
