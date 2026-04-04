// RecordingSession.swift - 操作記録セッション管理 + AXエンリッチメント
//
// startRecording で CGEventTap を起動し、イベントごとに AX コンテキストを付与。
// セッションはメモリ内 Dictionary で管理する。

import AppKit
import AXorcist
import Foundation

// MARK: - RecordingSession

/// 操作記録セッションを管理し、生イベントに AX コンテキストを付与するクラス。
public final class RecordingSession: @unchecked Sendable {

    // MARK: - Properties

    private let capture = EventCapture()
    private var sessions: [String: [EnrichedEvent]] = [:]
    private var activeSessionId: String?
    private let lock = NSLock()

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// 記録を開始する。既存の記録がある場合は停止してから再開する。
    /// - Parameter app: フィルタするアプリ名（nil = 全アプリ）
    /// - Returns: 新しいセッション ID
    @MainActor
    public func startRecording(app: String?) throws -> String {
        // 既存セッションを停止
        if capture.isCapturing {
            capture.stop()
        }

        let sessionId = UUID().uuidString

        lock.lock()
        sessions[sessionId] = []
        activeSessionId = sessionId
        lock.unlock()

        let filterApp = app

        try capture.start { [weak self] rawEvent in
            guard let self else { return }
            // CGEventTap コールバックはメインスレッドで呼ばれるため
            // MainActor 境界を超えずにそのまま呼び出せる
            Task { @MainActor in
                self.handleRawEvent(rawEvent, filterApp: filterApp)
            }
        }

        Log.info("RecordingSession: started session \(sessionId)")
        return sessionId
    }

    /// 記録を停止する。
    /// - Returns: 停止したセッション ID
    public func stopRecording() throws -> String {
        lock.lock()
        let sessionId = activeSessionId
        activeSessionId = nil
        lock.unlock()

        guard let sessionId else {
            throw RecordingError.noActiveSession
        }

        capture.stop()
        Log.info("RecordingSession: stopped session \(sessionId)")
        return sessionId
    }

    /// セッションのイベントを先頭から最大 `limit` 件返す。
    /// - Parameters:
    ///   - sessionId: 対象セッション ID
    ///   - limit: 最大取得件数（nil = 全件）
    /// - Returns: エンリッチ済みイベントの配列
    public func previewSession(sessionId: String, limit: Int?) throws -> [EnrichedEvent] {
        lock.lock()
        let events = sessions[sessionId]
        lock.unlock()

        guard let events else {
            throw RecordingError.sessionNotFound(sessionId)
        }

        if let limit {
            return Array(events.prefix(limit))
        }
        return events
    }

    /// セッションの全イベントを返す。
    /// - Parameter sessionId: 対象セッション ID
    /// - Returns: エンリッチ済みイベントの配列
    public func getSession(sessionId: String) throws -> [EnrichedEvent] {
        lock.lock()
        let events = sessions[sessionId]
        lock.unlock()

        guard let events else {
            throw RecordingError.sessionNotFound(sessionId)
        }
        return events
    }

    /// セッションを破棄する。
    /// - Parameter sessionId: 破棄するセッション ID
    public func clearSession(sessionId: String) throws {
        lock.lock()
        let existed = sessions.removeValue(forKey: sessionId) != nil
        // アクティブセッションを削除した場合はキャプチャも停止
        if activeSessionId == sessionId {
            activeSessionId = nil
            lock.unlock()
            capture.stop()
        } else {
            lock.unlock()
        }

        guard existed else {
            throw RecordingError.sessionNotFound(sessionId)
        }
        Log.info("RecordingSession: cleared session \(sessionId)")
    }

    // MARK: - Internal

    /// 生イベントを受け取り、AX コンテキストを付与してセッションに追加する。
    @MainActor
    private func handleRawEvent(_ raw: RawEvent, filterApp: String?) {
        let axContext = buildAXContext(for: raw, filterApp: filterApp)

        // filterApp 指定がある場合、対象アプリ以外のイベントをスキップ
        if let filterApp {
            let appName = axContext?.app ?? ""
            guard appName.localizedCaseInsensitiveContains(filterApp) else { return }
        }

        let context = axContext ?? AXContext(app: "Unknown")
        let enriched = EnrichedEvent(raw: raw, axContext: context)

        lock.lock()
        guard let sessionId = activeSessionId else {
            lock.unlock()
            return
        }
        sessions[sessionId]?.append(enriched)
        lock.unlock()
    }

    /// イベント座標 or フォアグラウンドアプリから AXContext を構築する。
    @MainActor
    private func buildAXContext(for raw: RawEvent, filterApp: String?) -> AXContext? {
        // フロントモストアプリをベースにする
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "Unknown"

        // ウィンドウタイトルを AX ツリーから取得
        var windowTitle: String? = nil
        var elementInfo: AXElementInfo? = nil
        var urlString: String? = nil

        if let pid = frontApp?.processIdentifier {
            if let appElement = AXorcistBridge.application(for: pid) {
                if let window = appElement.focusedWindow() {
                    windowTitle = window.title()

                    // URL 取得（ブラウザ向け）
                    if let webArea = findWebAreaInWindow(window) {
                        urlString = readURLFromWebArea(webArea)
                    }
                }

                // クリック座標の要素を取得
                if let x = raw.x, let y = raw.y,
                   let element = AXorcistBridge.elementAtPoint(CGPoint(x: x, y: y))
                {
                    elementInfo = AXElementInfo(
                        role: element.role(),
                        title: element.title() ?? element.computedName(),
                        identifier: element.identifier(),
                        value: element.stringValue()
                    )
                }
            }
        }

        return AXContext(
            app: appName,
            window: windowTitle,
            element: elementInfo,
            url: urlString
        )
    }

    /// ウィンドウ要素内の WebArea を探す（ブラウザ URL 取得用）。
    private func findWebAreaInWindow(_ window: AXElement) -> AXElement? {
        return findWebAreaRecursive(window, depth: 0)
    }

    private func findWebAreaRecursive(_ element: AXElement, depth: Int) -> AXElement? {
        guard depth < 6 else { return nil }
        if element.role() == "AXWebArea" { return element }
        guard let children = element.children() else { return nil }
        for child in children {
            if let found = findWebAreaRecursive(child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// WebArea から URL を読む。
    private func readURLFromWebArea(_ webArea: AXElement) -> String? {
        if let url = webArea.url() {
            return url.absoluteString
        }
        // フォールバック: AXURL 属性を直接読む
        if let cfValue = webArea.rawAttributeValue(named: "AXURL") {
            if let url = cfValue as? URL { return url.absoluteString }
            if CFGetTypeID(cfValue) == CFURLGetTypeID() {
                return (cfValue as! CFURL as URL).absoluteString
            }
        }
        return nil
    }
}

// MARK: - AXorcistBridge

/// AXorcist の Element ラッパー。RecordingSession 内での型エイリアス。
private typealias AXElement = Element

private enum AXorcistBridge {
    static func application(for pid: pid_t) -> AXElement? {
        AXElement.application(for: pid)
    }

    static func elementAtPoint(_ point: CGPoint) -> AXElement? {
        AXElement.elementAtPoint(point)
    }
}
