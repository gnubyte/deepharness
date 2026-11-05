import Foundation

// MARK: - Short-term Bedrock API keys
//
// A short-term Bedrock API key is a presigned request in disguise, minted offline from AWS
// credentials exactly as AWS's aws-bedrock-token-generator does it: SigV4-presign POST
// https://bedrock.amazonaws.com/?Action=CallWithBearerToken for service "bedrock" in the Region,
// drop the "https://", append "&Version=1", base64 the result and prefix "bedrock-api-key-".
// Bedrock verifies the embedded signature, so the key lives as long as the presigned URL (at most
// 12 hours) and no longer than the credentials that signed it.

public enum BedrockAPIKeys {
    public static let prefix = "bedrock-api-key-"

    /// The longest life AWS gives a short-term key.
    public static let maxLifetime: TimeInterval = 12 * 3600

    private static let endpoint = URL(string: "https://bedrock.amazonaws.com/?Action=CallWithBearerToken")!

    public struct Expired: Error, LocalizedError, Equatable {
        public var errorDescription: String? {
            "The AWS credentials have expired; sign in again to create a Bedrock API key."
        }
    }

    /// Mint a key for `region` valid for `lifetime` seconds (default and cap: 12
    /// hours), cut short to when `credentials` expire — a key signed by expired
    /// temporary credentials is refused anyway, and `describe` should tell the truth.
    public static func create(credentials: AWSCredentials, region: String, now: Date,
                              lifetime: TimeInterval? = nil) throws -> String {
        var life = min(lifetime ?? maxLifetime, maxLifetime)
        if let expiry = credentials.expiration, expiry.timeIntervalSince(now) < life {
            life = expiry.timeIntervalSince(now)
        }
        let seconds = life.rounded(.down)
        guard seconds >= 1 else { throw Expired() }
        let url = try SigV4.presign(method: "POST", url: endpoint, credentials: credentials, region: region,
                                    service: "bedrock", now: now, expires: seconds)
        let text = String(url.dropFirst("https://".count)) + "&Version=1"
        return prefix + Data(text.utf8).base64EncodedString()
    }

    /// What a short-term key says about itself.
    public struct KeyInfo: Equatable, Sendable {
        public let region: String
        public let issued: Date
        public let expires: Date
        public let accessKeyID: String
    }

    /// The Region and validity of a short-term key; nil for anything else (a
    /// long-term key is opaque, and garbage is garbage).
    public static func describe(_ key: String) -> KeyInfo? {
        guard key.hasPrefix(prefix),
              let data = Data(base64Encoded: String(key.dropFirst(prefix.count))),
              let url = String(data: data, encoding: .utf8),
              let question = url.firstIndex(of: "?") else { return nil }
        var parameters: [String: String] = [:]
        for pair in url[url.index(after: question)...].split(separator: "&") {
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else { continue }
            let name = String(pair[..<equals])
            let value = String(pair[pair.index(after: equals)...])
            parameters[name] = value.removingPercentEncoding ?? value
        }
        // Credential = AKID/yyyyMMdd/region/bedrock/aws4_request
        guard let credential = parameters["X-Amz-Credential"] else { return nil }
        let scope = credential.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard scope.count == 5,
              let date = parameters["X-Amz-Date"], let issued = parseAmzDate(date),
              let expires = parameters["X-Amz-Expires"], expires.allSatisfy(\.isASCII), let seconds = Int64(expires)
        else { return nil }
        return KeyInfo(region: scope[2], issued: issued, expires: issued.addingTimeInterval(TimeInterval(seconds)),
                       accessKeyID: scope[0])
    }

    /// "20260929T123456Z" → a Date, or nil when it isn't one.
    static func parseAmzDate(_ text: String) -> Date? {
        let chars = Array(text)
        guard chars.count == 16, chars[8] == "T", chars[15] == "Z" else { return nil }
        func number(_ range: Range<Int>) -> Int? { Int(String(chars[range])) }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))
    }
}
