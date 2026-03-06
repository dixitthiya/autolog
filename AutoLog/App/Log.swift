import Foundation
import os

struct Log {
    private static let logger = Logger(subsystem: "com.autolog.app", category: "general")

    static func ble(_ message: String) {
        logger.info("[BLE] \(message)")
    }

    static func obd(_ message: String) {
        logger.info("[OBD] \(message)")
    }

    static func db(_ message: String) {
        logger.info("[DB] \(message)")
    }

    static func sync(_ message: String) {
        logger.info("[SYNC] \(message)")
    }

    static func notify(_ message: String) {
        logger.info("[NOTIFY] \(message)")
    }

    static func csv(_ message: String) {
        logger.info("[CSV] \(message)")
    }
}
