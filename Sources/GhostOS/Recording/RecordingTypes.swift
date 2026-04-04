// RecordingTypes.swift - イベントキャプチャ・記録機能の型定義
//
// 生イベント取得 → AXコンテキスト付加 → セマンティックステップ抽出
// の各段階で使うデータ型を定義する。

import Foundation

// MARK: - Raw Event

/// イベントの種別
public enum RawEventType: String, Codable, Sendable {
    case leftClick
    case rightClick
    case doubleClick
    case keyDown
    case scroll
    case appSwitch
}

/// CGEventTap から取得した生イベント
public struct RawEvent: Codable, Sendable {
    public let type: RawEventType
    public let timestamp: Date
    public let x: Double?
    public let y: Double?
    public let keyCode: Int?
    public let characters: String?
    public let modifiers: [String]?
    public let scrollDeltaX: Double?
    public let scrollDeltaY: Double?

    public init(
        type: RawEventType,
        timestamp: Date,
        x: Double? = nil,
        y: Double? = nil,
        keyCode: Int? = nil,
        characters: String? = nil,
        modifiers: [String]? = nil,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil
    ) {
        self.type = type
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
    }
}

// MARK: - Accessibility Context

/// AX要素の詳細情報
public struct AXElementInfo: Codable, Sendable {
    public let role: String?
    public let title: String?
    public let identifier: String?
    public let value: String?

    public init(
        role: String? = nil,
        title: String? = nil,
        identifier: String? = nil,
        value: String? = nil
    ) {
        self.role = role
        self.title = title
        self.identifier = identifier
        self.value = value
    }
}

/// イベント発生時点のアクセシビリティコンテキスト
public struct AXContext: Codable, Sendable {
    public let app: String
    public let window: String?
    public let element: AXElementInfo?
    public let url: String?

    public init(
        app: String,
        window: String? = nil,
        element: AXElementInfo? = nil,
        url: String? = nil
    ) {
        self.app = app
        self.window = window
        self.element = element
        self.url = url
    }
}

// MARK: - Enriched Event

/// AXコンテキストを付加した生イベント
public struct EnrichedEvent: Codable, Sendable {
    public let raw: RawEvent
    public let axContext: AXContext

    enum CodingKeys: String, CodingKey {
        case raw
        case axContext = "ax_context"
    }

    public init(raw: RawEvent, axContext: AXContext) {
        self.raw = raw
        self.axContext = axContext
    }
}

// MARK: - Semantic Step

/// セマンティックステップの操作対象
public struct StepTarget: Codable, Sendable {
    public let query: String?
    public let role: String?
    public let identifier: String?

    public init(
        query: String? = nil,
        role: String? = nil,
        identifier: String? = nil
    ) {
        self.query = query
        self.role = role
        self.identifier = identifier
    }
}

/// 複数の生イベントから推論した1操作ステップ
public struct SemanticStep: Codable, Sendable {
    public let action: String
    public let target: StepTarget?
    public let params: [String: String]?
    public let description: String
    public let originalEventIndex: Int

    public init(
        action: String,
        target: StepTarget? = nil,
        params: [String: String]? = nil,
        description: String,
        originalEventIndex: Int
    ) {
        self.action = action
        self.target = target
        self.params = params
        self.description = description
        self.originalEventIndex = originalEventIndex
    }
}

// MARK: - Recording State

/// 記録セッションの状態
public enum RecordingState: Sendable {
    case idle
    case recording(sessionId: String, startTime: Date)
    case stopped(sessionId: String, events: [EnrichedEvent])
}

// MARK: - Recording Error

/// 記録機能固有のエラー
public enum RecordingError: Error, LocalizedError, Sendable {
    case permissionDenied(String)
    case eventTapCreationFailed
    case noActiveSession
    case sessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .permissionDenied(msg):
            "アクセシビリティ権限が必要です: \(msg)"
        case .eventTapCreationFailed:
            "イベントタップの作成に失敗しました"
        case .noActiveSession:
            "アクティブな記録セッションがありません"
        case let .sessionNotFound(id):
            "セッションが見つかりません: \(id)"
        }
    }
}
