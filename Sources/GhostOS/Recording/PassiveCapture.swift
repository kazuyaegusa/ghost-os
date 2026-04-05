// PassiveCapture.swift - ShadowPlay方式パッシブキャプチャ
//
// CGEventTapを常時起動し、クリック/キー/アプリ切替を
// RingBufferに軽量メタデータとして記録する。
// テキスト入力内容・パスワードフィールドは記録しない。

import AppKit
import AXorcist
import CoreGraphics
import Foundation

// MARK: - CapturedAction

/// パッシブキャプチャで記録する1アクションのメタデータ。
public struct CapturedAction: Sendable {
    public let timestamp: Date
    public let app: String
    public let windowTitle: String
    public let actionType: CapturedActionType
    public let target: String?
    public let keyCombo: String?

    public init(
        timestamp: Date,
        app: String,
        windowTitle: String,
        actionType: CapturedActionType,
        target: String? = nil,
        keyCombo: String? = nil
    ) {
        self.timestamp = timestamp
        self.app = app
        self.windowTitle = windowTitle
        self.actionType = actionType
        self.target = target
        self.keyCombo = keyCombo
    }
}

/// キャプチャ対象のアクション種別。
public enum CapturedActionType: String, Sendable {
    case click
    case type
    case hotkey
    case appSwitch
}

// MARK: - RingBuffer

/// 固定サイズの循環バッファ。最大容量を超えると古いデータを上書きする。
public struct RingBuffer<T>: Sendable where T: Sendable {
    private var storage: [T?]
    private var writeIndex: Int = 0
    private var isFull: Bool = false

    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    /// 要素を追加する。容量超過時は最古の要素を上書き。
    public mutating func append(_ element: T) {
        storage[writeIndex] = element
        writeIndex = (writeIndex + 1) % capacity
        if writeIndex == 0 { isFull = true }
    }

    /// バッファ内の全要素を古い順に返す。
    public var elements: [T] {
        if isFull {
            let tail = storage[writeIndex...].compactMap { $0 }
            let head = storage[..<writeIndex].compactMap { $0 }
            return tail + head
        } else {
            return storage[..<writeIndex].compactMap { $0 }
        }
    }

    /// バッファ内の現在の要素数。
    public var count: Int {
        isFull ? capacity : writeIndex
    }

    /// バッファを空にする。
    public mutating func clear() {
        storage = Array(repeating: nil, count: capacity)
        writeIndex = 0
        isFull = false
    }
}

// MARK: - PassiveCaptureManager

/// CGEventTapを常時起動し、操作をRingBufferに記録するマネージャー。
public final class PassiveCaptureManager: @unchecked Sendable {

    // MARK: - Properties

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()

    private var buffer: RingBuffer<CapturedAction>
    private let maxBufferSeconds: TimeInterval = 600
    private var previousApp: String = ""

    public private(set) var isRunning: Bool = false

    /// パターン検出器（外部から注入可能）
    public var patternDetector: PatternDetector?

    // MARK: - Init

    public init(bufferCapacity: Int = 1000) {
        self.buffer = RingBuffer(capacity: bufferCapacity)
    }

    // MARK: - Public API

    /// パッシブキャプチャを開始する。
    @MainActor
    public func start() throws {
        let status = PermissionChecker.check()
        guard status.allGranted else {
            throw RecordingError.permissionDenied(
                status.errorMessage ?? "権限が不足しています"
            )
        }

        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        let eventMask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: passiveCaptureCallback,
            userInfo: selfPtr
        ) else {
            Unmanaged<PassiveCaptureManager>.fromOpaque(selfPtr).release()
            throw RecordingError.eventTapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRunning = true

        Log.info("PassiveCapture: started")
    }

    /// パッシブキャプチャを停止する。
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }

        eventTap = nil
        runLoopSource = nil
        isRunning = false

        Log.info("PassiveCapture: stopped")
    }

    /// 直近N秒分のアクションを返す。
    public func saveRecent(seconds: Int = 60) -> [CapturedAction] {
        lock.lock()
        let allActions = buffer.elements
        lock.unlock()

        let cutoff = Date().addingTimeInterval(-Double(seconds))
        return allActions.filter { $0.timestamp >= cutoff }
    }

    /// バッファ内の全件数を返す。
    public var bufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    // MARK: - Internal

    fileprivate func handleCGEvent(type: CGEventType, event: CGEvent) {
        Task { @MainActor in
            self.processEvent(type: type, event: event)
        }
    }

    @MainActor
    private func processEvent(type: CGEventType, event: CGEvent) {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "Unknown"

        // アプリ切替検出
        if appName != previousApp && !previousApp.isEmpty {
            let action = CapturedAction(
                timestamp: Date(),
                app: appName,
                windowTitle: windowTitle(for: frontApp) ?? "",
                actionType: .appSwitch,
                target: appName
            )
            appendAction(action)
        }
        previousApp = appName

        let winTitle = windowTitle(for: frontApp) ?? ""

        switch type {
        case .leftMouseDown, .rightMouseDown:
            let location = event.location

            // クリック先の要素名を取得
            var targetName: String? = nil
            if let element = ElementBridge.elementAtPoint(CGPoint(x: location.x, y: location.y)) {
                // パスワードフィールドはスキップ
                if element.isSecure() {
                    return
                }
                targetName = element.title() ?? element.computedName()
            }

            let action = CapturedAction(
                timestamp: Date(),
                app: appName,
                windowTitle: winTitle,
                actionType: .click,
                target: targetName
            )
            appendAction(action)

        case .keyDown:
            let flags = event.flags
            let hasModifier = flags.contains(.maskCommand) || flags.contains(.maskControl)

            if hasModifier {
                // ショートカットキーとして記録
                var modifiers: [String] = []
                if flags.contains(.maskCommand) { modifiers.append("cmd") }
                if flags.contains(.maskShift) { modifiers.append("shift") }
                if flags.contains(.maskAlternate) { modifiers.append("option") }
                if flags.contains(.maskControl) { modifiers.append("control") }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let keyName = SemanticTransformer.keyCodeToName[Int(keyCode)] ?? "?"
                let combo = (modifiers + [keyName]).joined(separator: "+")

                let action = CapturedAction(
                    timestamp: Date(),
                    app: appName,
                    windowTitle: winTitle,
                    actionType: .hotkey,
                    keyCombo: combo
                )
                appendAction(action)
            } else {
                // テキスト入力の中身は記録しない（プライバシー）
                // "type" アクションがあったことだけ記録
                let action = CapturedAction(
                    timestamp: Date(),
                    app: appName,
                    windowTitle: winTitle,
                    actionType: .type
                )
                appendAction(action)
            }

        default:
            break
        }
    }

    private func appendAction(_ action: CapturedAction) {
        lock.lock()
        buffer.append(action)

        // 古いエントリを時間ベースで自動削除（600秒超え）
        // RingBufferは固定サイズなので、ここでは追加のみ
        lock.unlock()
    }

    @MainActor
    private func windowTitle(for app: NSRunningApplication?) -> String? {
        guard let pid = app?.processIdentifier,
              let appElement = Element.application(for: pid),
              let window = appElement.focusedWindow()
        else { return nil }
        return window.title()
    }
}

// MARK: - CGEventTap Callback (C関数)

private let passiveCaptureCallback: CGEventTapCallBack = {
    proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let manager = Unmanaged<PassiveCaptureManager>.fromOpaque(userInfo).takeUnretainedValue()
    manager.handleCGEvent(type: type, event: event)
    return Unmanaged.passRetained(event)
}

// MARK: - ElementBridge

/// AXorcist の Element をブリッジするヘルパー。
private enum ElementBridge {
    static func elementAtPoint(_ point: CGPoint) -> Element? {
        Element.elementAtPoint(point)
    }
}

// MARK: - Element Extension (isSecure)

extension Element {
    /// パスワードフィールドかどうかを判定する。
    func isSecure() -> Bool {
        // AXSubrole が "AXSecureTextField" の場合はセキュアフィールド
        if let subrole = self.subrole(), subrole == "AXSecureTextField" {
            return true
        }
        return false
    }
}
