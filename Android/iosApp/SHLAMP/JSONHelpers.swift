import Foundation

typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func object(_ keys: String...) -> JSONObject? {
        for key in keys {
            if let value = self[key] as? JSONObject { return value }
        }
        return nil
    }

    func array(_ keys: String...) -> [Any]? {
        for key in keys {
            if let value = self[key] as? [Any] { return value }
        }
        return nil
    }

    func string(_ keys: String...) -> String {
        for key in keys {
            if let value = self[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let value = self[key] as? NSNumber { return value.stringValue }
        }
        return ""
    }

    func int(_ keys: String...) -> Int? {
        for key in keys {
            if let value = self[key] as? Int { return value }
            if let value = self[key] as? NSNumber { return value.intValue }
            if let value = self[key] as? String, let parsed = Double(value) { return Int(parsed) }
        }
        return nil
    }

    func int64(_ keys: String...) -> Int64? {
        int(keys.first ?? "").map(Int64.init)
    }

    func bool(_ keys: String...) -> Bool? {
        for key in keys {
            if let value = self[key] as? Bool { return value }
            if let value = self[key] as? NSNumber { return value.boolValue }
            if let value = self[key] as? String {
                switch value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
                case "true", "1", "yes", "on", "online", "charging": return true
                case "false", "0", "no", "off", "offline", "idle", "not_charging": return false
                default: continue
                }
            }
        }
        return nil
    }
}

func parseJSONObject(_ data: Data) throws -> JSONObject {
    guard let object = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
        throw AppError.message("The server returned an invalid response.")
    }
    return object
}

func jsonData(_ object: JSONObject) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [])
}

func firstNonBlank(_ values: String...) -> String {
    values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
}

func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
}
