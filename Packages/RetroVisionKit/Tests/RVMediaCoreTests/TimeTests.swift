import CoreMedia
import XCTest
@testable import RVMediaCore

final class TimeAndMathTests: XCTestCase {
    func testPresentationTimeHasNoAccumulatedDrift() {
        // 29.97 で 1 時間（108000 帧）進めたとき、丸めの積算で 1 帧もずれないこと（01 §2）。
        let fps = FrameRate.ntsc
        let ts: Int32 = 90_000
        let last = fps.presentationTime(frameIndex: 107_999, timescale: ts)
        let expectedSeconds = 107_999.0 * 1_001 / 30_000.0
        XCTAssertEqual(CMTimeGetSeconds(last), expectedSeconds, accuracy: 1.0 / Double(ts))
    }

    func testFrameIndexInverseIsStable() {
        let fps = FrameRate.pal
        for n: Int64 in [0, 1, 2, 24, 25, 26, 1_000] {
            let t = fps.presentationTime(frameIndex: n, timescale: 1_000)
            XCTAssertEqual(fps.frameIndex(containing: t), n, "frame \(n)")
        }
    }

    func testHalfEvenRounding() {
        XCTAssertEqual(MediaMath.roundHalfEvenDivide(5, 2), 2)
        XCTAssertEqual(MediaMath.roundHalfEvenDivide(7, 2), 4)
        XCTAssertEqual(MediaMath.roundHalfEvenDivide(3, 2), 2)
        XCTAssertEqual(MediaMath.roundHalfEvenDivide(-5, 2), -2)
        XCTAssertEqual(MediaMath.floorDiv(-5, 2), -3)
        XCTAssertEqual(MediaMath.ceilDiv(5, 2), 3)
    }

    func testFrameRateIsReduced() {
        XCTAssertEqual(FrameRate(numerator: 30_000, denominator: 1_001), FrameRate.ntsc)
        XCTAssertEqual(FrameRate(numerator: 50, denominator: 2).framesPerSecond, 25)
    }

    func testMediaTimeConversionUsesHalfEven() {
        let t = CMTime(value: 1, timescale: 3)
        let converted = t.converted(to: 90_000)
        XCTAssertEqual(converted.value, 30_000)
    }

    func testDriftRangeUsesMilliseconds() {
        let t = CMTime(value: 10, timescale: 1)
        let range = t.range(aroundMS: 40)
        XCTAssertEqual(CMTimeGetSeconds(range.duration), 0.08, accuracy: 1e-9)
    }
}
