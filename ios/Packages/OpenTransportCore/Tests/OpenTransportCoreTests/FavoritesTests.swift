import XCTest
@testable import OpenTransportCore

final class FavoritesTests: XCTestCase {
    func testReorderAll() {
        XCTAssertEqual(Favorites.reorder(["a", "b", "c"], shown: ["c", "a", "b"]), ["c", "a", "b"])
    }

    func testFilteredReorderKeepsHiddenInPlace() {
        // Only the Metrobús ones (m1, m2) are on screen; EMT ones keep their slots.
        let all = ["emt-1", "mb-m1", "emt-2", "mb-m2"]
        XCTAssertEqual(Favorites.reorder(all, shown: ["mb-m2", "mb-m1"]), ["emt-1", "mb-m2", "emt-2", "mb-m1"])
    }

    func testUnknownOrMissingKeysAreHarmless() {
        XCTAssertEqual(Favorites.reorder(["a", "b"], shown: ["b"]), ["a", "b"])
        XCTAssertEqual(Favorites.reorder(["a", "b"], shown: []), ["a", "b"])
    }
}
