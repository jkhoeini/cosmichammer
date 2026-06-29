import Foundation

enum OpenTelemetryGoldenFixtures {
    struct TraceparentCase {
        var name: String
        var headerName: String
        var headerValue: String
        var expectedParentSpanID: UInt64
    }

    struct InvalidTraceparentCase {
        var name: String
        var headerValue: String
        var reason: String
    }

    struct BaggageExtractionCase {
        var name: String
        var headerName: String
        var headerValue: String
        var expectedItems: [String: String]
        var rejectedKeys: [String]
    }

    struct BaggageInjectionCase {
        var name: String
        var items: [String: String]
        var expectedHeader: String?
    }

    struct OTLPRequestExpectation {
        var signal: String
        var path: String
        var contentTypePrefix: String
    }

    struct OTLPPayloadExpectation {
        var serviceName: String
        var resourceAttributes: [String: String]
        var parentSpanName: String
        var childSpanName: String
        var spanEventName: String
        var logMessage: String
        var metricName: String
    }

    static let validTraceparentCases: [TraceparentCase] = [
        TraceparentCase(
            name: "sampled W3C example",
            headerName: "traceparent",
            headerValue: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
            expectedParentSpanID: 0x00f067aa0ba902b7
        ),
        TraceparentCase(
            name: "unsampled all-lowercase context",
            headerName: "TraceParent",
            headerValue: "00-00000000000000000000000000000001-0000000000000042-00",
            expectedParentSpanID: 0x42
        ),
        TraceparentCase(
            name: "additional flag bits preserved by parser",
            headerName: "TRACEPARENT",
            headerValue: "00-11111111111111111111111111111111-2222222222222222-03",
            expectedParentSpanID: 0x2222222222222222
        ),
    ]

    static let invalidTraceparentCases: [InvalidTraceparentCase] = [
        InvalidTraceparentCase(
            name: "empty value",
            headerValue: "",
            reason: "traceparent must contain four hyphen-separated fields"
        ),
        InvalidTraceparentCase(
            name: "missing flags",
            headerValue: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7",
            reason: "trace flags are required"
        ),
        InvalidTraceparentCase(
            name: "all-zero trace id",
            headerValue: "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
            reason: "trace id cannot be all zeros"
        ),
        InvalidTraceparentCase(
            name: "all-zero parent id",
            headerValue: "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
            reason: "parent id cannot be all zeros"
        ),
        InvalidTraceparentCase(
            name: "non-hex trace flags",
            headerValue: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-gg",
            reason: "trace flags must be hexadecimal"
        ),
        InvalidTraceparentCase(
            name: "unsupported ff version",
            headerValue: "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
            reason: "version ff is forbidden by W3C Trace Context"
        ),
    ]

    static let currentlyAcceptedInvalidTraceparentCases: [InvalidTraceparentCase] = [
        InvalidTraceparentCase(
            name: "uppercase hex fields",
            headerValue: "00-4BF92F3577B34DA6A3CE929D0E0E4736-00F067AA0BA902B7-01",
            reason: "W3C Trace Context defines trace-id, parent-id, and trace-flags as lowercase hex"
        ),
    ]

    static let baggageExtractionCases: [BaggageExtractionCase] = [
        BaggageExtractionCase(
            name: "simple members",
            headerName: "baggage",
            headerValue: "tenant=blue,user=ada",
            expectedItems: ["tenant": "blue", "user": "ada"],
            rejectedKeys: []
        ),
        BaggageExtractionCase(
            name: "case-insensitive header with metadata",
            headerName: "BaGgAgE",
            headerValue: "tenant=blue;ttl=60, user=ada",
            expectedItems: ["tenant": "blue", "user": "ada"],
            rejectedKeys: []
        ),
        BaggageExtractionCase(
            name: "percent-encoded values",
            headerName: "baggage",
            headerValue: "comma=hello%2Cworld,semi=a%3Bb,space=hello%20world,percent=100%25,line=hello%0Aworld",
            expectedItems: [
                "comma": "hello,world",
                "semi": "a;b",
                "space": "hello world",
                "percent": "100%",
                "line": "hello\nworld",
            ],
            rejectedKeys: []
        ),
        BaggageExtractionCase(
            name: "duplicate keys use last member",
            headerName: "baggage",
            headerValue: "tenant=blue,user=ada,tenant=green",
            expectedItems: ["tenant": "green", "user": "ada"],
            rejectedKeys: []
        ),
        BaggageExtractionCase(
            name: "malformed percent escapes preserve raw value",
            headerName: "baggage",
            headerValue: "bad=hello%ZZworld,trailing=abc%,good=ok",
            expectedItems: [
                "bad": "hello%ZZworld",
                "trailing": "abc%",
                "good": "ok",
            ],
            rejectedKeys: []
        ),
        BaggageExtractionCase(
            name: "invalid keys are ignored",
            headerName: "baggage",
            headerValue: "bad@key=ignored,good-key=kept,also_bad=still-kept",
            expectedItems: ["good-key": "kept", "also_bad": "still-kept"],
            rejectedKeys: ["bad@key"]
        ),
    ]

    static let baggageInjectionCases: [BaggageInjectionCase] = [
        BaggageInjectionCase(
            name: "empty baggage removes stale header",
            items: [:],
            expectedHeader: nil
        ),
        BaggageInjectionCase(
            name: "members are sorted for deterministic output",
            items: ["user": "ada", "tenant": "blue"],
            expectedHeader: "tenant=blue,user=ada"
        ),
        BaggageInjectionCase(
            name: "reserved value bytes are percent encoded",
            items: [
                "comma": "hello,world",
                "line": "hello\nworld",
                "percent": "100%",
                "semi": "a;b",
                "space": "hello world",
            ],
            expectedHeader: "comma=hello%2Cworld,line=hello%0Aworld,percent=100%25,semi=a%3Bb,space=hello%20world"
        ),
    ]

    static let otlpHTTPRequests: [OTLPRequestExpectation] = [
        OTLPRequestExpectation(signal: "traces", path: "/v1/traces", contentTypePrefix: "application/x-protobuf"),
        OTLPRequestExpectation(signal: "logs", path: "/v1/logs", contentTypePrefix: "application/x-protobuf"),
        OTLPRequestExpectation(signal: "metrics", path: "/v1/metrics", contentTypePrefix: "application/x-protobuf"),
    ]

    static let otlpPayload = OTLPPayloadExpectation(
        serviceName: "cosmichammer-otlp-loopback",
        resourceAttributes: [
            "test.transport": "http/protobuf",
            "test.receiver": "loopback",
        ],
        parentSpanName: "otlp.loopback.parent",
        childSpanName: "otlp.loopback.child",
        spanEventName: "loopback-event",
        logMessage: "otlp.loopback.log",
        metricName: "otlp.loopback.metric"
    )
}
