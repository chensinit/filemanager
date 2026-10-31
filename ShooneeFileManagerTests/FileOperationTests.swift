import XCTest
import AppKit
@testable import ShooneeFileManager

/// 임시 폴더와 전용 클립보드만 사용합니다. 실제 파일과 시스템 클립보드는 건드리지 않습니다.
@MainActor
final class FileOperationTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var destination: URL!
    private var pasteboard: NSPasteboard!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("ShooneeTests-\(UUID().uuidString)")
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: .init("ShooneeTests-\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        try? fm.removeItem(at: root)
    }

    private func write(_ name: String, in directory: URL, content: String = "data") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func makePane(at url: URL) -> FilePaneViewModel {
        FilePaneViewModel(initialPath: url, pasteboard: pasteboard)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testReplacingItemWithItselfDuringMoveKeepsFile() throws {
        let file = try write("a.txt", in: source, content: "important")
        try? FileSystemService().transferItem(at: file, to: file, isMove: true, overwrite: true)
        XCTAssertEqual(read(file), "important")
    }

    func testCopyFromAnotherAppAfterCutDoesNotMoveSource() async throws {
        let cutFile = try write("cut.txt", in: source)
        let externalFile = try write("external.txt", in: source)
        let pane = makePane(at: source)
        await waitUntil { pane.files.count == 2 }

        pane.selectedFiles = Set(pane.files.filter { $0.url.lastPathComponent == "cut.txt" })
        pane.copySelection(isCut: true)

        // 다른 앱이 클립보드를 새로 쓴 상황
        pasteboard.clearContents()
        pasteboard.writeObjects([externalFile as NSURL])

        pane.navigateTo(destination)
        pane.pasteClipboard()

        let pasted = destination.appendingPathComponent("external.txt")
        await waitUntil { self.fm.fileExists(atPath: pasted.path) }
        XCTAssertTrue(fm.fileExists(atPath: pasted.path))
        XCTAssertTrue(fm.fileExists(atPath: externalFile.path), "복사인데 원본이 사라졌습니다")
        XCTAssertTrue(fm.fileExists(atPath: cutFile.path))
    }

    func testUnreadableFolderDoesNotShowPreviousFolderContents() async throws {
        _ = try write("old.txt", in: source)
        let pane = makePane(at: source)
        await waitUntil { pane.files.count == 1 }

        pane.navigateTo(root.appendingPathComponent("missing"))
        await waitUntil { pane.files.isEmpty }
        XCTAssertTrue(pane.files.isEmpty, "다른 경로인데 이전 폴더 목록이 남아 있습니다")
    }

    private func clipboardPane(copying urls: [URL], at url: URL, isCut: Bool = false) -> FilePaneViewModel {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        if isCut {
            pasteboard.setString("1", forType: FilePaneViewModel.cutFlagType)
        }
        return makePane(at: url)
    }

    func testCutThenPasteMovesAndConsumesClipboard() async throws {
        let file = try write("a.txt", in: source)
        let pane = makePane(at: source)
        await pane.loadFiles().value
        pane.selectedFiles = Set(pane.files)
        pane.copySelection(isCut: true)

        pane.navigateTo(destination)
        await pane.pasteClipboard().value

        XCTAssertFalse(fm.fileExists(atPath: file.path))
        XCTAssertNotNil(read(destination.appendingPathComponent("a.txt")))
        XCTAssertNil(pasteboard.string(forType: FilePaneViewModel.cutFlagType))
        XCTAssertNil(pane.errorMessage, "두 번째 붙여넣기가 실패하지 않도록 클립보드가 비워져야 합니다")
    }

    func testCutPasteIntoSameFolderIsNoOp() async throws {
        let file = try write("a.txt", in: source, content: "important")
        let pane = clipboardPane(copying: [file], at: source, isCut: true)
        await pane.pasteClipboard().value

        XCTAssertEqual(read(file), "important")
        XCTAssertNil(pane.pendingConflict)
    }

    func testCopyPasteIntoSameFolderMakesCopy() async throws {
        let file = try write("a.txt", in: source)
        let pane = clipboardPane(copying: [file], at: source)
        await pane.pasteClipboard().value
        await pane.pasteClipboard().value

        XCTAssertNotNil(read(file))
        XCTAssertNotNil(read(source.appendingPathComponent("a 복사본.txt")))
        XCTAssertNotNil(read(source.appendingPathComponent("a 복사본 2.txt")))
    }

    func testFolderCannotBePastedIntoItself() async throws {
        let folder = source.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let pane = clipboardPane(copying: [folder], at: folder)
        await pane.pasteClipboard().value

        XCTAssertNotNil(pane.errorMessage)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), [])
    }

    func testReplacingFolderWithItsOwnChildKeepsData() throws {
        let parent = source.appendingPathComponent("x")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let child = try write("x", in: parent, content: "child")
        XCTAssertThrowsError(try FileSystemService().transferItem(at: child, to: parent, isMove: true, overwrite: true))
        XCTAssertEqual(read(child), "child")
    }

    func testSkippingConflictStillTransfersRemainingItems() async throws {
        let a = try write("a.txt", in: source, content: "new")
        let b = try write("b.txt", in: source)
        let c = try write("c.txt", in: source)
        _ = try write("b.txt", in: destination, content: "existing")

        let pane = clipboardPane(copying: [a, b, c], at: destination)
        await pane.pasteClipboard().value
        XCTAssertEqual(pane.pendingConflict?.src.lastPathComponent, "b.txt")
        XCTAssertTrue(pane.isShowingConflictAlert)

        await pane.resolveConflict(.skip).value
        XCTAssertNil(pane.pendingConflict)
        XCTAssertEqual(read(destination.appendingPathComponent("b.txt")), "existing")
        XCTAssertNotNil(read(destination.appendingPathComponent("a.txt")))
        XCTAssertNotNil(read(destination.appendingPathComponent("c.txt")), "충돌 뒤의 파일이 누락됐습니다")
    }

    func testReplacingConflictOverwritesAndContinues() async throws {
        let a = try write("a.txt", in: source, content: "new")
        let b = try write("b.txt", in: source)
        _ = try write("a.txt", in: destination, content: "existing")

        let pane = clipboardPane(copying: [a, b], at: destination)
        await pane.pasteClipboard().value
        await pane.resolveConflict(.replace).value

        XCTAssertEqual(read(destination.appendingPathComponent("a.txt")), "new")
        XCTAssertNotNil(read(destination.appendingPathComponent("b.txt")))
    }

    func testCancelConflictStopsRemainingItemsAndKeepsCutClipboard() async throws {
        let a = try write("a.txt", in: source)
        let b = try write("b.txt", in: source)
        _ = try write("a.txt", in: destination, content: "existing")

        let pane = clipboardPane(copying: [a, b], at: destination, isCut: true)
        await pane.pasteClipboard().value
        await pane.resolveConflict(.cancel).value

        XCTAssertTrue(fm.fileExists(atPath: a.path))
        XCTAssertTrue(fm.fileExists(atPath: b.path))
        XCTAssertEqual(read(destination.appendingPathComponent("a.txt")), "existing")
        XCTAssertNotNil(pasteboard.string(forType: FilePaneViewModel.cutFlagType))
    }

    func testTargetFolderIsFixedWhenPasteStarts() async throws {
        let a = try write("a.txt", in: source)
        let other = root.appendingPathComponent("other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)

        let pane = clipboardPane(copying: [a], at: destination)
        let task = pane.pasteClipboard()
        pane.navigateTo(other)
        await task.value

        XCTAssertNotNil(read(destination.appendingPathComponent("a.txt")))
        XCTAssertFalse(fm.fileExists(atPath: other.appendingPathComponent("a.txt").path))
    }

    func testFailedDropReportsErrorAndDoesNotPasteClipboard() async throws {
        let dropped = try write("dropped.txt", in: source)
        let inClipboard = try write("clipboard.txt", in: source)
        let pane = clipboardPane(copying: [inClipboard], at: destination)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destination.path)

        await pane.transfer([dropped], isMove: false).value

        XCTAssertNotNil(pane.errorMessage)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: destination.path), [])
    }

    func testLoadErrorIsExposedAndClearedAfterSuccess() async throws {
        let pane = makePane(at: root.appendingPathComponent("missing"))
        await pane.loadFiles().value
        XCTAssertNotNil(pane.loadError)

        pane.navigateTo(source)
        await pane.loadFiles().value
        XCTAssertNil(pane.loadError)
    }

    func testPasteIntoMissingFolderExplainsDestinationProblem() async throws {
        let file = try write("a.txt", in: source)
        let pane = clipboardPane(copying: [file], at: root.appendingPathComponent("missing"))
        await pane.pasteClipboard().value

        XCTAssertTrue(pane.errorMessage?.contains("대상 폴더") == true)
        XCTAssertTrue(fm.fileExists(atPath: file.path))
    }

    func testFirstFileFollowsListOrderNotSetOrder() async throws {
        for name in ["a.txt", "b.txt", "c.txt", "d.txt"] { _ = try write(name, in: source) }
        let pane = makePane(at: source)
        await pane.loadFiles().value

        pane.selectedFiles = Set(pane.files.dropFirst())
        XCTAssertEqual(pane.firstFile(in: pane.selectedFiles)?.name, "b.txt")
    }

    func testInvalidTypedPathKeepsCurrentFolder() async throws {
        _ = try write("a.txt", in: source)
        let pane = makePane(at: source)
        await pane.loadFiles().value

        XCTAssertFalse(pane.navigateToTypedPath(root.appendingPathComponent("missing").path))
        await pane.loadFiles().value

        XCTAssertEqual(pane.currentPath, source)
        XCTAssertEqual(pane.files.count, 1)
        XCTAssertNotNil(pane.errorMessage)
    }

    func testTypedPathToFileIsRejected() async throws {
        let file = try write("a.txt", in: source)
        let pane = makePane(at: source)

        XCTAssertFalse(pane.navigateToTypedPath(file.path))
        XCTAssertEqual(pane.currentPath, source)
    }

    func testValidTypedPathNavigates() async throws {
        let pane = makePane(at: source)

        XCTAssertTrue(pane.navigateToTypedPath("  \(destination.path)  "))
        XCTAssertEqual(pane.currentPath.path, destination.path)
    }

    func testRenameMovesFile() async throws {
        let file = try write("a.txt", in: source)
        let pane = makePane(at: source)
        await pane.loadFiles().value

        pane.selectedFiles = Set(pane.files)
        pane.startRenaming()
        XCTAssertEqual(pane.renameText, "a.txt")
        pane.renameText = "b.txt"
        pane.commitRename()

        XCTAssertFalse(fm.fileExists(atPath: file.path))
        XCTAssertNotNil(read(source.appendingPathComponent("b.txt")))
    }

    func testRenameRejectsExistingAndInvalidNames() async throws {
        let a = try write("a.txt", in: source, content: "a")
        _ = try write("b.txt", in: source, content: "b")
        let service = FileSystemService()

        XCTAssertThrowsError(try service.renameItem(at: a, to: "b.txt"))
        XCTAssertThrowsError(try service.renameItem(at: a, to: "x/y"))
        XCTAssertThrowsError(try service.renameItem(at: a, to: "   "))
        XCTAssertEqual(read(a), "a")
    }

    func testRenameAllowsCaseOnlyChange() async throws {
        let a = try write("a.txt", in: source)
        try FileSystemService().renameItem(at: a, to: "A.txt")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: source.path), ["A.txt"])
    }

    func testSortingKeepsFoldersFirst() async throws {
        _ = try write("big.txt", in: source, content: String(repeating: "x", count: 100))
        _ = try write("small.txt", in: source, content: "x")
        try fm.createDirectory(at: source.appendingPathComponent("zfolder"), withIntermediateDirectories: true)
        let pane = makePane(at: source)
        await pane.loadFiles().value

        XCTAssertEqual(pane.files.map(\.name), ["zfolder", "big.txt", "small.txt"])
        pane.setSort(.size, ascending: true)
        XCTAssertEqual(pane.files.map(\.name), ["zfolder", "small.txt", "big.txt"])
        pane.setSort(.size, ascending: false)
        XCTAssertEqual(pane.files.map(\.name), ["zfolder", "big.txt", "small.txt"])
    }

    func testSearchFiltersAndDropsHiddenSelection() async throws {
        _ = try write("report.txt", in: source)
        _ = try write("photo.png", in: source)
        let pane = makePane(at: source)
        await pane.loadFiles().value
        pane.selectedFiles = Set(pane.files)

        pane.searchText = "REP"
        XCTAssertEqual(pane.files.map(\.name), ["report.txt"])
        XCTAssertEqual(pane.selectedFiles.map(\.name), ["report.txt"])

        pane.searchText = ""
        XCTAssertEqual(pane.files.count, 2)
    }

    func testHiddenFilesToggle() async throws {
        _ = try write(".secret", in: source)
        _ = try write("visible.txt", in: source)
        let pane = makePane(at: source)
        await pane.loadFiles().value
        XCTAssertEqual(pane.files.count, 1)

        pane.showsHiddenFiles = true
        await pane.loadFiles().value
        XCTAssertEqual(pane.files.count, 2)
    }

    func testBackAndForwardHistory() async throws {
        let pane = makePane(at: source)
        XCTAssertFalse(pane.canGoBack)

        pane.navigateTo(destination)
        pane.navigateTo(root)
        pane.goBack()
        XCTAssertEqual(pane.currentPath, destination)
        pane.goBack()
        XCTAssertEqual(pane.currentPath, source)
        XCTAssertFalse(pane.canGoBack)
        pane.goForward()
        XCTAssertEqual(pane.currentPath, destination)

        pane.navigateTo(source)
        XCTAssertFalse(pane.canGoForward, "새로 이동하면 앞으로 기록은 지워져야 합니다")
    }

    func testExternalChangeRefreshesListAutomatically() async throws {
        let pane = makePane(at: source)
        await pane.loadFiles().value
        XCTAssertTrue(pane.files.isEmpty)

        _ = try write("from-another-app.txt", in: source)
        await waitUntil { pane.files.count == 1 }
        XCTAssertEqual(pane.files.first?.name, "from-another-app.txt")
    }

    func testDropOntoFolderTargetsThatFolder() async throws {
        let dropped = try write("a.txt", in: source)
        let pane = makePane(at: source)
        XCTAssertTrue(pane.handleDrop([dropped], isMove: true, to: destination))
        await waitUntil { self.fm.fileExists(atPath: self.destination.appendingPathComponent("a.txt").path) }

        XCTAssertFalse(fm.fileExists(atPath: dropped.path))
        XCTAssertNotNil(read(destination.appendingPathComponent("a.txt")))
    }

    func testCancelTransferSkipsRemainingItems() async throws {
        let urls = try ["a", "b", "c"].map { try write("\($0).txt", in: source) }
        let pane = makePane(at: destination)
        let task = pane.transfer(urls, isMove: false)
        pane.cancelTransfer()
        await task.value

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: destination.path), ["a.txt"])
        XCTAssertNil(pane.transferStatus)
    }
}
