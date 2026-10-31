import XCTest
@testable import ShooneeFileManager

@MainActor
final class SidebarTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("ShooneeSidebar-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "ShooneeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? fm.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDefaultsAppearOnFirstRun() async {
        let store = FavoritesStore(defaults: defaults)
        XCTAssertEqual(store.items.map(\.name), ["Home", "Downloads", "Desktop", "Documents", "Root"])
    }

    func testAddPersistsAcrossLaunches() async throws {
        let url = try folder("Projects")
        XCTAssertTrue(FavoritesStore(defaults: defaults).add(url))

        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reloaded.items.last?.name, "Projects")
        XCTAssertEqual(reloaded.items.last?.icon, "folder")
    }

    func testDuplicateAndFileAreRejected() async throws {
        let url = try folder("Projects")
        let file = root.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let store = FavoritesStore(defaults: defaults)

        XCTAssertTrue(store.add(url))
        XCTAssertFalse(store.add(url))
        XCTAssertFalse(store.add(file))
        XCTAssertFalse(store.add(root.appendingPathComponent("missing")))
    }

    func testRemoveAndMovePersist() async throws {
        let store = FavoritesStore(defaults: defaults)
        store.remove(store.items[1])
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reloaded.items.map(\.name), ["Desktop", "Documents", "Home", "Root"])
    }

    func testRemovingEverythingDoesNotRestoreDefaults() async {
        let store = FavoritesStore(defaults: defaults)
        store.items.forEach(store.remove)
        XCTAssertTrue(FavoritesStore(defaults: defaults).items.isEmpty)
    }

    func testServerAddressForms() {
        XCTAssertEqual(ServerAddress.url(from: "smb://nas/share")?.absoluteString, "smb://nas/share")
        XCTAssertEqual(ServerAddress.url(from: "nas/share")?.absoluteString, "smb://nas/share")
        XCTAssertEqual(ServerAddress.url(from: "  \\\\192.168.0.10\\공유 폴더 ")?.scheme, "smb")
        XCTAssertEqual(ServerAddress.url(from: "\\\\192.168.0.10\\share")?.host, "192.168.0.10")
        XCTAssertEqual(ServerAddress.url(from: "smb://nas/내 폴더")?.path, "/내 폴더")
    }

    func testInvalidServerAddressesAreRejected() {
        XCTAssertNil(ServerAddress.url(from: ""))
        XCTAssertNil(ServerAddress.url(from: "http://example.com"))
        XCTAssertNil(ServerAddress.url(from: "file:///etc"))
        XCTAssertNil(ServerAddress.url(from: "smb://"))
    }
}
