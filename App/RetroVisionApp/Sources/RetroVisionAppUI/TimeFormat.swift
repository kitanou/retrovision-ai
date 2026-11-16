import Foundation

/// 再生時刻の表示（#17 の transport 表示 mm:ss / h:mm:ss）。
func formatPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
}
