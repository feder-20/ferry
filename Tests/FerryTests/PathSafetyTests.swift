import XCTest
@testable import Ferry

final class PathSafetyTests: XCTestCase {
    var root: URL!   // carpeta temporal resuelta
    var home: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FerryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: PathSafety.resolve(base.path))
        home = root.appendingPathComponent("home", isDirectory: true)
        for d in ["Library/LaunchAgents", ".ssh", ".config/x", "Documents/Dest", "stash/abc"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(d),
                                                    withIntermediateDirectories: true)
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func validate(_ p: String) -> Result<URL, PathSafety.BringError> {
        PathSafety.validateBringPath(p, home: home, systemRoots: [])
    }

    // MARK: ferry://bring

    func testAcceptsNormalFolder() throws {
        let p = home.appendingPathComponent("Documents/Dest").path
        XCTAssertEqual(try validate(p).get().path, p)
    }
    func testRejectsRelativeAndMissingAndFile() throws {
        XCTAssertEqual(validate("Documents"), .failure(.notAbsolute))
        XCTAssertEqual(validate(home.path + "/nope"), .failure(.notFound))
        let f = home.appendingPathComponent("Documents/a.txt")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(validate(f.path), .failure(.notDirectory))
    }
    func testRejectsUserLibraryAndSubfolders() {
        XCTAssertEqual(validate(home.path + "/Library"), .failure(.forbidden))
        XCTAssertEqual(validate(home.path + "/Library/LaunchAgents"), .failure(.forbidden))
    }
    func testRejectsHiddenAndSSH() {
        XCTAssertEqual(validate(home.path + "/.ssh"), .failure(.forbidden))
        XCTAssertEqual(validate(home.path + "/.config/x"), .failure(.forbidden))
    }
    func testRejectsDotDotTraversal() {
        XCTAssertEqual(validate(home.path + "/Documents/../Library/LaunchAgents"), .failure(.forbidden))
    }
    func testRejectsSymlinkIntoForbidden() throws {
        let link = home.appendingPathComponent("Documents/enlace")
        try FileManager.default.createSymbolicLink(at: link,
            withDestinationURL: home.appendingPathComponent("Library/LaunchAgents"))
        XCTAssertEqual(validate(link.path), .failure(.forbidden))
    }
    func testRejectsSystemFoldersWithDefaultRoots() {
        let h = FileManager.default.homeDirectoryForCurrentUser
        for p in ["/System", "/Library", "/Applications", "/usr", "/usr/local", "/bin", "/etc", "/private",
                  "/private/tmp", "/tmp", "/Volumes", "/"] {
            if let r = Optional(PathSafety.validateBringPath(p, home: h)), case .success = r {
                XCTFail("\(p) no debería aceptarse")
            }
        }
        XCTAssertTrue(PathSafety.isForbidden(h.path + "/Library/LaunchAgents", home: h))
        XCTAssertTrue(PathSafety.isForbidden(h.path + "/.ssh", home: h))
        XCTAssertFalse(PathSafety.isForbidden(h.path + "/Documents", home: h))
        XCTAssertFalse(PathSafety.isForbidden("/Volumes/Disco/Carpeta", home: h))
    }
    func testBringPathParsing() {
        XCTAssertEqual(PathSafety.bringPath(from: URL(string: "ferry://bring?path=%2FUsers%2Fa%20b")!), "/Users/a b")
        XCTAssertNil(PathSafety.bringPath(from: URL(string: "ferry://other?path=/x")!))
        XCTAssertNil(PathSafety.bringPath(from: URL(string: "https://bring?path=/x")!))
        XCTAssertNil(PathSafety.bringPath(from: URL(string: "ferry://bring?path=")!))
    }

    // MARK: isInStash / historial

    func testIsInside() throws {
        let stash = home.appendingPathComponent("stash").path
        XCTAssertTrue(PathSafety.isInside(stash + "/abc/f.txt", base: stash))
        XCTAssertFalse(PathSafety.isInside(stash, base: stash))
        XCTAssertFalse(PathSafety.isInside(stash + "-otro/f", base: stash)) // prefijo sin «/»
        XCTAssertFalse(PathSafety.isInside(stash + "/../Documents", base: stash))
        // symlink dentro del stash que apunta fuera
        let link = home.appendingPathComponent("stash/abc/fuera")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("Documents"))
        XCTAssertFalse(PathSafety.isInside(link.path, base: stash))
    }
    func testValidStashEntryNeedsOwnSubfolder() {
        let stash = home.appendingPathComponent("stash").path
        XCTAssertTrue(PathSafety.isValidStashEntry(stash + "/abc/f.txt", stashDir: stash))
        // directamente bajo Cortados: borrar su padre vaciaría todo el stash
        XCTAssertFalse(PathSafety.isValidStashEntry(stash + "/f.txt", stashDir: stash))
        XCTAssertFalse(PathSafety.isValidStashEntry(home.path + "/Documents/f.txt", stashDir: stash))
        XCTAssertFalse(PathSafety.isValidStashEntry("/etc/passwd", stashDir: stash))
    }
    func testModelIsInStash() {
        XCTAssertTrue(ShelfModel.isInStash(ShelfModel.stashDir.appendingPathComponent("x/y")))
        XCTAssertFalse(ShelfModel.isInStash(ShelfModel.stashDir))
        XCTAssertFalse(ShelfModel.isInStash(URL(fileURLWithPath: NSHomeDirectory() + "/Documents")))
    }
    func testPlausibleDestinationAndOriginal() {
        let d = home.path + "/Documents/Dest"
        XCTAssertTrue(PathSafety.isPlausibleDestination(d + "/foto.png", name: "foto.png", home: home, systemRoots: []))
        XCTAssertTrue(PathSafety.isPlausibleDestination(d + "/foto 2.png", name: "foto.png", home: home, systemRoots: []))
        XCTAssertTrue(PathSafety.isPlausibleDestination(d + "/dir 3", name: "dir", home: home, systemRoots: []))
        XCTAssertFalse(PathSafety.isPlausibleDestination(d + "/otro.png", name: "foto.png", home: home, systemRoots: []))
        XCTAssertFalse(PathSafety.isPlausibleDestination(home.path + "/Library/LaunchAgents/foto.png", name: "foto.png", home: home, systemRoots: []))
        XCTAssertFalse(PathSafety.isPlausibleDestination("relativa/foto.png", name: "foto.png", home: home, systemRoots: []))
        XCTAssertTrue(PathSafety.isValidOriginal(d + "/foto.png", name: "foto.png", home: home, systemRoots: []))
        XCTAssertFalse(PathSafety.isValidOriginal(home.path + "/Library/LaunchAgents/foto.png", name: "foto.png", home: home, systemRoots: []))
        XCTAssertFalse(PathSafety.isValidOriginal(d + "/x.png", name: "foto.png", home: home, systemRoots: []))
    }

    // MARK: Solo copia por URL

    func testURLDeliveryNeverCuts() {
        for moveMode in [true, false] {
            XCTAssertFalse(DeliveryPolicy.shouldCut(moveMode: moveMode, origin: .url))
        }
        XCTAssertTrue(DeliveryPolicy.shouldCut(moveMode: true, origin: .user))
        XCTAssertFalse(DeliveryPolicy.shouldCut(moveMode: false, origin: .user))
    }

    // MARK: Portapapeles

    func testPasteboardPolicy() {
        XCTAssertFalse(PasteboardPolicy.isRestorable(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(PasteboardPolicy.isRestorable(types: ["public.utf8-plain-text"]))
        XCTAssertTrue(PasteboardPolicy.shouldRestore(currentChangeCount: 5, ourChangeCount: 5))
        XCTAssertFalse(PasteboardPolicy.shouldRestore(currentChangeCount: 6, ourChangeCount: 5))
    }
}
