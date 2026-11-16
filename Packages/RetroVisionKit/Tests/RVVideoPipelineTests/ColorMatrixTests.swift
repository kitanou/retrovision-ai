import Foundation
import RVMediaCore
import XCTest
@testable import RVVideoPipeline

// MARK: - 色変換行列の数値検査（05 §3。GPU に依らない純ロジック）
//
// 検査は二方向から挟む:
//   1. 導出式（kr/kb から係数を組む）が、古典的な表の定数（BT.601: 1.596/0.391/0.813/2.017、
//      BT.709: 1.792/0.213/0.535/2.114）と丸め精度で一致すること。
//   2. 既知の色バー値（MPEG トーンバー）を通すと、 Expected RGB に ±1/255 以内で収まること。

final class ColorMatrixTests: XCTestCase {

    private func approx(_ a: Float, _ b: Float, _ tol: Float, _ msg: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(a - b), tol, msg + " (got \(a), want \(b))",
                                file: file, line: line)
    }

    // MARK: BT.601 video range — 表の定数との一致

    func testBT601VideoRangeMatchesTableConstants() {
        let color = ColorInfo(primaries: .bt601SMPTEC, transfer: .bt709OrBT601,
                              matrix: .bt601_4, range: .videoRange, isStated: true)
        let c = ColorMatrixBuilder.resolve(color: color, parameters: ColorConvertParameters())
        XCTAssertNotNil(c)
        guard let c else { return }
        XCTAssertFalse(c.assumptionApplied)
        // 古典的な studio swing 定数: Y 係数 1.1643、Cr→R 1.596、Cb→G 0.391、Cr→G 0.813、Cb→B 2.017
        approx(c.m[0], 1.1643, 0.0005, "601 luma scale")
        approx(c.m[2], 1.596, 0.001, "601 Cr→R")
        approx(c.m[3], 1.1643, 0.0005, "601 luma scale (G row)")
        approx(c.m[4], -0.391, 0.001, "601 Cb→G")
        approx(c.m[5], -0.813, 0.001, "601 Cr→G")
        approx(c.m[6], 1.1643, 0.0005, "601 luma scale (B row)")
        approx(c.m[7], 2.017, 0.001, "601 Cb→B")
    }

    /// MPEG トーンバー（BT.601 video range の Y/Cb/Cr 値）を 8bit 整数で与えて、
    /// 期待 RGB に一致すること（clip 前の線形値としての検査。±1.5/255）。
    func testBT601KnownBarValues() {
        let color = ColorInfo(primaries: .bt601SMPTEC, transfer: .bt709OrBT601,
                              matrix: .bt601_4, range: .videoRange, isStated: true)
        guard let c = ColorMatrixBuilder.resolve(color: color, parameters: ColorConvertParameters())
        else { return XCTFail("resolve が nil") }

        func check(y: Int, cb: Int, cr: Int, r: Double, g: Double, b: Double,
                   _ label: String, tol: Double = 1.5) {
            let out = c.transform(y: Double(y) / 255, cb: Double(cb) / 255, cr: Double(cr) / 255)
            for (got, want, name) in [(out.r, r, "R"), (out.g, g, "G"), (out.b, b, "B")] {
                let got255 = got * 255
                XCTAssertLessThanOrEqual(abs(got255 - want * 255), tol,
                                         "\(label) \(name): got \(got255) want \(want * 255)")
            }
        }
        // black / white（studio swing の端点）
        check(y: 16, cb: 128, cr: 128, r: 0, g: 0, b: 0, "black")
        check(y: 235, cb: 128, cr: 128, r: 1, g: 1, b: 1, "white")
        // gray 50%（ITU: Y=128, Cb=Cr=128 → ≈(128,128,128) 相当の mid gray）
        let gray = c.transform(y: 128.0 / 255, cb: 128.0 / 255, cr: 128.0 / 255)
        XCTAssertGreaterThan(gray.r * 255, 122); XCTAssertLessThan(gray.r * 255, 134)
        // primary red bar（Y=81, Cb=90, Cr=240 → ≈(254,0,0)）
        check(y: 81, cb: 90, cr: 240, r: 254.0 / 255, g: 0, b: 0, "red", tol: 2.0)
        // primary green bar（Y=145, Cb=54, Cr=34 → ≈(0,255,0)）
        check(y: 145, cb: 54, cr: 34, r: 0, g: 255.0 / 255, b: 0, "green", tol: 2.0)
        // primary blue bar（Y=41, Cb=240, Cr=110 → ≈(0,0,255)）
        check(y: 41, cb: 240, cr: 110, r: 0, g: 0, b: 255.0 / 255, "blue", tol: 2.0)
        // chroma 中立（Cb=Cr=128）で色カブリが無いこと
        let neutral = c.transform(y: 200.0 / 255, cb: 128.0 / 255, cr: 128.0 / 255)
        XCTAssertLessThan(abs(neutral.r - neutral.g), 0.004)
        XCTAssertLessThan(abs(neutral.g - neutral.b), 0.004)
    }

    // MARK: BT.709 — 別マトリクスへ張り替わること

    func testBT709UsesItsOwnCoefficients() {
        let color = ColorInfo(primaries: .bt709, transfer: .bt709OrBT601,
                              matrix: .bt709_2, range: .videoRange, isStated: true)
        guard let c = ColorMatrixBuilder.resolve(color: color, parameters: ColorConvertParameters())
        else { return XCTFail("resolve が nil") }
        // 709 の studio swing 換算係数（255/224 込みの正確値。よく引かれる表値 1.792/0.213/
        // 0.535/2.114 は端数丸めなので、導出式側の正確値 1.7927/0.2133/0.5329/2.1124 で合わせる。
        // 表値との差が 0.002 以内であることも同時に確認していることになる）。
        approx(c.m[2], 1.7927, 0.001, "709 Cr→R")
        approx(c.m[4], -0.2133, 0.001, "709 Cb→G")
        approx(c.m[5], -0.5329, 0.001, "709 Cr→G")
        approx(c.m[7], 2.1124, 0.001, "709 Cb→B")
    }

    // MARK: assumption の発動と記録（05 §3: 発動したら必ず残す）

    func testUnstatedSDAppliesBT601AssumptionWithFlag() {
        let color = ColorInfo.unspecified
        guard let c = ColorMatrixBuilder.resolve(color: color, parameters: ColorConvertParameters())
        else { return XCTFail("resolve が nil（既定は BT.601 のはず）") }
        XCTAssertTrue(c.assumptionApplied, "assumption の発動が記録されていない")
        XCTAssertEqual(c.matrixUsed, "bt601_4")
        approx(c.m[2], 1.596, 0.001, "assumed 601 Cr→R")

        // assumption を切った then: 解決不能（nil）→ plan 生成失敗にできる
        var off = ColorConvertParameters()
        off.assumeBT601WhenUnstated = false
        XCTAssertNil(ColorMatrixBuilder.resolve(color: color, parameters: off))
    }

    /// 指定済み primaries からの導出は assumption ではない（flag が立たない）。
    func testDerivationFromStatedPrimariesIsNotAnAssumption() {
        let color = ColorInfo(primaries: .bt601EBU, transfer: .bt709OrBT601,
                              matrix: .unspecified, range: .videoRange, isStated: true)
        guard let c = ColorMatrixBuilder.resolve(color: color, parameters: ColorConvertParameters())
        else { return XCTFail("resolve が nil") }
        XCTAssertFalse(c.assumptionApplied, "指定済み BT.601 からの導出に assumption flag は不正")
    }

    // MARK: full range（JPEG/PC 値）の展开

    func testFullRangeAnchors() {
        let color = ColorInfo(primaries: .bt601SMPTEC, transfer: .bt709OrBT601,
                              matrix: .bt601_4, range: .fullRange, isStated: true)
        guard let c = ColorMatrixBuilder.resolve(color: color, parameters: ColorConvertParameters())
        else { return XCTFail("resolve が nil") }
        let black = c.transform(y: 0, cb: 128.0 / 255, cr: 128.0 / 255)
        for v in [black.r, black.g, black.b] {
            XCTAssertLessThan(abs(v), 0.01, "full range black が 0 でない")
        }
        let white = c.transform(y: 1, cb: 128.0 / 255, cr: 128.0 / 255)
        for v in [white.r, white.g, white.b] {
            XCTAssertLessThan(abs(v - 1), 0.01, "full range white が 1 でない")
        }
    }
}
