import Foundation
import StorageCore
import Testing

struct StorageFailureDiagnosticTests {
    private struct Value: Decodable { let value: String }
    private struct Records: Decodable { let rows: [String: Value] }

    @Test func diagnosticsKeepSystemCodesAndDeclaredFieldsWhileMaskingPayloadKeys() throws {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: "private-payload"])
        let file = StorageFailureDiagnostic(error, operation: "read")
        #expect(file.summary == "read.\(NSCocoaErrorDomain).\(NSFileReadNoPermissionError)")
        do {
            _ = try JSONDecoder().decode(Records.self, from: Data(#"{"rows":{"private-account":{"value":1}}}"#.utf8))
            Issue.record("数据类型冲突需要保留诊断。")
        } catch {
            let failure = StorageFailureDiagnostic(error, operation: "decode", fields: ["rows", "value"])
            #expect(failure.summary == "decode.type:rows.*.value")
            #expect(!failure.summary.contains("private-account"))
        }
    }
}
