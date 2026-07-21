import XCTest
import AppKit
@testable import ShakaPachi

final class TrayIconRendererTests: XCTestCase {

    func testAllFourStatesDefined() {
        XCTAssertEqual(TrayIconState.allCases.count, 4)
    }

    func testNormalMenuBarImageIsTemplate() {
        XCTAssertTrue(TrayIconRenderer.menuBarImage(for: .normal).isTemplate)
    }

    func testColouredMenuBarImagesAreNotTemplate() {
        for state in [TrayIconState.settings, .permission, .restricted] {
            XCTAssertFalse(TrayIconRenderer.menuBarImage(for: state).isTemplate)
        }
    }

    func testEveryStateHasCardNameAndDetail() {
        for state in TrayIconState.allCases {
            XCTAssertFalse(state.cardName.isEmpty)
            XCTAssertFalse(state.detail.isEmpty)
        }
    }

    func testPreviewImageHasRequestedSize() {
        let img = TrayIconRenderer.previewImage(for: .normal, size: 32)
        XCTAssertEqual(img.size.width, 32, accuracy: 0.01)
        XCTAssertEqual(img.size.height, 32, accuracy: 0.01)
    }
}
