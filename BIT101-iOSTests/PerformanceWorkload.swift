import Foundation

nonisolated struct PerformanceWorkload {
    private let input: [String: Any]

    init(_ scene: String, bundle: Bundle) throws {
        guard let url = bundle.url(forResource: "PerformanceWorkloads", withExtension: "json"),
              let records = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]],
              let input = records[scene]?["input"] as? [String: Any] else {
            throw NSError(domain: "BIT101.PerformanceFixture", code: 1)
        }
        self.input = input
    }

    func value<Value: Decodable>(_ key: String, as type: Value.Type = Value.self) throws -> Value {
        guard let value = input[key] else { throw NSError(domain: "BIT101.PerformanceFixture", code: 2) }
        let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        return try JSONDecoder().decode(type, from: data)
    }
}
