import Foundation
import CryptoKit

// MARK: - AWS Signature Version 4
//
// The app signs its own Bedrock requests instead of carrying the AWS SDK: SigV4 is a few hashes over
// a canonical form of the request. The canonical form follows botocore exactly (the reference
// implementation the tests were checked against): every header named x-amz-* is signed along with
// host and content-type; the path is normalised (no dot segments, no empty segments) and
// percent-encoded a second time, so a model id sent as ".../v1%3A0/..." is signed as
// ".../v1%253A0/..."; query parameters are decoded, re-encoded with the RFC 3986 unreserved set and
// sorted by key, then value.

public enum SigV4 {
    public static let algorithm = "AWS4-HMAC-SHA256"

    /// Hex SHA-256 of an empty payload (GETs, presigned URLs).
    public static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// Longest a presigned URL may live (AWS's own limit).
    public static let maxPresignLifetime: TimeInterval = 7 * 24 * 3600

    public enum Failure: Error, LocalizedError, Equatable {
        case noURL
        case badLifetime

        public var errorDescription: String? {
            switch self {
            case .noURL: "The request has no URL."
            case .badLifetime: "A presigned URL lives between 1 second and 7 days."
            }
        }
    }

    /// Percent-encode everything but the RFC 3986 unreserved characters
    /// (A–Z a–z 0–9 - _ . ~), UTF-8 first, upper-case hex — botocore's
    /// `percent_encode`. This is how a path parameter such as a Bedrock model
    /// id or inference-profile ARN goes into a URL: ':' → %3A, '/' → %2F.
    public static func encode(_ value: String, keepSlash: Bool = false) -> String {
        var output = ""
        output.reserveCapacity(value.utf8.count * 3 / 2)
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                output.unicodeScalars.append(Unicode.Scalar(byte))
            case UInt8(ascii: "/") where keepSlash:
                output.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                output += "%" + hexDigits(byte).uppercased()
            }
        }
        return output
    }

    /// The "20260929T123456Z" timestamp SigV4 uses.
    public static func amzDate(_ now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Sign `request` in place with an Authorization header, adding X-Amz-Date
    /// and (for temporary credentials) X-Amz-Security-Token. `body` must be
    /// exactly the bytes the request sends. Safe to call again on a retry:
    /// earlier auth headers are replaced. `contentSHA256` also sends the
    /// payload hash as X-Amz-Content-SHA256 (S3 wants it; Bedrock doesn't).
    public static func sign(_ request: inout URLRequest, body: Data, credentials: AWSCredentials,
                            region: String, service: String, now: Date,
                            contentSHA256: Bool = false) throws {
        guard let url = request.url else { throw Failure.noURL }
        let amzDate = amzDate(now)
        let payloadHash = hex(Data(SHA256.hash(data: body)))
        for name in ["Authorization", "X-Amz-Date", "X-Amz-Security-Token", "X-Amz-Content-SHA256"] {
            request.setValue(nil, forHTTPHeaderField: name)
        }
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        if contentSHA256 { request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-SHA256") }

        var headers: [String: String] = ["host": host(of: url)]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let lower = name.lowercased()
            if lower.hasPrefix("x-amz-") { headers[lower] = headerValue(value) }
        }
        if let contentType = request.value(forHTTPHeaderField: "Content-Type") {
            headers["content-type"] = headerValue(contentType)
        }

        let signedHeaders = headers.keys.sorted().joined(separator: ";")
        let canonical = canonicalRequest(method: request.httpMethod ?? "GET", url: url,
                                         canonicalQuery: canonicalQuery(parameters(of: url)),
                                         headers: headers, payloadHash: payloadHash)
        let scope = scope(amzDate, region, service)
        let signature = signature(secret: credentials.secretAccessKey, amzDate: amzDate,
                                  region: region, service: service, canonicalRequest: canonical)
        request.setValue("\(algorithm) Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    /// A presigned URL (query-string auth, as botocore's SigV4QueryAuth builds
    /// it): the URL's own parameters, then X-Amz-Algorithm, -Credential, -Date,
    /// -Expires, -SignedHeaders and, for temporary credentials, -Security-Token,
    /// then X-Amz-Signature — in that order, which matters because a Bedrock API
    /// key embeds the URL text. Only the host header is signed and the payload
    /// hash is that of an empty body. Returned as text: the exact characters are
    /// what a Bedrock API key carries, and `URL` would re-canonicalise them.
    public static func presign(method: String, url: URL, credentials: AWSCredentials,
                               region: String, service: String, now: Date,
                               expires: TimeInterval) throws -> String {
        guard expires > 0, expires <= maxPresignLifetime else { throw Failure.badLifetime }
        let amzDate = amzDate(now)
        let scope = scope(amzDate, region, service)
        var params = parameters(of: url)
        params.append(("X-Amz-Algorithm", algorithm))
        params.append(("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"))
        params.append(("X-Amz-Date", amzDate))
        params.append(("X-Amz-Expires", String(Int64(expires))))
        params.append(("X-Amz-SignedHeaders", "host"))
        if let token = credentials.sessionToken, !token.isEmpty {
            params.append(("X-Amz-Security-Token", token))
        }

        let headers = ["host": host(of: url)]
        let canonical = canonicalRequest(method: method, url: url, canonicalQuery: canonicalQuery(params),
                                         headers: headers, payloadHash: emptyPayloadHash)
        let signature = signature(secret: credentials.secretAccessKey, amzDate: amzDate,
                                  region: region, service: service, canonicalRequest: canonical)
        let query = params.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&")
        let path = pathOf(url)
        return "\(url.scheme ?? "https")://\(host(of: url))\(path.isEmpty ? "/" : path)?\(query)&X-Amz-Signature=\(signature)"
    }

    // MARK: Canonical form

    static func canonicalRequest(method: String, url: URL, canonicalQuery: String,
                                 headers: [String: String], payloadHash: String) -> String {
        var text = method.uppercased() + "\n"
        text += canonicalPath(pathOf(url)) + "\n"
        text += canonicalQuery + "\n"
        let names = headers.keys.sorted()
        for name in names { text += "\(name):\(headers[name]!)\n" }
        text += "\n"
        text += names.joined(separator: ";") + "\n"
        text += payloadHash
        return text
    }

    /// The path as sent (already percent-encoded), with dot and empty segments
    /// removed, then encoded once more — AWS signs every service but S3 over
    /// the doubly-encoded path.
    static func canonicalPath(_ path: String) -> String {
        if path.isEmpty { return "/" }
        var output: [Substring] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            if segment.isEmpty || segment == "." { continue }
            if segment == ".." {
                if !output.isEmpty { output.removeLast() }
                continue
            }
            output.append(segment)
        }
        let normalised = (path.hasPrefix("/") ? "/" : "")
            + output.joined(separator: "/")
            + (path.hasSuffix("/") && !output.isEmpty ? "/" : "")
        return encode(normalised, keepSlash: true)
    }

    /// The URL's query parameters, decoded, in order.
    static func parameters(of url: URL) -> [(key: String, value: String)] {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        guard !raw.isEmpty else { return [] }
        var result: [(key: String, value: String)] = []
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let text = String(pair)
            let key: String
            let value: String
            if let equals = text.firstIndex(of: "=") {
                key = String(text[..<equals])
                value = String(text[text.index(after: equals)...])
            } else {
                key = text
                value = ""
            }
            result.append((key.removingPercentEncoding ?? key, value.removingPercentEncoding ?? value))
        }
        return result
    }

    static func canonicalQuery(_ parameters: [(key: String, value: String)]) -> String {
        parameters
            .map { (key: encode($0.key), value: encode($0.value)) }
            .sorted { $0.key != $1.key ? $0.key < $1.key : $0.value < $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
    }

    /// host[:port], the port only when it isn't the scheme's default.
    static func host(of url: URL) -> String {
        let host = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? url.host ?? "").lowercased()
        guard let port = url.port else { return host }
        let isDefault = (url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)
        return isDefault ? host : "\(host):\(port)"
    }

    /// The path exactly as it will be sent (percent-encoding preserved).
    private static func pathOf(_ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
    }

    /// Trimmed, with inner runs of whitespace collapsed to one space.
    private static func headerValue(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    private static func scope(_ amzDate: String, _ region: String, _ service: String) -> String {
        "\(amzDate.prefix(8))/\(region)/\(service)/aws4_request"
    }

    private static func signature(secret: String, amzDate: String, region: String, service: String,
                                  canonicalRequest: String) -> String {
        let stringToSign = "\(algorithm)\n\(amzDate)\n\(scope(amzDate, region, service))\n"
            + hex(Data(SHA256.hash(data: Data(canonicalRequest.utf8))))
        var key = hmac(Data("AWS4\(secret)".utf8), String(amzDate.prefix(8)))
        key = hmac(key, region)
        key = hmac(key, service)
        key = hmac(key, "aws4_request")
        return hex(hmac(key, stringToSign))
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    private static let hexTable = Array("0123456789abcdef")

    private static func hex(_ data: Data) -> String {
        var out = ""
        out.reserveCapacity(data.count * 2)
        for byte in data { out += hexDigits(byte) }
        return out
    }

    private static func hexDigits(_ byte: UInt8) -> String {
        String([hexTable[Int(byte >> 4)], hexTable[Int(byte & 0x0F)]])
    }
}
