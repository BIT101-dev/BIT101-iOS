import Foundation
import StorageCore
import UIKit
import OSLog

/// 正式组装完成且场景活跃时，向装机工作流提供单一就绪信号。
@MainActor
enum AppRestoreReadiness {
    private static var initialized = false
    private static var sessionRecovered = false
    private static var recorded = false

    static func initializedScene() {
        initialized = true
        recordIfReady()
    }

    static func restoredSession(_ state: LoginScreenState) {
        let storage = AppAccountSession.storage
        switch state {
        case .signedOut: sessionRecovered = storage.fakeCookie.isEmpty
        case let .signedIn(studentID): sessionRecovered = !storage.fakeCookie.isEmpty && studentID == storage.currentStudentID
        }
        sessionRecovered = sessionRecovered && storage.credentialReadIssue == nil
        recordIfReady()
    }

    static func recordIfReady() {
        let arguments = ProcessInfo.processInfo.arguments
        guard initialized, sessionRecovered, !recorded, UIApplication.shared.applicationState == .active,
              let index = arguments.firstIndex(of: "--restore-run-id"), arguments.indices.contains(index + 1),
              UUID(uuidString: arguments[index + 1]) != nil,
              let digest = Bundle.main.object(forInfoDictionaryKey: "BIT101RestoreInputDigest") as? String,
              digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let proof: [String: Any] = ["schemaVersion": 1, "runID": arguments[index + 1], "inputDigest": digest,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "executablePath": Bundle.main.executableURL?.path ?? "",
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "version": info["CFBundleShortVersionString"] ?? "", "build": info["CFBundleVersion"] ?? "",
            "initialized": true, "sessionRecovered": true, "active": true, "readyAt": Date().ISO8601Format()]
        do {
            guard let documents = AppFileDirectories.files.directoryURL(.documentDirectory) else { throw CocoaError(.fileNoSuchFile) }
            try AppFileDirectories.files.writeData(JSONSerialization.data(withJSONObject: proof),
                to: documents.appendingPathComponent("restore-readiness.json"), options: [.atomic, .completeFileProtection])
            recorded = true
        } catch {
            Logger(subsystem: "BIT101", category: "RestoreReadiness").error("Restore readiness write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
