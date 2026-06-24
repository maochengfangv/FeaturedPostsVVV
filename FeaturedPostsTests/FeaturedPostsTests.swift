//
//  FeaturedPostsTests.swift
//  FeaturedPostsTests
//
//  Created by maochengfang on 2026/6/24.
//

import XCTest
import UIKit
@testable import FeaturedPosts

final class FeaturedPostsTests: XCTestCase {
    func testLRUEvictionByCost() {
        let cache = LRUCache<String, Int>(totalCostLimit: 3)
        cache.setValue(1, forKey: "a", cost: 1)
        cache.setValue(2, forKey: "b", cost: 1)
        cache.setValue(3, forKey: "c", cost: 1)

        _ = cache.value(forKey: "a")
        cache.setValue(4, forKey: "d", cost: 1)

        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertEqual(cache.value(forKey: "a"), 1)
        XCTAssertEqual(cache.value(forKey: "c"), 3)
        XCTAssertEqual(cache.value(forKey: "d"), 4)
    }

    func testRateLimiterAllowsBurstThenBlocks() {
        let limiter = RateLimiter(maxTokens: 2, refillInterval: 1.0)
        XCTAssertTrue(limiter.tryAcquire())
        XCTAssertTrue(limiter.tryAcquire())
        XCTAssertFalse(limiter.tryAcquire())
    }

    func testSQLitePostStoreSaveAndFetch() throws {
        let store = try SQLitePostStore(directory: FileManager.default.temporaryDirectory)
        let posts = (0..<3).map { idx in
            Post(
                id: "p_\(idx)",
                author: "a",
                text: "t_\(idx)",
                imageURLs: [URL(string: "https://picsum.photos/id/\(idx)/300/300")!],
                createdAt: Date(timeIntervalSince1970: TimeInterval(idx))
            )
        }

        try store.save(posts: posts)
        let fetched = try store.fetchLatest(limit: 10)

        XCTAssertEqual(Set(fetched.map { $0.id }), Set(posts.map { $0.id }))
    }

    func testPublishValidator() {
        let v = PublishValidator(maxImages: 9, maxTextLength: 1000)
        XCTAssertNoThrow(try v.validate(text: "hi", imagesCount: 1))
        XCTAssertThrowsError(try v.validate(text: "", imagesCount: 1))
        XCTAssertThrowsError(try v.validate(text: "hi", imagesCount: 0))
    }

    func testImageCompressorReducesBytes() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 2000))
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 2000))
        }

        let input = image.jpegData(compressionQuality: 1.0)!
        let compressor = ImageCompressor()
        let output = try compressor.compressToJPEG(image: image, maxByteSize: 200 * 1024, targetMaxPixel: 1280)

        XCTAssertGreaterThan(input.count, output.count)
        XCTAssertLessThanOrEqual(output.count, 200 * 1024)
    }
}
