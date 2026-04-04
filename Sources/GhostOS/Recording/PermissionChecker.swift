import Foundation
import ApplicationServices
import CoreGraphics

@MainActor
public struct PermissionChecker: Sendable {
    public struct PermissionStatus: Sendable {
        public let accessibility: Bool
        public let eventTap: Bool
        public let allGranted: Bool
        public let errorMessage: String?
    }

    public static func check() -> PermissionStatus {
        let hasAccessibility = AXIsProcessTrusted()

        // listenOnly で EventTap 作成テスト（作成後すぐ破棄）
        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let testTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, _, event, _ in Unmanaged.passRetained(event) },
            userInfo: nil
        )
        let hasEventTap = testTap != nil
        if let tap = testTap {
            CFMachPortInvalidate(tap)
        }

        let allGranted = hasAccessibility && hasEventTap

        var errorParts: [String] = []
        if !hasAccessibility {
            errorParts.append("アクセシビリティ権限が不足しています。「システム設定 > プライバシーとセキュリティ > アクセシビリティ」でこのアプリを許可してください。")
        }
        if !hasEventTap {
            errorParts.append("入力監視権限が不足しています。「システム設定 > プライバシーとセキュリティ > 入力監視」でこのアプリを許可してください。")
        }

        return PermissionStatus(
            accessibility: hasAccessibility,
            eventTap: hasEventTap,
            allGranted: allGranted,
            errorMessage: errorParts.isEmpty ? nil : errorParts.joined(separator: "\n")
        )
    }
}
