import XCTest
@testable import RVMediaCore

/// MPEG-2 bitstream からの信号取得。テストに埋めたバイト列は生成 fixture
/// （Scripts/gen-fixtures.sh）から抽出した実データで、ffprobe が読む profile / level /
/// frame rate / field 旗とバイト単位で照合済み（docs/experiments/EXP-001）。
final class MPEG2BitstreamTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return Data(out)
    }

    // fixtures/generated/ntsc480i-22-01.mpg の sequence_header から最初の
    // picture_coding_extension まで（GOP・picture header を含む）。
    private let ntsc = "000001b32d01e02415f92380000001b5148200010000000001b5250202020b420f00000001b80008004000000100000ffff8000001b58ffff30000000001"
    // fixtures/generated/pal576i-22-01.mpg（video_format=PAL を区別できることの確認用）。
    private let pal = "000001b32d02402315f92380000001b5148200010000000001b5230202020b421200000001b80008004000000100000ffff8000001b58ffff30000000001"
    // fixtures/generated/film24p-01.mpg（progressive_sequence=1 の対照）。
    private let film24p = "000001b32d01e02215f92380000001b5148a00010000000001b5250202020b420f00000001b80008004000000100000ffff8000001b58ffff34180000001"

    func testFrameRateCodeTableMatchesGeneratedFixtures() {
        // 実測: 24 / 25 / 29.97 の素材が sequence_header に書く code は 2 / 3 / 4。
        XCTAssertEqual(MPEG2SequenceHeader.baseFrameRate(forCode: 2), .film24)
        XCTAssertEqual(MPEG2SequenceHeader.baseFrameRate(forCode: 3), .pal)
        XCTAssertEqual(MPEG2SequenceHeader.baseFrameRate(forCode: 4), .ntsc)
        XCTAssertEqual(MPEG2SequenceHeader.baseFrameRate(forCode: 5), FrameRate(value: 30))
        XCTAssertEqual(MPEG2SequenceHeader.baseFrameRate(forCode: 6), FrameRate(value: 50))
        XCTAssertEqual(MPEG2SequenceHeader.baseFrameRate(forCode: 7), FrameRate(value: 60))
        XCTAssertNil(MPEG2SequenceHeader.baseFrameRate(forCode: 0))
        XCTAssertNil(MPEG2SequenceHeader.baseFrameRate(forCode: 1))
        XCTAssertNil(MPEG2SequenceHeader.baseFrameRate(forCode: 8))
    }

    func testNTSCFixtureSequenceHeaderAndSequenceExtension() {
        guard let h = MPEG2Bitstream.sequenceHeader(in: bytes(ntsc)) else {
            return XCTFail("sequence_header が見つからない")
        }
        XCTAssertEqual(h.horizontalSize, 720)
        XCTAssertEqual(h.verticalSize, 480)
        XCTAssertEqual(h.aspectRatioInformation, .dar4x3)
        XCTAssertEqual(h.frameRate, .ntsc)
        XCTAssertEqual(h.bitRateValue, 22_500)   // 400 byte/s 単位 → 9 Mbit/s（ffprobe の目標ビットレートと一致）
        // sequence_extension(): ffprobe の profile=Main / level=8 / field 符号化と一致。
        XCTAssertEqual(h.profile, 4)             // Main
        XCTAssertEqual(h.level, 8)               // Main Level
        XCTAssertEqual(h.chromaFormat, 1)        // 4:2:0
        XCTAssertFalse(h.progressiveSequence)    // ffprobe field_order=bb
    }

    func testNTSCFixtureSequenceDisplayExtension() {
        guard let h = MPEG2Bitstream.sequenceHeader(in: bytes(ntsc)) else {
            return XCTFail("sequence_header が見つからない")
        }
        XCTAssertTrue(h.displayExtensionPresent)
        XCTAssertEqual(h.displayVideoFormat, 2)  // NTSC
        XCTAssertTrue(h.displayColourDescription)
        // 生成素材が書く色 code は 2（= unspecified の語彙）。実測の this 値を回帰で固定する。
        XCTAssertEqual(h.displayColorPrimaries, 2)
        XCTAssertEqual(h.displayTransferCharacteristics, 2)
        XCTAssertEqual(h.displayMatrixCoefficients, 2)
        XCTAssertEqual(h.displayHorizontalSize, 720)
        XCTAssertEqual(h.displayVerticalSize, 480)
    }

    func testPALFixtureIsDistinctFromNTSC() {
        guard let h = MPEG2Bitstream.sequenceHeader(in: bytes(pal)) else {
            return XCTFail("sequence_header が見つからない")
        }
        XCTAssertEqual(h.frameRate, .pal)
        XCTAssertEqual(h.verticalSize, 576)
        XCTAssertEqual(h.displayVideoFormat, 1)  // PAL
        XCTAssertFalse(h.progressiveSequence)
    }

    func testFilm24pFixtureDeclaresProgressiveSequence() {
        guard let h = MPEG2Bitstream.sequenceHeader(in: bytes(film24p)) else {
            return XCTFail("sequence_header が見つからない")
        }
        XCTAssertEqual(h.frameRate, .film24)
        XCTAssertTrue(h.progressiveSequence)     // ffprobe field_order=progressive
    }

    func testPictureCodingExtensionFromFixtureBytes() {
        // field 順は picture 层にしかない信号。ffprobe の帧単位 top_field_first=0・
        // interlaced_frame=1 と一致すること（EXP-001）。
        guard let pce = MPEG2Bitstream.pictureCodingExtension(in: bytes(ntsc)) else {
            return XCTFail("picture_coding_extension が見つからない")
        }
        XCTAssertEqual(pce.pictureStructure, 3)          // frame picture
        XCTAssertFalse(pce.topFieldFirst)                // ffprobe field_order=bb
        XCTAssertFalse(pce.repeatFirstField)
        XCTAssertFalse(pce.progressiveFrame)             // field 符号化の frame
    }

    func testPictureCodingExtensionMarksProgressiveFramesInFilm24p() {
        guard let pce = MPEG2Bitstream.pictureCodingExtension(in: bytes(film24p)) else {
            return XCTFail("picture_coding_extension が見つからない")
        }
        XCTAssertEqual(pce.pictureStructure, 3)
        XCTAssertTrue(pce.progressiveFrame)
        XCTAssertFalse(pce.topFieldFirst)
    }

    func testSequenceHeaderNotFoundInNonMPEGData() {
        XCTAssertNil(MPEG2Bitstream.sequenceHeader(in: Data(repeating: 0, count: 64)))
        XCTAssertNil(MPEG2Bitstream.pictureCodingExtension(in: Data(repeating: 0, count: 64)))
    }
}

final class BitReaderTests: XCTestCase {
    func testBitReadsMatchByteLayout() {
        var r = BitReader(Data([0b1010_0101, 0b1100_0000]))
        XCTAssertEqual(r.readBits(4), 0b1010)
        XCTAssertEqual(r.readBits(4), 0b0101)
        XCTAssertEqual(r.readBits(8), 0b1100_0000)
        XCTAssertNil(r.readBits(1))
        XCTAssertEqual(r.remainingBits, 0)
    }

    func testPeekDoesNotConsume() {
        var r = BitReader(Data([0xAB]))
        XCTAssertEqual(r.peekBits(8), 0xAB)
        XCTAssertEqual(r.peekBits(8), 0xAB)
        XCTAssertEqual(r.readBits(8), 0xAB)
    }

    func testAlignToByteAndStartCodeSearch() {
        var r = BitReader(Data([0x00, 0x00, 0x07, 0x00, 0x00, 0x01, 0xB3]))
        _ = r.readBits(3)
        XCTAssertTrue(r.alignToByte())
        XCTAssertEqual(r.bitsRead % 8, 0)
        // 000001B3 を見つけて、その直後（payload の先頭）へ進む。
        let pos = r.advanceToStartCode()
        XCTAssertNotNil(pos)
        XCTAssertEqual(r.bitsRead, 7 * 8)
    }
}

final class FrameRateFromPTSTests: XCTestCase {
    /// PTS 列は decode 順（B 帧のある素材では昇順ではない）。並びと重複に関係なく
    /// 総フレーム数 / 総時間で測ること（01 §2、EXP-001）。
    func testResolveFromDecodeOrderedPTS() {
        let scale: Int32 = 90_000
        let step = FrameRate.ntsc.presentationTime(frameIndex: 1, timescale: scale).value  // 3003
        // presentation 順: 0,1,2,3,... / decode 順（GOP I B B P の想定）に並べ替える。
        var decodeOrder: [Int64] = []
        for g in 0..<8 {
            let base = Int64(g * 4)
            decodeOrder += [base, base &+ 2, base &+ 1, base &+ 3]
        }
        let pts = decodeOrder.map { MediaTime(value: $0 * step, timescale: scale) }
        XCTAssertEqual(RVMediaCore.frameRate(fromPTSs: pts), .ntsc)
    }

    func testIgnoresDuplicateTimestamps() {
        let scale: Int32 = 90_000
        let fps = FrameRate.pal
        var pts: [MediaTime] = []
        for n: Int64 in 0..<16 {
            let t = fps.presentationTime(frameIndex: n, timescale: scale)
            pts.append(t)
            if n % 3 == 0 { pts.append(t) }   // repeat 相当の重複
        }
        XCTAssertEqual(RVMediaCore.frameRate(fromPTSs: pts), .pal)
    }

    func testDoesNotGuessForShortOrNonStandardStreams() {
        let scale: Int32 = 90_000
        let pts = (0..<7).map { MediaTime(value: Int64($0) * 3600, timescale: scale) }
        XCTAssertNil(RVMediaCore.frameRate(fromPTSs: pts))           // 短すぎる
        let odd = (0..<24).map { MediaTime(value: Int64($0) * 4000, timescale: scale) } // 22.5 fps 相当
        XCTAssertNil(RVMediaCore.frameRate(fromPTSs: odd))           // 標準に一致しない場合は推測しない
    }
}
