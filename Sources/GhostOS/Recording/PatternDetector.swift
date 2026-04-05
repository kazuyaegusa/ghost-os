// PatternDetector.swift - 操作パターンの自動検出
//
// PassiveCaptureのバッファを30秒ごとにスキャンし、
// アプリ遷移シーケンスの繰り返しを検出する。
// 同一パターン3回以上で通知コールバックを呼ぶ。

import Foundation

// MARK: - DetectedPattern

/// 検出されたパターン情報。
public struct DetectedPattern: Sendable {
    public let patternHash: String
    public let count: Int
    public let actions: [CapturedAction]
    public let description: String
}

// MARK: - PatternDetector

/// バッファ内の操作パターンを検出するクラス。
public final class PatternDetector: @unchecked Sendable {

    // MARK: - Properties

    /// パターン検出時のコールバック。
    public var onPatternDetected: (([DetectedPattern]) -> Void)?

    private let lock = NSLock()
    private var patternCounts: [String: Int] = [:]
    private var patternActions: [String: [CapturedAction]] = [:]
    private var scanTimer: Timer?
    private let scanInterval: TimeInterval = 30
    private let minPatternLength = 3
    private let maxPatternLength = 10
    private let detectionThreshold = 3

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// パターン検出を開始する。
    /// - Parameter captureManager: 監視対象のPassiveCaptureManager
    public func startDetection(captureManager: PassiveCaptureManager) {
        stopDetection()

        let timer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) {
            [weak self, weak captureManager] _ in
            guard let self, let captureManager else { return }
            let actions = captureManager.saveRecent(seconds: 300)
            self.scan(actions: actions)
        }
        RunLoop.main.add(timer, forMode: .common)

        lock.lock()
        scanTimer = timer
        lock.unlock()

        Log.info("PatternDetector: started (interval: \(Int(scanInterval))s)")
    }

    /// パターン検出を停止する。
    public func stopDetection() {
        lock.lock()
        scanTimer?.invalidate()
        scanTimer = nil
        lock.unlock()
    }

    /// 検出済みパターンの一覧を返す。
    public var detectedPatterns: [DetectedPattern] {
        lock.lock()
        defer { lock.unlock() }

        return patternCounts.compactMap { hash, count in
            guard count >= detectionThreshold,
                  let actions = patternActions[hash]
            else { return nil }
            let desc = describePattern(actions)
            return DetectedPattern(
                patternHash: hash,
                count: count,
                actions: actions,
                description: desc
            )
        }.sorted { $0.count > $1.count }
    }

    /// 検出済みパターン数を返す。
    public var detectedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return patternCounts.values.filter { $0 >= detectionThreshold }.count
    }

    // MARK: - Internal

    /// アクション配列をスキャンしてパターンを検出する。
    private func scan(actions: [CapturedAction]) {
        guard actions.count >= minPatternLength else { return }

        // アクションをシーケンスに変換（app + actionType + target）
        let sequence = actions.map { hashAction($0) }

        // N-gramでパターンを探す
        var newCounts: [String: Int] = [:]
        var newActions: [String: [CapturedAction]] = [:]

        for length in minPatternLength...min(maxPatternLength, sequence.count / 2) {
            for start in 0...(sequence.count - length) {
                let subsequence = Array(sequence[start..<(start + length)])
                let hash = subsequence.joined(separator: "|")

                // このパターンが他の位置にも出現するか
                var occurrences = 0
                var i = 0
                while i <= sequence.count - length {
                    let candidate = Array(sequence[i..<(i + length)])
                    if candidate == subsequence {
                        occurrences += 1
                        i += length // 重複なしでカウント
                    } else {
                        i += 1
                    }
                }

                if occurrences >= 2 {
                    newCounts[hash] = occurrences
                    if newActions[hash] == nil {
                        newActions[hash] = Array(actions[start..<(start + length)])
                    }
                }
            }
        }

        // 検出結果を更新
        lock.lock()
        for (hash, count) in newCounts {
            let prev = patternCounts[hash] ?? 0
            patternCounts[hash] = max(prev, count)
            if patternActions[hash] == nil {
                patternActions[hash] = newActions[hash]
            }
        }
        let patterns = detectedPatternsUnlocked()
        lock.unlock()

        // 閾値超えパターンがあればコールバック
        if !patterns.isEmpty {
            onPatternDetected?(patterns)
        }
    }

    /// ロック保持中に検出パターンを返す（内部用）。
    private func detectedPatternsUnlocked() -> [DetectedPattern] {
        return patternCounts.compactMap { hash, count in
            guard count >= detectionThreshold,
                  let actions = patternActions[hash]
            else { return nil }
            let desc = describePattern(actions)
            return DetectedPattern(
                patternHash: hash,
                count: count,
                actions: actions,
                description: desc
            )
        }
    }

    /// 個別アクションをハッシュ文字列に変換する。
    private func hashAction(_ action: CapturedAction) -> String {
        let parts = [
            action.app,
            action.actionType.rawValue,
            action.target ?? "",
        ]
        return parts.joined(separator: ":")
    }

    /// パターンの人間可読な説明を生成する。
    private func describePattern(_ actions: [CapturedAction]) -> String {
        let steps = actions.map { action -> String in
            switch action.actionType {
            case .click:
                if let t = action.target { return "\(action.app)で「\(t)」をクリック" }
                return "\(action.app)でクリック"
            case .type:
                return "\(action.app)でテキスト入力"
            case .hotkey:
                return "\(action.app)で\(action.keyCombo ?? "ショートカット")"
            case .appSwitch:
                return "\(action.app)に切替"
            }
        }
        return steps.joined(separator: " → ")
    }
}
