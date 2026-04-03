import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FilePaneView: View {
    @ObservedObject var viewModel: FilePaneViewModel
    let previewManager: PreviewManager
    var isFocused: Bool
    @FocusState.Binding var focusedField: FocusField?
    var focusTarget: FocusField
    var onFocus: () -> Void
    var onRequestPaneSwitch: ((ActivePane) -> Void)? = nil
    
    @State private var pathInput: String = ""
    @State private var lastClickTime: Date = .distantPast
    @State private var lastClickedFile: FileItem? = nil
    @State private var isHandlingManualClick: Bool = false
    @State private var hasToggledThisClick: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            toolbarArea
                .onTapGesture { onFocus() }
            
            ZStack {
                Color(NSColor.textBackgroundColor)
                    .onTapGesture {
                        onFocus()
                        viewModel.selectedFiles = []
                        previewManager.selectedFile = nil
                    }
                
                List(viewModel.files, selection: selectionBinding) { file in
                    FileRow(file: file)
                        .onDrag {
                            viewModel.dragProvider(for: file)
                        }
                        .tag(file)
                        .contentShape(Rectangle())
                        .simultaneousGesture(fileClickGesture(for: file))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .focused($focusedField, equals: focusTarget)
                .onDrop(of: [UTType.fileURL.identifier, UTType.shooneeDraggedFiles.identifier], isTargeted: nil) { providers in
                    onFocus()
                    return viewModel.handleDroppedProviders(providers)
                }
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
                .onKeyPress(.return) {
                    if let target = viewModel.selectedFiles.first {
                        viewModel.openItem(target)
                        return .handled
                    }
                    return .ignored
                }
            }
            .contentShape(Rectangle())
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
        .onChange(of: viewModel.selectedFiles) { _, newValue in
            previewManager.selectedFile = newValue.first
        }
        .alert("Conflict", isPresented: $viewModel.isShowingConflictAlert, presenting: viewModel.pendingConflict) { conflict in
            Button("Keep Existing", role: .cancel) { }
            Button("Replace (Overwrite)", role: .destructive) {
                Task {
                    let result = await viewModel.performPaste(src: conflict.src, dest: conflict.dest, isCut: conflict.isMove, overwrite: true)
                    await MainActor.run {
                        if result.success {
                            viewModel.finishFileTransfer(isCut: conflict.isMove)
                        }
                    }
                }
            }
        } message: {
            Text("A file named '\($0.dest.lastPathComponent)' already exists. Do you want to replace it?")
        }
        .alert("Trash Files", isPresented: $viewModel.isShowingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                viewModel.deleteSelection()
            }
        } message: {
            let count = viewModel.selectedFiles.count
            Text("Are you sure you want to move \(count) selected item\(count > 1 ? "s" : "") to the Trash?")
        }
        .alert("새 폴더 만들기", isPresented: $viewModel.isShowingNewFolderAlert) {
            TextField("새 폴더", text: $viewModel.newFolderName)
            Button("취소", role: .cancel) { viewModel.isShowingNewFolderAlert = false }
            Button("만들기") { viewModel.commitFolderCreation() }
        }
    }
    
    private var selectionBinding: Binding<Set<FileItem>> {
        Binding(
            get: { viewModel.selectedFiles },
            set: { newValue in
                if !isHandlingManualClick {
                    DispatchQueue.main.async {
                        viewModel.selectedFiles = newValue
                    }
                }
            }
        )
    }
    
    private func fileClickGesture(for file: FileItem) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                isHandlingManualClick = true
                
                guard !hasToggledThisClick else { return }
                hasToggledThisClick = true
                
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
                } else if isShift,
                          let anchor = lastClickedFile,
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
                hasToggledThisClick = false
                
                let now = Date()
                let interval = now.timeIntervalSince(lastClickTime)
                if interval < 0.38 && lastClickedFile?.url == file.url {
                    viewModel.openItem(file)
                    lastClickTime = .distantPast
                    lastClickedFile = nil
                } else {
                    lastClickTime = now
                }
                
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    previewManager.selectedFile = file
                }
                isHandlingManualClick = false
            }
    }
    
    private var toolbarArea: some View {
        VStack(spacing: 8) {
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
                .disabled(viewModel.selectedFiles.isEmpty)
                
                Spacer()
                
                Button(action: { }) {
                    Image(systemName: "list.bullet")
                }
                .help("리스트 모드")
                
                Button(action: { }) {
                    Image(systemName: "square.grid.2x2")
                }
                .help("아이콘 모드")
            }
            .buttonStyle(.plain)
            .font(.system(size: 16))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
            
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
