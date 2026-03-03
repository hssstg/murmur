import Foundation
import CryptoKit

// MARK: - Volcengine V4 Signer

private enum VolcSigner {
    static let algorithm  = "HMAC-SHA256"
    static let terminator = "request"

    static func sign(
        method: String,
        host: String,
        path: String,
        queryParams: [(key: String, value: String)],
        headers: inout [(key: String, value: String)],
        body: Data,
        ak: String,
        sk: String,
        service: String,
        region: String
    ) {
        let now = Date()
        let dateStr     = utcFormatter("yyyyMMdd").string(from: now)
        let datetimeStr = utcFormatter("yyyyMMdd'T'HHmmss'Z'").string(from: now)

        headers.append((key: "X-Date", value: datetimeStr))

        // Canonical headers (sorted by lowercase key)
        let sorted = headers.sorted { $0.key.lowercased() < $1.key.lowercased() }
        let canonicalHeaders = sorted
            .map { "\($0.key.lowercased()):\($0.value.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n") + "\n"
        let signedHeaders = sorted.map { $0.key.lowercased() }.joined(separator: ";")

        // Canonical query string (sorted, URL-encoded)
        let canonicalQuery = queryParams
            .sorted { $0.key < $1.key }
            .map { "\(rfc3986($0.key))=\(rfc3986($0.value))" }
            .joined(separator: "&")

        // Body hash
        let bodyHash = SHA256.hash(data: body).hexString

        // Canonical request
        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, bodyHash]
            .joined(separator: "\n")
        let canonicalHash = SHA256.hash(data: Data(canonicalRequest.utf8)).hexString

        // String to sign
        let credentialScope = "\(dateStr)/\(region)/\(service)/\(terminator)"
        let stringToSign = "\(algorithm)\n\(datetimeStr)\n\(credentialScope)\n\(canonicalHash)"

        // Signing key
        let kDate    = hmac(key: Data(sk.utf8),  msg: Data(dateStr.utf8))
        let kRegion  = hmac(key: kDate,           msg: Data(region.utf8))
        let kService = hmac(key: kRegion,         msg: Data(service.utf8))
        let kSigning = hmac(key: kService,        msg: Data(terminator.utf8))

        let signature = hmac(key: kSigning, msg: Data(stringToSign.utf8)).hexString

        let authorization = "\(algorithm) Credential=\(ak)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        headers.append((key: "Authorization", value: authorization))
    }

    private static func hmac(key: Data, msg: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func rfc3986(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func utcFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Volcengine Hotwords Client

public enum SyncError: Error, LocalizedError {
    case apiError(code: String, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .apiError(let code, let msg): return "[\(code)] \(msg)"
        case .invalidResponse: return "无效响应"
        }
    }
}

public enum VolcHotwordsClient {

    private static let host    = "open.volcengineapi.com"
    private static let service = "speech_saas_prod"
    private static let region  = "cn-north-1"
    private static let version = "2022-08-30"

    // MARK: - Public API

    /// Fetch the current word list from Volcengine boosting table.
    /// Returns nil if the table doesn't exist yet.
    public static func fetchWords(ak: String, sk: String, appId: String, tableName: String) async throws -> [String]? {
        let body = try JSONSerialization.data(withJSONObject: [
            "AppID": appId, "PageNumber": 1, "PageSize": 50, "PreviewSize": 10000
        ])
        let resp = try await jsonCall(ak: ak, sk: sk, action: "ListBoostingTable", body: body)
        guard let result = resp["Result"] as? [String: Any],
              let tables = result["BoostingTables"] as? [[String: Any]] else {
            fputs("[hotwords] fetchWords: no BoostingTables in Result\n", stderr)
            return nil
        }
        guard let table = tables.first(where: { $0["BoostingTableName"] as? String == tableName }) else {
            fputs("[hotwords] fetchWords: table '\(tableName)' not found\n", stderr)
            return nil
        }
        if let preview = table["Preview"] as? [String] {
            return preview
        }
        if let preview = table["Preview"] as? String {
            return preview.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        fputs("[hotwords] fetchWords: Preview field missing or unexpected type\n", stderr)
        return []
    }

    /// Upload local words to Volcengine boosting table (create or update).
    public static func sync(ak: String, sk: String, appId: String, tableName: String, words: [String]) async throws -> String {
        // Filter words containing forbidden characters (Volcengine restriction)
        let filtered = words.filter { !$0.contains(where: { "/\\|<>'".contains($0) }) }

        // Find existing table
        let tableID = try await findTableID(ak: ak, sk: sk, appId: appId, tableName: tableName)

        let action: String
        var fields: [(String, String)]
        if let id = tableID {
            action = "UpdateBoostingTable"
            fields = [("AppID", appId), ("BoostingTableID", id)]
        } else {
            action = "CreateBoostingTable"
            fields = [("AppID", appId), ("BoostingTableName", tableName)]
        }

        let fileBytes = filtered.joined(separator: "\n").data(using: .utf8) ?? Data()
        let result = try await multipartCall(ak: ak, sk: sk, action: action, fields: fields, fileBytes: fileBytes)

        guard let wordCount = result["WordCount"] as? Int ?? (result["WordCount"].flatMap { String(describing: $0) }.flatMap(Int.init)) else {
            return "同步成功（词数未知）"
        }
        return "同步成功，词数 \(wordCount)"
    }

    // MARK: - Private

    private static func findTableID(ak: String, sk: String, appId: String, tableName: String) async throws -> String? {
        let body = try JSONSerialization.data(withJSONObject: [
            "AppID": appId, "PageNumber": 1, "PageSize": 50
        ])
        let resp = try await jsonCall(ak: ak, sk: sk, action: "ListBoostingTable", body: body)
        guard let result = resp["Result"] as? [String: Any],
              let tables = result["BoostingTables"] as? [[String: Any]] else { return nil }
        return tables.first(where: { $0["BoostingTableName"] as? String == tableName })
            .flatMap { t -> String? in
                if let id = t["BoostingTableID"] as? String { return id }
                if let id = t["BoostingTableID"] as? Int    { return String(id) }
                return nil
            }
    }

    private static func jsonCall(ak: String, sk: String, action: String, body: Data) async throws -> [String: Any] {
        let queryParams = [("Action", action), ("Version", version)]
        var headers: [(key: String, value: String)] = [
            (key: "Content-Type", value: "application/json"),
            (key: "Host",         value: host),
        ]
        VolcSigner.sign(method: "POST", host: host, path: "/", queryParams: queryParams,
                        headers: &headers, body: body, ak: ak, sk: sk, service: service, region: region)

        let qs = queryParams.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        var req = URLRequest(url: URL(string: "https://\(host)/?\(qs)")!)
        req.httpMethod = "POST"
        req.httpBody   = body
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.invalidResponse
        }
        if let meta = json["ResponseMetadata"] as? [String: Any],
           let err  = meta["Error"] as? [String: Any],
           let code = err["Code"] as? String,
           let msg  = err["Message"] as? String {
            throw SyncError.apiError(code: code, message: msg)
        }
        return json
    }

    private static func multipartCall(ak: String, sk: String, action: String,
                                      fields: [(String, String)], fileBytes: Data) async throws -> [String: Any] {
        let boundary = "MurmurHotwordsBoundary"
        var body = Data()

        for (name, value) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8Data)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"File\"; filename=\"hotwords.txt\"\r\nContent-Type: text/plain\r\n\r\n".utf8Data)
        body.append(fileBytes)
        body.append("\r\n--\(boundary)--\r\n".utf8Data)

        let contentType = "multipart/form-data; boundary=\(boundary)"
        let queryParams = [("Action", action), ("Version", version)]
        var headers: [(key: String, value: String)] = [
            (key: "Content-Type", value: contentType),
            (key: "Host",         value: host),
        ]
        VolcSigner.sign(method: "POST", host: host, path: "/", queryParams: queryParams,
                        headers: &headers, body: body, ak: ak, sk: sk, service: service, region: region)

        let qs = queryParams.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        var req = URLRequest(url: URL(string: "https://\(host)/?\(qs)")!)
        req.httpMethod = "POST"
        req.httpBody   = body
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.invalidResponse
        }
        if let meta = json["ResponseMetadata"] as? [String: Any],
           let err  = meta["Error"] as? [String: Any],
           let code = err["Code"] as? String,
           let msg  = err["Message"] as? String {
            throw SyncError.apiError(code: code, message: msg)
        }
        return json["Result"] as? [String: Any] ?? [:]
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}
