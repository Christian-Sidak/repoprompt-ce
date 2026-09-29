import Logging

/// Process-wide CLI logger.
///
/// Declared outside `main.swift` on purpose: globals in the entry file are initialized by
/// top-level code, which never runs when the module is loaded in-process (XCTest), so transport
/// paths that log would read an uninitialized value. Ordinary-file globals initialize lazily and
/// thread-safely on first access in every host.
let log: Logger = {
    var logger = Logger(label: "com.repoprompt.ce.mcp.cli") {
        StreamLogHandler.standardError(label: $0)
    }
    // Default to warning level - --verbose will enable more output
    logger.logLevel = .warning
    return logger
}()
