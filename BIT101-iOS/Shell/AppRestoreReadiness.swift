import Foundation
import StorageCore
import UIKit
import OSLog

/// 正式组装完成且场景活跃时，向装机工作流提供单一就绪信号。
@MainActor
enum AppRestoreReadiness {
    private static var initialized = false
    private static var sessionState: LoginScreenState?
    private static var recorded = false

    static func initializedScene() {
        initialized = true
        recordIfReady()
    }

    static func restoredSession(_ state: LoginScreenState) {
        sessionState = state
        recordIfReady()
    }

    static func sessionIsReady(_ state: LoginScreenState, storage: LoginStorage) -> Bool {
        guard storage.hasResolvedSession else { return false }
        switch state {
        case .signedOut: return !storage.hasCachedSession
        case let .signedIn(studentID): return storage.hasCachedSession && studentID == storage.currentStudentID
        }
    }

    static func recordIfReady() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !recorded, let index = arguments.firstIndex(of: "--restore-run-id"), arguments.indices.contains(index + 1),
              UUID(uuidString: arguments[index + 1]) != nil else { return }
        let digest = Bundle.main.object(forInfoDictionaryKey: "BIT101RestoreInputDigest") as? String ?? ""
        let active = UIApplication.shared.applicationState == .active
        let sessionRecovered = sessionState.map { sessionIsReady($0, storage: AppAccountSession.storage) } ?? false
        let digestValid = (UUID(uuidString: digest) != nil || digest.hasPrefix("git.")) && digest.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
        Logger(subsystem: "BIT101", category: "RestoreReadiness").info(
            "Restore readiness initialized=\(initialized) sessionRecovered=\(sessionRecovered) active=\(active) digestValid=\(digestValid)")
        guard initialized, sessionRecovered, active, digestValid else { return }
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
