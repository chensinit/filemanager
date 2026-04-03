//
//  ContentView.swift
//  ShooneeFileManager
//
//  Created by shoonee on 3/31/26.
//

import SwiftUI
import Foundation

// MARK: - Pane Selection Enum
enum ActivePane: Hashable {
    case left, right
}

struct ContentView: View {
    @StateObject private var leftPane = FilePaneViewModel(initialPath: FileManager.default.homeDirectoryForCurrentUser)
    @StateObject private var rightPane = FilePaneViewModel(initialPath: FileManager.default.homeDirectoryForCurrentUser)
    @StateObject private var previewManager = PreviewManager()
    @State private var showPermissionOverlay: Bool = false
    @State private var activePane: ActivePane = .left 
    @FocusState private var focusedField: FocusField? // 시스템 포커스 추적
    
    var body: some View {
        ZStack {
            NavigationSplitView {
                // [Column 1] Sidebar (📐 다시 조절 가능 - 조작감은 유지하면서 너비만 자유롭게!)
                SidebarView(previewManager: previewManager, onSelectLocation: { url in
                    if activePane == .left {
                        leftPane.navigateTo(url)
                    } else {
                        rightPane.navigateTo(url)
                    }
                })
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 500)
            } content: {
                // [Column 2] Left Mirror Pane
                FilePaneView(viewModel: leftPane, previewManager: previewManager, isFocused: focusedField == .leftPane, focusedField: $focusedField, focusTarget: .leftPane, onFocus: {
                    activePane = .left
                    focusedField = .leftPane 
                }, onRequestPaneSwitch: { target in switchPane(to: target) })
                .overlay {
                    if activePane == .left {
                        Rectangle().stroke(Color.accentColor, lineWidth: 3)
                    }
                }
                .navigationSplitViewColumnWidth(min: 300, ideal: 500, max: 3000)
            } detail: {
                // [Column 3] Right Mirror Pane
                FilePaneView(viewModel: rightPane, previewManager: previewManager, isFocused: focusedField == .rightPane, focusedField: $focusedField, focusTarget: .rightPane, onFocus: {
                    activePane = .right
                    focusedField = .rightPane 
                }, onRequestPaneSwitch: { target in switchPane(to: target) })
                .overlay {
                    if activePane == .right {
                        Rectangle().stroke(Color.accentColor, lineWidth: 3)
                    }
                }
                .navigationSplitViewColumnWidth(min: 300, ideal: 500, max: 3000)
            }
            //  macOS 네이티브 Command 이벤트 연결 (TextField 입력 중일 때는 방해하지 않음!)
            .onCommand(Selector("copy:")) {
                if activePane == .left { leftPane.copySelection(isCut: false) }
                else { rightPane.copySelection(isCut: false) }
            }
            .onCommand(Selector("cut:")) {
                if activePane == .left { leftPane.copySelection(isCut: true) }
                else { rightPane.copySelection(isCut: true) }
            }
            .onCommand(Selector("paste:")) {
                if activePane == .left { leftPane.pasteClipboard() }
                else { rightPane.pasteClipboard() }
            }
            
            // 🔒 권한 안내 레이어
            if showPermissionOverlay {
                permissionOverlayView
            }
            
            // ⌨️ [전역 키보드 관제탑] 활성화된 패널로 정확히 명령 배달!
            Group {
                // Enter: 파일 실행 또는 폴더 진입
                Button("") {
                    let targetPane = (activePane == .left) ? leftPane : rightPane
                    if let first = targetPane.selectedFiles.first {
                        targetPane.openItem(first)
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                
                // Cmd + N: 새 폴더 만들기
                Button("") {
                    if activePane == .left { leftPane.startCreatingFolder() }
                    else { rightPane.startCreatingFolder() }
                }
                .keyboardShortcut("n", modifiers: [.command])
                
                // Delete (Backspace): 삭제 확인창 띄우기
                Button("") {
                    let targetPane = (activePane == .left) ? leftPane : rightPane
                    if !targetPane.selectedFiles.isEmpty {
                        targetPane.isShowingDeleteConfirmation = true
                    }
                }
                .keyboardShortcut(.delete, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .frame(minWidth: 1100, minHeight: 700)
        .onAppear {
            checkPermissions()
        }
    }
    
    // 키보드 방향키로 패널을 명시적으로 전환할 때만 동작하는 함수 (수동 클릭의 부작용 방지)
    private func switchPane(to target: ActivePane) {
        if target == .left {
            focusedField = .leftPane
            activePane = .left
            if leftPane.selectedFiles.isEmpty, let first = leftPane.files.first {
                leftPane.selectedFiles = [first]
            }
        } else {
            focusedField = .rightPane
            activePane = .right
            if rightPane.selectedFiles.isEmpty, let first = rightPane.files.first {
                rightPane.selectedFiles = [first]
            }
        }
    }
    
    // 권한 안내 뷰 분리
    var permissionOverlayView: some View {
        VStack(spacing: 25) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 60))
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(.accentColor)
            
            Text("전체 디스크 접근 권한이 필요합니다")
                .font(.title2.bold())
            
            VStack(alignment: .leading, spacing: 10) {
                Text("파인더처럼 자유롭게 파일을 관리하려면 아래 단계가 필요합니다:")
                    .font(.headline)
                Text("1. [설정창 열기] 버튼을 클릭합니다.")
                Text("2. [내 앱 파일 찾기] 버튼을 눌러 앱의 위치를 확인합니다.")
                Text("3. 파인더에 나타난 앱을 설정창 목록으로 드래그합니다.")
                Text("4. 스위치를 ON으로 켭니다.")
            }
            .font(.body)
            .foregroundColor(.secondary)
            .padding(.horizontal)
            
            VStack(spacing: 12) {
                HStack {
                    Button("1. 설정창 열기") {
                        leftPane.openSystemPrivacySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("2. 내 앱 파일 찾기") {
                        leftPane.revealAppInFinder()
                    }
                    .buttonStyle(.bordered)
                }
                
                Divider().padding(.vertical, 10)
                
                Button("일단 이번만 수동으로 허용하기") {
                    leftPane.requestAccess { url in
                        rightPane.navigateTo(url)
                        showPermissionOverlay = false
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
        .padding(40)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .shadow(radius: 20)
        .frame(maxWidth: 450)
    }
    
    func checkPermissions() {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let isSandboxed = homeURL.path.contains("Library/Containers")
        let contents = try? FileManager.default.contentsOfDirectory(at: homeURL, includingPropertiesForKeys: nil)
        let isActuallyEmpty = contents?.isEmpty ?? true
        
        if isSandboxed || isActuallyEmpty {
            showPermissionOverlay = true
        } else {
            showPermissionOverlay = false
            leftPane.loadFiles()
            rightPane.loadFiles()
        }
    }
}

#Preview {
    ContentView()
}
