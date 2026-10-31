import SwiftUI
import AppKit

struct FilePaneView: View {
    @ObservedObject var viewModel: FilePaneViewModel
    let previewManager: PreviewManager
    let pane: ActivePane
    @FocusState.Binding var focusedField: FocusField?
    /// 패널을 활성화합니다. 경로 입력칸의 포커스는 빼앗지 않습니다.
    var onActivate: () -> Void
    var onRequestPaneSwitch: ((ActivePane) -> Void)? = nil

    @State private var pathInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbarArea
                .onTapGesture { onActivate() }

            FileTableView(
                viewModel: viewModel,
                onActivate: onActivate,
                onRequestPaneSwitch: { onRequestPaneSwitch?(pane == .left ? .right : .left) }
            )
            .background(Color(NSColor.textBackgroundColor))
            .overlay(alignment: .bottom) {
                if let status = viewModel.transferStatus {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(status)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("남은 항목 취소") { viewModel.cancelTransfer() }
                    }
                    .padding(10)
                    .background(.regularMaterial)
                }
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView()
                } else if let loadError = viewModel.loadError {
                    ContentUnavailableView(
                        "폴더를 열 수 없습니다",
                        systemImage: "exclamationmark.lock",
                        description: Text(loadError)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.selectedFiles) { _, newValue in
            previewManager.selectedFile = viewModel.firstFile(in: newValue)
        }
        .alert("같은 이름의 항목이 있습니다", isPresented: $viewModel.isShowingConflictAlert, presenting: viewModel.pendingConflict) { _ in
            Button("덮어쓰기", role: .destructive) { viewModel.resolveConflict(.replace) }
            Button("건너뛰기") { viewModel.resolveConflict(.skip) }
            Button("모두 중단", role: .cancel) { viewModel.resolveConflict(.cancel) }
        } message: {
            Text("'\($0.dest.lastPathComponent)' 항목이 이미 있습니다. 덮어쓰면 기존 항목은 복구할 수 없습니다.")
        }
        .alert("작업을 완료하지 못했습니다", isPresented: errorAlertBinding) {
            Button("확인", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("휴지통으로 이동", isPresented: $viewModel.isShowingDeleteConfirmation) {
            Button("취소", role: .cancel) { }
            Button("휴지통으로 이동", role: .destructive) {
                viewModel.deleteSelection()
            }
        } message: {
            let count = viewModel.selectedFiles.count
            Text("선택한 항목 \(count)개를 휴지통으로 옮길까요?")
        }
        .alert("이름 변경", isPresented: $viewModel.isShowingRenameAlert) {
            TextField("이름", text: $viewModel.renameText)
            Button("취소", role: .cancel) { }
            Button("변경") { viewModel.commitRename() }
        }
        .alert("새 폴더 만들기", isPresented: $viewModel.isShowingNewFolderAlert) {
            TextField("새 폴더", text: $viewModel.newFolderName)
            Button("취소", role: .cancel) { viewModel.isShowingNewFolderAlert = false }
            Button("만들기") { viewModel.commitFolderCreation() }
        }
    }

    private var pathFocusTarget: FocusField {
        pane == .left ? .leftPath : .rightPath
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
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
                
                TextField("검색", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                
                Button(action: { viewModel.toggleHiddenFiles() }) {
                    Image(systemName: viewModel.showsHiddenFiles ? "eye" : "eye.slash")
                }
                .help("숨김 파일 표시 (⌘⇧.)")
            }
            .buttonStyle(.plain)
            .font(.system(size: 16))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)

            HStack {
                Button(action: viewModel.goBack) {
                    Image(systemName: "chevron.left").font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canGoBack)
                .help("뒤로 (⌘[)")
                
                Button(action: viewModel.goForward) {
                    Image(systemName: "chevron.right").font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canGoForward)
                .help("앞으로 (⌘])")
                
                Button(action: viewModel.goUp) {
                    Image(systemName: "arrow.up.circle").font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.currentPath.path == "/")

                // onCommit은 포커스를 잃을 때도 실행되므로 Enter에만 반응하는 onSubmit을 씁니다.
                TextField("Path", text: $pathInput)
                .onSubmit {
                    if !viewModel.navigateToTypedPath(pathInput) {
                        pathInput = viewModel.currentPath.path
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: pathFocusTarget)
                .onAppear { pathInput = viewModel.currentPath.path }
                .onChange(of: viewModel.currentPath) { _, newValue in
                    pathInput = newValue.path
                }
                .onChange(of: focusedField) { oldValue, newValue in
                    // Enter 없이 칸을 벗어나면 입력을 취소하고 현재 경로를 표시합니다.
                    if oldValue == pathFocusTarget && newValue != pathFocusTarget {
                        pathInput = viewModel.currentPath.path
                    }
                }

                Button(action: { viewModel.loadFiles() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.thinMaterial)
    }
}
