import Foundation

/// PocketBase serialises dates as `yyyy-MM-dd HH:mm:ss.SSS'Z'` in UTC.
public enum PeardDate {
    /// The canonical format PocketBase emits and accepts.
    public static let canonicalFormat = "yyyy-MM-dd HH:mm:ss.SSS'Z'"

    /// Variant seen on some records (invite `expires`, for example) where the
    /// millisecond component is omitted. Accepted when parsing, never emitted.
    public static let formatWithoutMilliseconds = "yyyy-MM-dd HH:mm:ss'Z'"

    public static let timeZone = TimeZone(identifier: "UTC")!

    private static func formatter(_ dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        return formatter
    }

    /// Formats with millisecond precision so `format(parse(x))` is stable.
    public static func format(_ date: Date) -> String {
        formatter(canonicalFormat).string(from: date)
    }

    /// Parses the canonical format, falling back to the millisecond-less
    /// variant. Returns `nil` for empty or unrecognised input.
    public static func parse(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        if let date = formatter(canonicalFormat).date(from: value) { return date }
        return formatter(formatWithoutMilliseconds).date(from: value)
    }

    /// Truncates a `Date` to the precision the wire format can express, so
    /// round-trip comparisons are exact.
    public static func truncatedToMilliseconds(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.towardZero)
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    public static var decodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = parse(value) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "Unrecognised PocketBase date: \(value)")
                )
            }
            return date
        }
    }

    public static var encodingStrategy: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format(date))
        }
    }
}

public extension JSONDecoder {
    /// Decoder configured for every Pear'd wire payload.
    static var peard: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = PeardDate.decodingStrategy
        return decoder
    }
}

public extension JSONEncoder {
    static var peard: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = PeardDate.encodingStrategy
        return encoder
    }
}
