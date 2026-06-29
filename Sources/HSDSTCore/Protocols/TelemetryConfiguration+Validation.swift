import Foundation

/// Shared, pure OTLP/telemetry configuration validation and attribute-limiting
/// logic used by every `TelemetryProtocol` implementation.
///
/// This lives in `HSDSTCore` so the deterministic simulator
/// (`SimulatedTelemetry`) and the SDK-backed production implementation
/// (`ProductionTelemetry`) share a single source of truth. Keeping this logic
/// in one place guarantees sim/prod parity by construction instead of by manual
/// copy-paste synchronization.
extension TelemetryConfiguration {
    public var normalizedProtocolName: String {
        protocolName.lowercased()
    }

    public var otlpProtocolIsHTTP: Bool {
        let normalized = normalizedProtocolName
        return normalized == "http/protobuf" || normalized == "http"
    }

    public var otlpProtocolIsGRPC: Bool {
        let normalized = normalizedProtocolName
        return normalized == "grpc" || normalized == "otlp-grpc"
    }

    public var otlpProtocolIsSupported: Bool {
        otlpProtocolIsHTTP || otlpProtocolIsGRPC
    }

    /// Whether the given propagator name is enabled, ignoring case and hyphens
    /// (so `tracecontext` and `TraceContext` match).
    public func propagationEnabled(_ name: String) -> Bool {
        let normalized = TelemetryConfiguration.normalizePropagatorName(name)
        return propagators.contains {
            TelemetryConfiguration.normalizePropagatorName($0) == normalized
        }
    }

    private static func normalizePropagatorName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// Whether any configured OTLP header looks like a credential, which we
    /// refuse to send over non-loopback cleartext HTTP.
    public var hasSensitiveOTLPHeaders: Bool {
        headers.keys.contains { key in
            let normalized = key.lowercased()
            return normalized == "authorization"
                || normalized == "proxy-authorization"
                || normalized.contains("api-key")
                || normalized.contains("apikey")
                || normalized.contains("token")
        }
    }

    /// The deterministic OTLP endpoint diagnostic, or `nil` when the configured
    /// endpoints are acceptable. Contains no fault-injection; the simulator
    /// layers its own simulated failures on top of this.
    public var invalidOTLPEndpointMessage: String? {
        guard exporter == "otlp", otlpProtocolIsSupported else { return nil }
        let endpoints = [endpoint, tracesEndpoint, logsEndpoint, metricsEndpoint].compactMap { $0 }
        if otlpProtocolIsGRPC,
           let endpoint = endpoints.first(where: { TelemetryEndpoint.grpcDiagnostic($0) != nil })
        {
            return TelemetryEndpoint.grpcDiagnostic(endpoint)
        }
        if hasSensitiveOTLPHeaders,
           let endpoint = endpoints.first(where: { TelemetryEndpoint.isNonLoopbackCleartext($0) })
        {
            return "OTLP endpoint '\(endpoint)' uses credential headers over cleartext HTTP; use https or a loopback endpoint"
        }
        guard endpoints.contains(where: { !TelemetryEndpoint.isValidHTTP($0) }) else { return nil }
        return "Invalid OTLP endpoint"
    }

    /// Applies `attributeLimits` to a set of attributes, returning the bounded
    /// key/value pairs (sorted for determinism) plus counts of attributes
    /// dropped for exceeding `maxCount` and values truncated for exceeding
    /// `maxValueLength`. Callers translate the bounded `Any` values into their
    /// own attribute representation.
    public func limitedAttributes(_ attributes: [String: Any]) -> TelemetryLimitedAttributes {
        let maxCount = max(attributeLimits["maxCount"] ?? 64, 0)
        let maxValueLength = max(attributeLimits["maxValueLength"] ?? 4096, 0)
        var pairs: [(key: String, value: Any)] = []
        var droppedOverLimit = 0
        var truncated = 0

        for key in attributes.keys.sorted() where !key.isEmpty {
            guard pairs.count < maxCount else {
                droppedOverLimit += 1
                continue
            }
            let bounded = TelemetryEndpoint.boundedAttributeValue(attributes[key]!, maxValueLength: maxValueLength)
            if bounded.truncated {
                truncated += 1
            }
            pairs.append((key, bounded.value))
        }

        return TelemetryLimitedAttributes(pairs: pairs, droppedOverLimit: droppedOverLimit, truncated: truncated)
    }
}

/// Result of applying attribute limits to a set of telemetry attributes.
public struct TelemetryLimitedAttributes {
    public var pairs: [(key: String, value: Any)]
    /// Attributes dropped for exceeding `maxCount`.
    public var droppedOverLimit: Int
    /// String values truncated for exceeding `maxValueLength`.
    public var truncated: Int

    /// Total attribute-level drops (over-limit attributes plus truncated values).
    public var totalDropped: Int { droppedOverLimit + truncated }
}

/// Pure endpoint-shape helpers shared across telemetry implementations.
public enum TelemetryEndpoint {
    public static func isNonLoopbackCleartext(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint),
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased()
        else { return false }
        return !(host == "localhost" || host == "::1" || host.hasPrefix("127."))
    }

    public static func isValidHTTP(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            return false
        }
        return true
    }

    /// Returns a diagnostic string for a gRPC endpoint, or `nil` when valid.
    /// gRPC endpoints are host/port service addresses and must not carry a
    /// path, query, or fragment (gRPC does not use `/v1/*` URL paths).
    public static func grpcDiagnostic(_ endpoint: String) -> String? {
        guard let url = URL(string: endpoint),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else {
            return "Invalid OTLP gRPC endpoint '\(endpoint)'; expected http or https URL with host and optional port"
        }
        if (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil {
            return nil
        }
        return "Invalid OTLP gRPC endpoint '\(endpoint)'; endpoint must not include a path, query, or fragment"
    }

    /// Bounds a single attribute value to `maxValueLength`. Numeric and boolean
    /// values pass through unchanged; strings (and other stringified values) are
    /// truncated. Returns the bounded value and whether truncation occurred.
    public static func boundedAttributeValue(_ value: Any, maxValueLength: Int) -> (value: Any, truncated: Bool) {
        switch value {
        case let value as String:
            guard value.count > maxValueLength else { return (value, false) }
            return (String(value.prefix(maxValueLength)), true)
        case is Bool, is Int, is Int32, is Int64, is UInt, is UInt32, is UInt64, is Double, is Float, is NSNumber:
            return (value, false)
        default:
            let stringValue = String(describing: value)
            guard stringValue.count > maxValueLength else { return (stringValue, false) }
            return (String(stringValue.prefix(maxValueLength)), true)
        }
    }
}
