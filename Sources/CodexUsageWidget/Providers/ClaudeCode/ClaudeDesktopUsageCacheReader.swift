import Foundation
import Darwin

/// Claude Desktop quota values read entirely from the app's local Chromium HTTP cache.
///
/// This reader never opens a network connection, never reads cookies or Keychain
/// credentials, and never launches `claude`. Claude Desktop itself owns the
/// authenticated request; codexU only consumes the cached `/usage` response that
/// the official app has already written to disk.
struct ClaudeDesktopQuotaSnapshot {
    let exists: Bool
    let capturedAt: Date?
    let primary: RateWindow?
    let secondary: RateWindow?
    let organization: String?
    let entryPath: String?
    let discoveredOrganizationCount: Int
    let isStale: Bool

    var hasQuota: Bool {
        primary != nil || secondary != nil
    }

    static let empty = ClaudeDesktopQuotaSnapshot(
        exists: false,
        capturedAt: nil,
        primary: nil,
        secondary: nil,
        organization: nil,
        entryPath: nil,
        discoveredOrganizationCount: 0,
        isStale: false
    )
}

final class ClaudeDesktopUsageCacheReader {
    private struct Reading {
        let primary: RateWindow?
        let secondary: RateWindow?
        let capturedAt: Date
        let organization: String
        let entry: URL
    }

    private struct ParsedEntry {
        let body: Data
        let organization: String
        let date: Date?
    }

    private struct Frame {
        let data: Data
        let frameSize: Int
    }

    private static let maxEntryBytes = 512 * 1024
    private static let maxEntriesExamined = 400
    private static let maxDecompressedBytes = 256 * 1024
    private static let maxKeyBytes = 8 * 1024
    private static let headerBytes = 24
    private static let entryMagic: UInt64 = 0xfcfb_6d1b_a772_5c30
    private static let zstdMagic: [UInt8] = [0x28, 0xb5, 0x2f, 0xfd]
    private static let freshnessWindow: TimeInterval = 30 * 60

    func load(
        context: RuntimeLoadContext,
        messages: inout [String]
    ) -> ClaudeDesktopQuotaSnapshot {
        let directories = cacheDirectories(home: context.homeDirectory)
        guard !directories.isEmpty else {
            messages.append("未找到 Claude Desktop HTTP 缓存；请确认 Claude Desktop 已安装并登录")
            return .empty
        }

        var readings: [Reading] = []
        for directory in directories {
            readings.append(contentsOf: readRecentUsageEntries(in: directory, now: context.now))
        }

        guard let newest = readings.max(by: { $0.capturedAt < $1.capturedAt }) else {
            messages.append("Claude Desktop 本地缓存中暂无可识别的 Usage 响应；请在 Claude Desktop 打开 Settings → Usage")
            return ClaudeDesktopQuotaSnapshot(
                exists: true,
                capturedAt: nil,
                primary: nil,
                secondary: nil,
                organization: nil,
                entryPath: nil,
                discoveredOrganizationCount: 0,
                isStale: false
            )
        }

        let organizationCount = Set(readings.map(\.organization)).count
        if organizationCount > 1 {
            messages.append("检测到 \(organizationCount) 个 Claude Desktop 账号缓存，当前采用最近更新的一组 Usage 数据")
        }

        let age = context.now.timeIntervalSince(newest.capturedAt)
        let isStale = age > Self.freshnessWindow || age < -Self.freshnessWindow
        if isStale {
            let minutes = max(0, Int(age / 60))
            messages.append("Claude Desktop Usage 本地缓存已过期（约 \(minutes) 分钟前）；打开 Claude Desktop 的 Settings → Usage 可由官方 App 自行刷新")
        } else {
            messages.append("Claude 额度来源：Claude Desktop 本地 Usage 缓存（只读，无网络请求）")
        }

        return ClaudeDesktopQuotaSnapshot(
            exists: true,
            capturedAt: newest.capturedAt,
            primary: newest.primary,
            secondary: newest.secondary,
            organization: newest.organization,
            entryPath: newest.entry.path,
            discoveredOrganizationCount: organizationCount,
            isStale: isStale
        )
    }

    private func cacheDirectories(home: URL) -> [URL] {
        let root = home
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true)

        var candidates: [URL] = [
            root.appendingPathComponent("Cache/Cache_Data", isDirectory: true)
        ]

        // Chromium/Electron may place a named partition under Partitions/<name>.
        // Look only one level deep; never recursively walk the whole Claude tree.
        let partitions = root.appendingPathComponent("Partitions", isDirectory: true)
        if let children = try? FileManager.default.contentsOfDirectory(
            at: partitions,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }
                candidates.append(
                    child.appendingPathComponent("Cache/Cache_Data", isDirectory: true)
                )
            }
        }

        var seen = Set<String>()
        return candidates.filter { url in
            guard seen.insert(url.path).inserted else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    private func readRecentUsageEntries(in directory: URL, now: Date) -> [Reading] {
        recentEntries(in: directory).compactMap { reading(from: $0, now: now) }
    }

    private func recentEntries(in directory: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey
        ]
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        let candidates: [(url: URL, modified: Date)] = names.compactMap { url in
            guard url.lastPathComponent.hasSuffix("_0"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > Self.headerBytes,
                  size <= Self.maxEntryBytes,
                  let modified = values.contentModificationDate
            else {
                return nil
            }
            return (url, modified)
        }

        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(Self.maxEntriesExamined)
            .map(\.url)
    }

    private func reading(from entry: URL, now: Date) -> Reading? {
        guard let file = contents(of: entry),
              let parsed = Self.parse(entry: file.bytes),
              let windows = Self.decodeUsageBody(parsed.body)
        else {
            return nil
        }

        let capturedAt = parsed.date ?? file.modified ?? now
        return Reading(
            primary: windows.primary,
            secondary: windows.secondary,
            capturedAt: capturedAt,
            organization: parsed.organization,
            entry: entry
        )
    }

    private func contents(of entry: URL) -> (bytes: Data, modified: Date?)? {
        guard let handle = try? FileHandle(forReadingFrom: entry) else { return nil }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: Self.headerBytes + Self.maxKeyBytes),
              let key = Self.key(in: [UInt8](head)),
              Self.usageOrganization(inKey: key) != nil
        else {
            return nil
        }

        try? handle.seek(toOffset: 0)
        guard let bytes = try? handle.read(upToCount: Self.maxEntryBytes) else { return nil }

        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            return (bytes, nil)
        }
        let modified = Date(
            timeIntervalSince1970:
                TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return (bytes, modified)
    }

    private static func parse(entry bytes: Data) -> ParsedEntry? {
        let entry = [UInt8](bytes)
        guard let key = key(in: entry),
              let organization = usageOrganization(inKey: key)
        else {
            return nil
        }

        let bodyStart = Self.headerBytes + key.utf8.count
        guard bodyStart < entry.count else { return nil }

        let remainder = Array(entry[bodyStart...])
        if remainder.count >= Self.zstdMagic.count,
           Array(remainder.prefix(Self.zstdMagic.count)) == Self.zstdMagic,
           let body = decompress(frame: remainder) {
            let trailer = body.frameSize < remainder.count
                ? Array(remainder[body.frameSize...])
                : []
            return ParsedEntry(
                body: body.data,
                organization: organization,
                date: httpDate(inTrailer: trailer)
            )
        }

        // Forward-compatible fallback for a future Desktop build that writes the
        // JSON response without content encoding.
        let raw = Data(remainder)
        if let first = raw.first(where: { byte in
            byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D
        }), first == 0x7B || first == 0x5B {
            return ParsedEntry(body: raw, organization: organization, date: nil)
        }

        return nil
    }

    static func key(in entry: [UInt8]) -> String? {
        guard entry.count > Self.headerBytes,
              readUInt64(entry, at: 0) == Self.entryMagic
        else {
            return nil
        }

        let keyLength = Int(readUInt32(entry, at: 12))
        guard keyLength > 0,
              keyLength <= Self.maxKeyBytes,
              Self.headerBytes + keyLength <= entry.count
        else {
            return nil
        }

        return String(
            bytes: entry[Self.headerBytes..<(Self.headerBytes + keyLength)],
            encoding: .utf8
        )
    }

    static func usageOrganization(inKey key: String) -> String? {
        guard key.contains("claude.ai") || key.contains("anthropic.com"),
              let organizations = key.range(of: "/api/organizations/")
        else {
            return nil
        }

        let path = key[organizations.upperBound...].prefix { $0 != "?" && $0 != "#" }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2,
              !segments[0].isEmpty,
              segments[1] == "usage"
        else {
            return nil
        }
        return String(segments[0])
    }

    private static func decodeUsageBody(
        _ data: Data
    ) -> (primary: RateWindow?, secondary: RateWindow?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Some internal wrappers have historically placed the response under a
        // top-level `usage` field. Prefer the root but tolerate that shape.
        let object = (root["usage"] as? [String: Any]) ?? root

        var primary: RateWindow?
        var secondary: RateWindow?

        if let limits = object["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let kind = stringValue(limit["kind"]),
                      let percent = doubleValue(limit["percent"])
                else {
                    continue
                }
                let reset = dateValue(limit["resets_at"]) ?? dateValue(limit["resetsAt"])
                switch kind {
                case "session":
                    primary = RateWindow(
                        usedPercent: clampPercent(percent),
                        windowDurationMins: 300,
                        resetsAt: reset
                    )
                case "weekly_all":
                    secondary = RateWindow(
                        usedPercent: clampPercent(percent),
                        windowDurationMins: 10_080,
                        resetsAt: reset
                    )
                default:
                    break
                }
            }
        }

        func namedWindow(_ snake: String, _ camel: String, duration: Int) -> RateWindow? {
            let window = (object[snake] as? [String: Any]) ?? (object[camel] as? [String: Any])
            guard let window else { return nil }
            let used = doubleValue(window["utilization"])
                ?? doubleValue(window["used_percent"])
                ?? doubleValue(window["usedPercent"])
            guard let used else { return nil }
            let reset = dateValue(window["resets_at"]) ?? dateValue(window["resetsAt"])
            return RateWindow(
                usedPercent: clampPercent(used),
                windowDurationMins: duration,
                resetsAt: reset
            )
        }

        if primary == nil {
            primary = namedWindow("five_hour", "fiveHour", duration: 300)
        }
        if secondary == nil {
            secondary = namedWindow("seven_day", "sevenDay", duration: 10_080)
        }

        guard primary != nil || secondary != nil else { return nil }
        return (primary, secondary)
    }

    private static func clampPercent(_ value: Double) -> Double {
        max(0, min(100, value))
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let value = value as? NSNumber {
            let raw = value.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        guard let text = value as? String, !text.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    private static func httpDate(inTrailer trailer: [UInt8]) -> Date? {
        for name in ["date:", "Date:"] {
            let needle = [UInt8(0)] + Array(name.utf8)
            guard let start = firstIndex(of: needle, in: trailer) else { continue }
            let valueStart = start + needle.count
            guard valueStart < trailer.count,
                  let end = trailer[valueStart...].firstIndex(of: 0x00),
                  let text = String(bytes: trailer[valueStart..<end], encoding: .utf8),
                  let date = httpDateFormatter.date(
                    from: text.trimmingCharacters(in: .whitespaces)
                  )
            else {
                continue
            }
            return date
        }
        return nil
    }

    private static func decompress(frame bytes: [UInt8]) -> Frame? {
        guard !bytes.isEmpty else { return nil }

        return bytes.withUnsafeBytes { source -> Frame? in
            guard let sourceAddress = source.baseAddress else { return nil }
            let compressed = ZSTD_findFrameCompressedSize(sourceAddress, source.count)
            guard ZSTD_isError(compressed) == 0,
                  compressed > 0,
                  compressed <= source.count
            else {
                return nil
            }

            let declared = ZSTD_getFrameContentSize(sourceAddress, source.count)
            let unknownContentSize = UInt64.max
            let errorContentSize = UInt64.max - 1
            if declared != unknownContentSize,
               declared != errorContentSize,
               declared > UInt64(Self.maxDecompressedBytes) {
                return nil
            }

            var output = [UInt8](repeating: 0, count: Self.maxDecompressedBytes)
            let written = output.withUnsafeMutableBytes { destination -> Int in
                guard let destinationAddress = destination.baseAddress else { return -1 }
                return Int(
                    ZSTD_decompress(
                        destinationAddress,
                        destination.count,
                        sourceAddress,
                        compressed
                    )
                )
            }
            guard written > 0,
                  written <= output.count,
                  ZSTD_isError(written) == 0
            else {
                return nil
            }

            return Frame(
                data: Data(output[0..<written]),
                frameSize: Int(compressed)
            )
        }
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        var value: UInt32 = 0
        for index in (0..<4).reversed() {
            value = value << 8 | UInt32(bytes[offset + index])
        }
        return value
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = value << 8 | UInt64(bytes[offset + index])
        }
        return value
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) {
                return start
            }
        }
        return nil
    }

    static func diagnosticJSON(
        context: RuntimeLoadContext = .live()
    ) -> String {
        let reader = ClaudeDesktopUsageCacheReader()
        var messages: [String] = []
        let snapshot = reader.load(
            context: context,
            messages: &messages
        )

        func window(_ value: RateWindow?) -> [String: Any]? {
            guard let value else { return nil }
            var result: [String: Any] = [
                "usedPercent": value.usedPercent,
                "remainingPercent": value.remainingPercent
            ]
            if let duration = value.windowDurationMins {
                result["windowDurationMins"] = duration
            }
            if let resetsAt = value.resetsAt {
                result["resetsAt"] = ISO8601DateFormatter().string(from: resetsAt)
            }
            return result
        }

        // This second pass is diagnostic-only and counts parser stages without
        // exposing cache keys, organization IDs, file names, cookies or bodies.
        let directories = reader.cacheDirectories(home: context.homeDirectory)
        var candidateEntryCount = 0
        var usageKeyEntryCount = 0
        var zstdUsageEntryCount = 0
        var rawUsageEntryCount = 0
        var parsedBodyCount = 0
        var decodedUsageResponseCount = 0

        for directory in directories {
            for entry in reader.recentEntries(in: directory) {
                candidateEntryCount += 1
                guard let file = reader.contents(of: entry) else { continue }
                usageKeyEntryCount += 1

                let bytes = [UInt8](file.bytes)
                if let key = key(in: bytes) {
                    let bodyStart = Self.headerBytes + key.utf8.count
                    if bodyStart < bytes.count {
                        let remainder = Array(bytes[bodyStart...])
                        if remainder.count >= Self.zstdMagic.count,
                           Array(remainder.prefix(Self.zstdMagic.count)) == Self.zstdMagic {
                            zstdUsageEntryCount += 1
                        } else {
                            let raw = remainder.drop(while: { byte in
                                byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
                            })
                            if raw.first == 0x7B || raw.first == 0x5B {
                                rawUsageEntryCount += 1
                            }
                        }
                    }
                }

                guard let parsed = parse(entry: file.bytes) else { continue }
                parsedBodyCount += 1
                if decodeUsageBody(parsed.body) != nil {
                    decodedUsageResponseCount += 1
                }
            }
        }

        var object: [String: Any] = [
            "desktopCacheDetected": snapshot.exists,
            "cacheDirectoryCount": directories.count,
            "candidateEntryCount": candidateEntryCount,
            "usageKeyEntryCount": usageKeyEntryCount,
            "zstdUsageEntryCount": zstdUsageEntryCount,
            "rawUsageEntryCount": rawUsageEntryCount,
            "parsedBodyCount": parsedBodyCount,
            "decodedUsageResponseCount": decodedUsageResponseCount,
            "hasQuota": snapshot.hasQuota,
            "isStale": snapshot.isStale,
            "organizationCount": snapshot.discoveredOrganizationCount,
            "messages": messages,
            "networkUsedByCodexU": false,
            "credentialsReadByCodexU": false
        ]
        if let capturedAt = snapshot.capturedAt {
            object["capturedAt"] = ISO8601DateFormatter().string(from: capturedAt)
        }
        if let primary = window(snapshot.primary) {
            object["fiveHour"] = primary
        }
        if let secondary = window(snapshot.secondary) {
            object["sevenDay"] = secondary
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "{\"error\":\"failed to encode diagnostic report\"}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func selfTest() -> Bool {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        expect(
            usageOrganization(
                inKey: "1/0/https://claude.ai/api/organizations/org-test/usage?skip_spend=1"
            ) == "org-test",
            "Claude Desktop cache key should resolve its organization"
        )
        expect(
            usageOrganization(inKey: "https://example.com/api/organizations/org-test/usage") == nil,
            "non-Claude hosts must never be treated as Claude usage cache"
        )

        let limitsJSON = """
        {
          "limits": [
            {"kind":"session","percent":12.5,"resets_at":"2026-09-26T12:00:00Z"},
            {"kind":"weekly_all","percent":34.0,"resets_at":"2026-09-30T12:00:00Z"}
          ]
        }
        """
        let limits = decodeUsageBody(Data(limitsJSON.utf8))
        expect(abs((limits?.primary?.usedPercent ?? -1) - 12.5) < 0.000_001,
               "session limit should decode from limits[]")
        expect(limits?.primary?.windowDurationMins == 300,
               "session limit should be classified as 5h")
        expect(abs((limits?.secondary?.usedPercent ?? -1) - 34.0) < 0.000_001,
               "weekly_all should decode from limits[]")
        expect(limits?.secondary?.windowDurationMins == 10_080,
               "weekly_all should be classified as 7d")

        let legacyJSON = """
        {
          "five_hour": {"utilization": 7.0, "resets_at": "2026-09-26T13:00:00Z"},
          "seven_day": {"utilization": 21.0, "resets_at": "2026-10-01T13:00:00Z"}
        }
        """
        let legacy = decodeUsageBody(Data(legacyJSON.utf8))
        expect(abs((legacy?.primary?.usedPercent ?? -1) - 7.0) < 0.000_001,
               "five_hour fallback should decode")
        expect(abs((legacy?.secondary?.usedPercent ?? -1) - 21.0) < 0.000_001,
               "seven_day fallback should decode")

        if failures.isEmpty {
            print("Claude Desktop cache self-test passed")
            return true
        }
        failures.forEach { print("Claude Desktop cache self-test failed: \($0)") }
        return false
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
