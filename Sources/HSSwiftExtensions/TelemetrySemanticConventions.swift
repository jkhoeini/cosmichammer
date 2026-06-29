enum TelemetrySemanticConventions {
    enum Metric {
        enum Telemetry {
            static let flushDuration = "cosmichammer.telemetry.flush.duration"
            static let flushCount = "cosmichammer.telemetry.flush.count"
            static let activeSpans = "cosmichammer.telemetry.spans.active"
            static let droppedRecords = "cosmichammer.telemetry.records.dropped"
            static let droppedAttributes = "cosmichammer.telemetry.attributes.dropped"
            static let exporterQueueCapacity = "cosmichammer.telemetry.exporter.queue.capacity"
            static let exporterBatchMaxSize = "cosmichammer.telemetry.exporter.batch.max_size"
            static let exporterScheduleDelay = "cosmichammer.telemetry.exporter.schedule.delay"
            static let exporterTimeout = "cosmichammer.telemetry.exporter.timeout"
            static let exporterBackpressureDroppedRecords = "cosmichammer.telemetry.exporter.backpressure.dropped_records"
            static let exporterFailureCount = "cosmichammer.telemetry.exporter.failure.count"
        }
    }

    enum Attribute {
        enum HTTP {
            static let requestMethod = "http.request.method"
            static let responseStatusCode = "http.response.status_code"
        }

        enum URL {
            static let full = "url.full"
            static let path = "url.path"
            static let scheme = "url.scheme"
        }

        enum Server {
            static let address = "server.address"
            static let port = "server.port"
        }

        enum Client {
            static let address = "client.address"
            static let port = "client.port"
        }

        enum Error {
            static let type = "error.type"
        }

        enum Process {
            static let executablePath = "process.executable.path"
            static let argsCount = "process.args_count"
            static let exitCode = "process.exit.code"
            static let workingDirectory = "process.working_directory"
            static let pid = "process.pid"

            static let commandLength = "cosmichammer.process.command.length"
            static let exitType = "cosmichammer.process.exit.type"
            static let shellUserEnv = "cosmichammer.process.shell.user_env"
            static let stream = "cosmichammer.process.stream"
        }

        enum Lua {
            static let callbackName = "cosmichammer.lua.callback.name"
            static let commandLength = "cosmichammer.lua.command.length"
            static let completionPrefixLength = "cosmichammer.lua.completion.prefix.length"
            static let configHasInit = "cosmichammer.lua.config.has_init"
            static let loggerID = "cosmichammer.lua.logger.id"
            static let module = "cosmichammer.lua.module"
            static let setupPath = "cosmichammer.lua.setup.path"
            static let source = "cosmichammer.lua.source"
        }

        enum CLI {
            static let instanceID = "cosmichammer.cli.instance_id"
        }

        enum IPC {
            static let messageID = "cosmichammer.ipc.message_id"
        }

        enum Permission {
            static let enabled = "cosmichammer.permission.enabled"
            static let name = "cosmichammer.permission.name"
            static let prompted = "cosmichammer.permission.prompted"
            static let status = "cosmichammer.permission.status"
        }

        enum UI {
            static let action = "cosmichammer.ui.action"
            static let actionSuccess = "cosmichammer.ui.action.success"
            static let dockDropType = "cosmichammer.ui.dock.drop.type"
            static let system = "cosmichammer.ui.system"
        }

        enum Window {
            static let id = "cosmichammer.window.id"
        }

        enum WebSocket {
            static let messageLength = "cosmichammer.websocket.message.length"
        }

        enum Telemetry {
            static let flushResult = "cosmichammer.telemetry.flush.result"
        }
    }
}
