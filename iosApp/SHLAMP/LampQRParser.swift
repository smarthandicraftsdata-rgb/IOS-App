import Foundation

enum LampQRParser {
    private static let pattern = try! NSRegularExpression(pattern: "SH-[A-Z0-9]{4,16}")

    static func parse(_ raw: String) throws -> LampQRPayload {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AppError.message("The scanned code is empty.") }

        if text.hasPrefix("{"),
           let data = text.data(using: .utf8),
           let json = try? parseJSONObject(data) {
            let lampId = firstNonBlank(json.string("lampId"), json.string("deviceId"), json.string("serial")).uppercased()
            guard isValid(lampId) else { throw AppError.message("Invalid lamp ID.") }
            return LampQRPayload(
                lampId: lampId,
                claimCode: firstNonBlank(json.string("claimCode"), json.string("code"), json.string("setupCode")).prefix(32).description,
                model: json.string("model").prefix(40).description
            )
        }

        if let components = URLComponents(string: text),
           components.scheme?.lowercased() == "shlamp" || components.host?.lowercased() == "setup.shlamp" || components.host?.lowercased() == "smarthandicrafts.com" {
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let lampId = firstNonBlank(query["lampId"] ?? "", query["deviceId"] ?? "", components.url?.lastPathComponent ?? "").uppercased()
            guard isValid(lampId) else { throw AppError.message("Invalid lamp ID.") }
            return LampQRPayload(
                lampId: lampId,
                claimCode: firstNonBlank(query["claimCode"] ?? "", query["code"] ?? "").prefix(32).description,
                model: (query["model"] ?? "").prefix(40).description
            )
        }

        let parts = text.split(whereSeparator: { "|;,".contains($0) }).map { String($0).trimmingCharacters(in: .whitespaces) }
        if let lampId = parts.first(where: { isValid($0.uppercased()) })?.uppercased() {
            let code = parts.first(where: { $0.uppercased() != lampId && (6...32).contains($0.count) }) ?? ""
            return LampQRPayload(lampId: lampId, claimCode: code, model: "")
        }

        let upper = text.uppercased()
        let range = NSRange(upper.startIndex..<upper.endIndex, in: upper)
        guard let match = pattern.firstMatch(in: upper, range: range),
              let swiftRange = Range(match.range, in: upper) else {
            throw AppError.message("This is not an SH Lamp code.")
        }
        let lampId = String(upper[swiftRange])
        let code = text.replacingOccurrences(of: lampId, with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: " |:;,-"))
        return LampQRPayload(lampId: lampId, claimCode: String(code.prefix(32)), model: "")
    }

    private static func isValid(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return pattern.firstMatch(in: value, range: range)?.range == range
    }
}
