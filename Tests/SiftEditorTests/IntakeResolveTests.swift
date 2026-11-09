import XCTest
@testable import SiftEditorCore

/// 目标打开的解析。这是**在一处完成判决**的入口点，所以我们在这里进行修复。
/// 当它崩溃时，命令行、拖放和最近使用的项目的行为有所不同。
final class IntakeResolveTests: XCTestCase {

    func testRemoteFormsResolveToRemote() {
        XCTAssertEqual(
            Intake.resolve("ssh web01:/var/log/app.log"),
            .remote(RemoteFile.Target(host: "web01", path: "/var/log/app.log"))
        )
        XCTAssertEqual(
            Intake.resolve("deploy@web01:/srv/app/current/log/production.log"),
            .remote(RemoteFile.Target(host: "deploy@web01", path: "/srv/app/current/log/production.log"))
        )
    }

    func testPlainPathsStayLocal() {
        XCTAssertEqual(Intake.resolve("/var/log/app.log"), .local(URL(fileURLWithPath: "/var/log/app.log")))
    }

    /// **如果你不确定，就直接击败它。** 如果你远程击败它，你可能会意外地飞到 ssh。
    func testAmbiguousStringsStayLocal() {
        for text in ["C:/Users/x/app.log", "web01:relative/path.log", "12:34:56.log", "app.log"] {
            guard case .local = Intake.resolve(text) else {
                return XCTFail("\(text) を遠隔と判定した")
            }
        }
    }

    func testTildeIsExpandedForLocalPaths() {
        guard case .local(let url) = Intake.resolve("~/app.log") else { return XCTFail("local を期待") }
        XCTAssertFalse(url.path.hasPrefix("~"))
        XCTAssertTrue(url.path.hasSuffix("/app.log"))
    }
}
