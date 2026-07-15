import XCTest
@testable import AiUsage

@MainActor
final class UpdateStatusModelTests: XCTestCase {
    func testPreviewUpdateExposesVersionsWithoutStartingARealCheck() {
        let model = UpdateStatusModel(
            currentVersion: "1.2.0",
            previewAvailableVersion: "1.3.0"
        )

        XCTAssertEqual(model.currentVersion, "1.2.0")
        XCTAssertEqual(model.latestVersion, "1.3.0")
        XCTAssertEqual(model.availableVersion, "1.3.0")
        XCTAssertTrue(model.isPreviewingUpdate)
        XCTAssertFalse(model.isChecking)

        model.beginChecking()
        XCTAssertFalse(model.isChecking)
    }

    func testNormalModelStartsWaitingForItsFirstUpdateCheck() {
        let model = UpdateStatusModel(currentVersion: "1.2.0")

        XCTAssertEqual(model.currentVersion, "1.2.0")
        XCTAssertNil(model.latestVersion)
        XCTAssertNil(model.availableVersion)
        XCTAssertFalse(model.isPreviewingUpdate)
        XCTAssertTrue(model.isChecking)
    }
}
