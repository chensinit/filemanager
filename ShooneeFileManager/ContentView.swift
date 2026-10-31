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
    @StateObject private var leftPane = FilePaneViewModel(initialPath: Self.initialPath(forKey: "leftPath"))
    @StateObject private var rightPane = FilePaneViewModel(initialPath: Self.initialPath(forKey: "rightPath"))
    @StateObject private var previewManager = PreviewManager()
    @State private var activePane: ActivePane = .left
    @State private var isShowingPermissionBanner = false
    @FocusState private var focusedField: FocusField? // 경로 입력칸 포커스 추적

    var body: some View {
        ZStack {
            NavigationSplitView {
                // [Column 1] Sidebar (📐 다시 조절 가능 - 조작감은 유지하면서 너비만 자유롭게!)
                SidebarView(previewManager: previewManager, currentFolder: {
                    (activePane == .left ? leftPane : rightPane).currentPath
                }, onSelectLocation: { url in
                    if activePane == .left {
                        leftPane.navigateTo(url)
                    } else {
                        rightPane.navigateTo(url)
                    }
                })
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 500)
            } content: {
                // [Column 2] Left Mirror Pane
                FilePaneView(viewModel: leftPane, previewManager: previewManager, pane: .left, focusedField: $focusedField, onActivate: {
                    activePane = .left
                }, onRequestPaneSwitch: { target in switchPane(to: target) })
                .overlay {
                    if activePane == .left {
                        Rectangle().stroke(Color.accentColor, lineWidth: 3)
                    }
                }
                .navigationSplitViewColumnWidth(min: 300, ideal: 500, max: 3000)
            } detail: {
                // [Column 3] Right Mirror Pane
                FilePaneView(viewModel: rightPane, previewManager: previewManager, pane: .right, focusedField: $focusedField, onActivate: {
                    activePane = .right
                }, onRequestPaneSwitch: { target in switchPane(to: target) })
                .overlay {
                    if activePane == .right {
                        Rectangle().stroke(Color.accentColor, lineWidth: 3)
                    }
                }
                .navigationSplitViewColumnWidth(min: 300, ideal: 500, max: 3000)
            }
            // ⌨️ [전역 키보드 관제탑] 활성화된 패널로 정확히 명령 배달!
            Group {
                // Cmd + N: 새 폴더 만들기
                Button("") {
                    if activePane == .left { leftPane.startCreatingFolder() }
                    else { rightPane.startCreatingFolder() }
                }
                .keyboardShortcut("n", modifiers: [.command])
                
                Button("") { currentPane.goBack() }
                    .keyboardShortcut("[", modifiers: [.command])
                Button("") { currentPane.goForward() }
                    .keyboardShortcut("]", modifiers: [.command])
                Button("") { currentPane.toggleHiddenFiles() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .frame(minWidth: 1100, minHeight: 700)
        .overlay(alignment: .bottom) {
            if isShowingPermissionBanner {
                permissionBanner
            }
        }
        .onAppear {
            rightPane.oppositePaneKeyCode = 123
            leftPane.requestFocus()
            checkFullDiskAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkFullDiskAccess()
        }
        .onChange(of: focusedField) { _, newValue in
            // 목록을 직접 클릭해 포커스가 옮겨가면 활성 패널도 따라갑니다.
            if let pane = newValue?.pane {
                activePane = pane
            }
        }
    }

    private static func initialPath(forKey key: String) -> URL {
        #if DEBUG
        // UI 점검용: 실행 인자로 시작 폴더를 지정합니다. (-leftPath /경로 -rightPath /경로)
        if let path = UserDefaults.standard.string(forKey: key) {
            return URL(fileURLWithPath: path)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private var currentPane: FilePaneViewModel {
        activePane == .left ? leftPane : rightPane
    }
    
    // 키보드 방향키로 패널을 명시적으로 전환합니다.
    private func switchPane(to target: ActivePane) {
        let pane = target == .left ? leftPane : rightPane
        activePane = target
        if pane.selectedFiles.isEmpty, let first = pane.files.first {
            pane.selectedFiles = [first]
        }
        pane.requestFocus()
    }

    private func checkFullDiskAccess() {
        let hasAccess = MacSystemService().hasFullDiskAccess()
        if hasAccess && isShowingPermissionBanner {
            leftPane.loadFiles()
            rightPane.loadFiles()
        }
        isShowingPermissionBanner = !hasAccess
    }

    // 작업을 막지 않는 권한 안내
    private var permissionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("전체 디스크 접근 권한을 허용하면 폴더마다 묻지 않습니다")
                    .font(.headline)
                Text("시스템 설정에서 이 앱을 켠 뒤 앱을 다시 실행해 주세요.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("시스템 설정 열기") { leftPane.openSystemPrivacySettings() }
                .buttonStyle(.borderedProminent)
            Button("앱 위치 보기") { leftPane.revealAppInFinder() }
            Button("닫기") { isShowingPermissionBanner = false }
        }
        .padding(12)
        .background(.regularMaterial)
        .cornerRadius(10)
        .shadow(radius: 6)
        .padding(16)
    }
}

#Preview {
    ContentView()
}
