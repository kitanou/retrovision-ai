import XCTest
@testable import RVMediaCore

final class AspectResolverTests: XCTestCase {
    private let ntsc720x480 = PixelSize(width: 720, height: 480)
    private let pal720x576 = PixelSize(width: 720, height: 576)

    /// 05 §6 の注意: 720 幅のまま 10:11 を掛えると 1.364 になる。IFO の 4:3 指示を優先し、
    /// 目標比に合う幅（704）で切り出すこと。
    func testDVD4x3FlagCropsToCleanAperture() {
        let signals = AspectSignals(dvdAspectFlag: .allowed4x3,
                                   sampleAspectFromStandard: .bt601NTSCSample)
        let r = AspectResolver.resolve(codedSize: ntsc720x480, signals: signals, policy: .followSource)
        XCTAssertEqual(r.targetDAR, .dar4x3)
        XCTAssertEqual(r.source, .dvdAspectFlag)
        XCTAssertEqual(r.cleanAperture.width, 704)
        XCTAssertEqual(r.cleanAperture.height, 480)
        XCTAssertEqual(r.cleanAperture.x, 8)
        let displayed = Double(r.cleanAperture.width) * (10.0 / 11.0) / Double(r.cleanAperture.height)
        XCTAssertEqual(displayed, 4.0 / 3.0, accuracy: 0.01)
    }

    func testMPEGDisplayExtensionIsLowerPriorityThanDVDFlag() {
        let signals = AspectSignals(mpegAspectInformation: .dar16x9,
                                   dvdAspectFlag: .allowed4x3,
                                   sampleAspectFromStandard: .bt601NTSCSample)
        let r = AspectResolver.resolve(codedSize: ntsc720x480, signals: signals, policy: .followSource)
        XCTAssertEqual(r.source, .dvdAspectFlag)
        XCTAssertEqual(r.targetDAR, .dar4x3)
    }

    func testPAL4x3CropsTo704() {
        let signals = AspectSignals(mpegAspectInformation: .dar4x3,
                                   sampleAspectFromStandard: .bt601Palsample)
        let r = AspectResolver.resolve(codedSize: pal720x576, signals: signals, policy: .followSource)
        XCTAssertEqual(r.targetDAR, .dar4x3)
        XCTAssertEqual(r.source, .mpegDisplayExtension)
        XCTAssertEqual(r.cleanAperture.width, 704)
        let displayed = Double(r.cleanAperture.width) * (12.0 / 11.0) / 576.0
        XCTAssertEqual(displayed, 4.0 / 3.0, accuracy: 0.01)
    }

    /// 目標比が sample aspect から作る幅より広い場合（PAL の 16:9 を 12:11 で扱うケースなど）、
    /// 切り出せないため letterbox 側で解決する。この組み合わせでは sample aspect の設定違いを
    /// 勝手に補正しない（OQ として素材で検証する）。
    func testTooWideTargetKeepsFullFrameAndDoesNotGuess() {
        let signals = AspectSignals(mpegAspectInformation: .dar16x9,
                                   sampleAspectFromStandard: .bt601Palsample)
        let r = AspectResolver.resolve(codedSize: pal720x576, signals: signals, policy: .followSource)
        XCTAssertEqual(r.cleanAperture.width, 720)
        XCTAssertEqual(r.cleanAperture.x, 0)
        let displayed = Double(r.cleanAperture.width) * (12.0 / 11.0) / 576.0
        XCTAssertEqual(displayed, 1.3636, accuracy: 0.01)
    }

    /// sample aspect だけの素材では、4:3 に既定で倒さない（05 §6）。
    func testSampleAspectOnlyDoesNotGuessDAR() {
        let signals = AspectSignals(sampleAspectFromStandard: .bt601NTSCSample)
        let r = AspectResolver.resolve(codedSize: ntsc720x480, signals: signals, policy: .followSource)
        XCTAssertEqual(r.source, .sampleAspectOnly)
        XCTAssertEqual(r.cleanAperture.width, 720)
    }

    func testUnresolvedIsReported() {
        let r = AspectResolver.resolve(codedSize: PixelSize(width: 640, height: 480),
                                      signals: AspectSignals(), policy: .followSource)
        XCTAssertEqual(r.source, .unresolved)
        XCTAssertEqual(r.targetDAR, .square)
    }

    func testUserOverrideBeatsSourceSignals() {
        let signals = AspectSignals(dvdAspectFlag: .allowed4x3,
                                   sampleAspectFromStandard: .bt601NTSCSample)
        let r = AspectResolver.resolve(codedSize: ntsc720x480, signals: signals,
                                      policy: .explicit(.dar16x9))
        XCTAssertEqual(r.source, .userOverride)
        XCTAssertEqual(r.targetDAR, .dar16x9)
    }

    func testAspectRatioReducesToLowestTerms() {
        XCTAssertEqual(AspectRatio(w: 64, h: 48), .dar4x3)
        XCTAssertEqual(AspectRatio(w: 10, h: 11).value, 10.0 / 11.0, accuracy: 1e-9)
    }

    func testGuessSampleAspectRejectsUnknownSizes() {
        XCTAssertEqual(VideoFormatDescription.guessSampleAspect(codedSize: ntsc720x480), .bt601NTSCSample)
        XCTAssertNil(VideoFormatDescription.guessSampleAspect(codedSize: PixelSize(width: 640, height: 480)))
    }
}
