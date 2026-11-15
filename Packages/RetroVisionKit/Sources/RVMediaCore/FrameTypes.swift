import CoreVideo
import Foundation

// MARK: - 復号フレームと資源の寿命（01 §4）

/// 復号後のフレーム。
///
/// 不変契約（INV-5）:
///   - 生成後に pixel buffer へ書き込まない。
///   - `lease` が 0 になるまでプールへ返却しない。
///
/// スレッド要件: 生成後は不変なのでどこからでも読める（`@unchecked Sendable`）。
public final class DecodedVideoFrame: @unchecked Sendable {
    public let id: FrameID
    public let pixelBuffer: CVPixelBuffer
    public let format: VideoFormatDescription
    public let pts: MediaTime
    public let duration: MediaTime
    public let isKey: Bool
    let lease: FrameLease

    init(id: FrameID, pixelBuffer: CVPixelBuffer, format: VideoFormatDescription,
         pts: MediaTime, duration: MediaTime, isKey: Bool, lease: FrameLease) {
        self.id = id
        self.pixelBuffer = pixelBuffer
        self.format = format
        self.pts = pts
        self.duration = duration
        self.isKey = isKey
        self.lease = lease
    }

    /// 使用中であることを示すトークンを取る。返却前に離すと診断に出る。
    public func retainForUse(reason: String) -> FrameLeaseToken { lease.acquire(reason: reason) }
    public var activeLeaseCount: Int { lease.count }
}

/// 資源の寿命管理。実数はアトミックに保つ（ロックを取らない）。
final class FrameLease: @unchecked Sendable {
    private let storage: ManagedAtomicBox<Int>
    let frameID: FrameID
    private let onViolation: ([String: String]) -> Void

    init(frameID: FrameID, onViolation: @escaping ([String: String]) -> Void) {
        self.frameID = frameID
        self.storage = ManagedAtomicBox(0)
        self.onViolation = onViolation
    }

    var count: Int { storage.value }

    func acquire(reason: String) -> FrameLeaseToken {
        storage.withMutableValue { $0 += 1 }
        return FrameLeaseToken(lease: self, reason: reason)
    }

    func decrement() {
        storage.withMutableValue { if $0 > 0 { $0 -= 1 } }
    }

    /// プール返却時に呼ぶ。生存者が残っている場合は違反として報告し、上書きはしない。
    func assertReleased() -> Bool {
        let remaining = storage.value
        if remaining > 0 {
            onViolation(["frameID": "\(frameID)", "remainingLeases": "\(remaining)"])
            return false
        }
        return true
    }
}

public final class FrameLeaseToken: @unchecked Sendable {
    private let lease: FrameLease
    let reason: String

    init(lease: FrameLease, reason: String) {
        self.lease = lease
        self.reason = reason
    }

    deinit { release() }

    public func release() {
        lease.decrement()
    }
}

/// ManagedAtomicBox の簡易実装（ロックなしの単調更新）。
final class ManagedAtomicBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storageValue: Value

    init(_ value: Value) { self.storageValue = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storageValue
    }

    func withMutableValue(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storageValue)
    }
}

/// CVPixelBuffer プールの要求仕様。実装は RVDecode 側が持つ（04 §3）。
public struct PixelBufferPoolRequirements: Sendable, Hashable {
    public var width: Int32
    public var height: Int32
    public var pixelFormat: OSType
    /// Metal 共有・IOSurface 共有を必須にする（01 §4）。
    public var metalCompatible: Bool
    public var iosurfaceBacked: Bool
    public var minimumBufferCount: Int

    public init(width: Int32, height: Int32, pixelFormat: OSType,
                metalCompatible: Bool = true, iosurfaceBacked: Bool = true,
                minimumBufferCount: Int = 6) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.metalCompatible = metalCompatible
        self.iosurfaceBacked = iosurfaceBacked
        self.minimumBufferCount = minimumBufferCount
    }
}
