// EventCapture.swift - CGEventTapベースのイベント捕捉
//
// listenOnlyモードでマウス・キーボード・スクロールを監視し、
// RawEventを生成してハンドラに渡す。

import Foundation
import CoreGraphics
import Carbon

// MARK: - EventCapture

/// CGEventTapを使ってシステムイベントをlistenOnlyで捕捉するクラス
public final class EventCapture: @unchecked Sendable {

    // MARK: - Properties

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventHandler: ((RawEvent) -> Void)?
    private let lock = NSLock()

    public private(set) var isCapturing: Bool = false

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// イベントキャプチャを開始する
    /// - Parameter handler: イベント受信時のコールバック
    @MainActor
    public func start(handler: @escaping @Sendable (RawEvent) -> Void) throws {
        let status = PermissionChecker.check()
        guard status.allGranted else {
            throw RecordingError.permissionDenied(
                status.errorMessage ?? "権限が不足しています"
            )
        }

        lock.lock()
        defer { lock.unlock() }

        guard !isCapturing else { return }

        eventHandler = handler

        let eventMask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        // CGEventTapCallBack内でselfにアクセスするためUnmanagedで渡す
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else {
            // passRetainedしたが作成失敗なのでreleaseする
            Unmanaged<EventCapture>.fromOpaque(selfPtr).release()
            throw RecordingError.eventTapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isCapturing = true
    }

    /// イベントキャプチャを停止する
    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isCapturing else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }

        eventTap = nil
        runLoopSource = nil
        eventHandler = nil
        isCapturing = false
    }

    // MARK: - Internal

    fileprivate func handleCGEvent(type: CGEventType, event: CGEvent) {
        guard let rawEvent = makeRawEvent(type: type, event: event) else { return }
        lock.lock()
        let handler = eventHandler
        lock.unlock()
        handler?(rawEvent)
    }
}

// MARK: - CGEventTap Callback (C関数)

/// CGEventTapCallBack: Cの関数ポインタなのでグローバル関数として定義
private let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let capture = Unmanaged<EventCapture>.fromOpaque(userInfo).takeUnretainedValue()
    capture.handleCGEvent(type: type, event: event)
    // listenOnlyなのでイベントをそのまま返す
    return Unmanaged.passRetained(event)
}

// MARK: - RawEvent生成

private func makeRawEvent(type: CGEventType, event: CGEvent) -> RawEvent? {
    let timestamp = Date()
    let location = event.location

    switch type {
    case .leftMouseDown:
        let clickState = event.getIntegerValueField(.mouseEventClickState)
        let eventType: RawEventType = clickState >= 2 ? .doubleClick : .leftClick
        return RawEvent(
            type: eventType,
            timestamp: timestamp,
            x: location.x,
            y: location.y
        )

    case .rightMouseDown:
        return RawEvent(
            type: .rightClick,
            timestamp: timestamp,
            x: location.x,
            y: location.y
        )

    case .keyDown:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        var modifiers: [String] = []
        if flags.contains(.maskCommand) { modifiers.append("cmd") }
        if flags.contains(.maskShift) { modifiers.append("shift") }
        if flags.contains(.maskAlternate) { modifiers.append("option") }
        if flags.contains(.maskControl) { modifiers.append("control") }

        // キャラクタ取得（存在しない場合はnil）
        var length = 0
        event.keyboardGetUnicodeString(
            maxStringLength: 0,
            actualStringLength: &length,
            unicodeString: nil
        )
        var characters: String? = nil
        if length > 0 {
            var buffer = [UniChar](repeating: 0, count: length)
            var actualLength = 0
            event.keyboardGetUnicodeString(
                maxStringLength: length,
                actualStringLength: &actualLength,
                unicodeString: &buffer
            )
            let str = String(utf16CodeUnits: buffer, count: actualLength)
            if !str.isEmpty { characters = str }
        }

        return RawEvent(
            type: .keyDown,
            timestamp: timestamp,
            keyCode: Int(keyCode),
            characters: characters,
            modifiers: modifiers.isEmpty ? nil : modifiers
        )

    case .scrollWheel:
        let deltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        let deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        return RawEvent(
            type: .scroll,
            timestamp: timestamp,
            x: location.x,
            y: location.y,
            scrollDeltaX: deltaX,
            scrollDeltaY: deltaY
        )

    default:
        return nil
    }
}
