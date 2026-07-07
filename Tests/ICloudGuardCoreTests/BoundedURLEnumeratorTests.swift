import Foundation
import XCTest
@testable import ICloudGuardCore

final class BoundedURLEnumeratorTests: XCTestCase {
    func testStopsBeforeProcessingNextURLWhenLimitIsReached() {
        let urls = (0..<10).map { URL(fileURLWithPath: "/tmp/item-\($0)") }
        var processed: [URL] = []

        BoundedURLEnumerator.forEachURL(in: urls, shouldStop: { processed.count >= 3 }) { url in
            processed.append(url)
        }

        XCTAssertEqual(processed.map(\.lastPathComponent), ["item-0", "item-1", "item-2"])
    }

    func testNonURLValuesDoNotConsumeLimit() {
        let values: [Any] = [
            "not-a-url",
            URL(fileURLWithPath: "/tmp/a"),
            42,
            URL(fileURLWithPath: "/tmp/b"),
            URL(fileURLWithPath: "/tmp/c"),
        ]
        var processed: [String] = []

        BoundedURLEnumerator.forEachURL(in: values, shouldStop: { processed.count >= 2 }) { url in
            processed.append(url.lastPathComponent)
        }

        XCTAssertEqual(processed, ["a", "b"])
    }
}
