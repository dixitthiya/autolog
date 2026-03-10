import Foundation
import CoreBluetooth
import Combine
import UIKit

enum BLEConnectionState: String {
    case disconnected
    case scanning
    case connecting
    case connected
    case ready

    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .scanning: return "Scanning..."
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .ready: return "Ready"
        }
    }

    var icon: String {
        switch self {
        case .disconnected: return "antenna.radiowaves.left.and.right.slash"
        case .scanning: return "antenna.radiowaves.left.and.right"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .connected, .ready: return "checkmark.circle.fill"
        }
    }
}

@MainActor
class BLEManager: NSObject, ObservableObject {
    static let shared = BLEManager()

    @Published var connectionState: BLEConnectionState = .disconnected
    @Published var lastError: String?
    @Published var autoModeEnabled = true

    /// Tracks what triggered the current connection for snapshot categorization
    var captureMode: String = "bg_auto"

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var autoScanTask: Task<Void, Never>?
    private var dataBuffer = Data()
    private var wasDisconnectedByOtherApp = false
    private var isIntentionalDisconnect = false

    // Persist last known adapter UUID for direct reconnection
    private let savedPeripheralKey = "com.autolog.lastPeripheralUUID"

    private var dataContinuation: AsyncStream<Data>.Continuation?
    private(set) var dataStream: AsyncStream<Data>!

    // Auto-scan interval: 2 minutes (testing mode — revert to 900 for production)
    private let autoScanInterval: TimeInterval = 120

    // Common ELM327/OBD adapter BLE names
    private let knownNames = [
        "Vgate", "iCar", "ELM327", "OBD", "OBDII", "OBD2",
        "V-LINK", "Vlink", "IOS-Vlink", "VEEPEAK", "LELink",
        "Carista", "Konnwei", "Elm", "AutoScan", "Scan Tool", "BT-OBD"
    ]

    // Common ELM327 service/characteristic UUIDs across adapters
    private let knownServiceUUIDs = [
        CBUUID(string: "FFF0"),
        CBUUID(string: "FFE0"),
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"),
        CBUUID(string: "18F0"),
        CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB"),
    ]
    private let knownWriteUUIDs = [
        CBUUID(string: "FFF2"), CBUUID(string: "FFE1"),
        CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"),
    ]
    private let knownNotifyUUIDs = [
        CBUUID(string: "FFF1"), CBUUID(string: "FFE1"),
        CBUUID(string: "BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F"),
    ]

    override init() {
        super.init()
        setupDataStream()
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.autolog.ble"
        ])
    }

    private func setupDataStream() {
        dataStream = AsyncStream { [weak self] continuation in
            self?.dataContinuation = continuation
        }
    }

    // MARK: - Public API

    /// Start scanning for OBD adapter
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            Log.ble("Bluetooth not powered on")
            return
        }
        guard connectionState == .disconnected else { return }

        connectionState = .scanning
        Log.ble("scanning...")
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        // Stop scanning after 10 seconds to save battery
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if connectionState == .scanning {
                centralManager.stopScan()
                connectionState = .disconnected
                Log.ble("scan timeout, adapter not found")
            }
        }
    }

    /// Disconnect and don't auto-reconnect
    func disconnect() {
        isIntentionalDisconnect = true
        autoScanTask?.cancel()
        autoScanTask = nil
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectionState = .disconnected
        clearPeripheralState()
        Log.ble("disconnected (manual)")
    }

    /// Disconnect after quick read — schedule background-safe reconnect
    func disconnectAfterRead() {
        isIntentionalDisconnect = true
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectionState = .disconnected
        clearPeripheralState()
        Log.ble("disconnected after read")
        startAutoScanLoop()
        // Also schedule a background-safe reconnect using CoreBluetooth
        scheduleBackgroundReconnect()
    }

    /// Disconnect without scheduling immediate reconnect (used during throttle to avoid reconnect loops)
    /// Still restarts the auto-scan loop as a background safety net
    func disconnectQuietly() {
        isIntentionalDisconnect = true
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectionState = .disconnected
        clearPeripheralState()
        Log.ble("disconnected quietly (throttled)")
        startAutoScanLoop()
    }

    func send(_ command: String) {
        guard let characteristic = writeCharacteristic,
              let peripheral = peripheral,
              let data = "\(command)\r".data(using: .ascii) else { return }
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: writeType)
        Log.obd("sending: \(command)")
    }

    // MARK: - Auto Scan

    /// Start the auto-scan cycle — called once on app init
    func startAutoScanCycle() {
        guard autoModeEnabled else { return }
        Log.ble("auto-scan cycle started (every \(Int(autoScanInterval))s)")
        // Try immediately on first launch
        captureMode = "app_launch"
        connectOrScan()
        startAutoScanLoop()
    }

    func startAutoScanLoop() {
        autoScanTask?.cancel()
        guard autoModeEnabled else { return }
        autoScanTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self?.autoScanInterval ?? 120) * 1_000_000_000)
                guard !Task.isCancelled, let self = self else { break }
                if self.connectionState == .disconnected {
                    let isForeground = UIApplication.shared.applicationState == .active
                    self.captureMode = isForeground ? "fg_timer" : "bg_auto"
                    Log.ble("auto-scan triggered (context: \(self.captureMode))")
                    self.connectOrScan()
                } else {
                    Log.ble("auto-scan skipped (state: \(self.connectionState.rawValue))")
                }
            }
        }
    }

    /// Try direct reconnect to saved peripheral first, fall back to scanning
    func connectOrScan() {
        // Try direct reconnect using saved peripheral UUID
        if let uuidString = UserDefaults.standard.string(forKey: savedPeripheralKey),
           let uuid = UUID(uuidString: uuidString) {
            let knownPeripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let saved = knownPeripherals.first {
                Log.ble("reconnecting to saved adapter: \(saved.name ?? uuid.uuidString)")
                self.peripheral = saved
                saved.delegate = self
                connectionState = .connecting
                centralManager.connect(saved, options: nil)

                // Fall back to scan if direct connect doesn't work in 5 seconds
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if connectionState == .connecting {
                        Log.ble("direct reconnect timeout, falling back to scan")
                        centralManager.cancelPeripheralConnection(saved)
                        connectionState = .disconnected
                        clearPeripheralState()
                        startScanning()
                    }
                }
                return
            }
        }
        startScanning()
    }

    /// Use CoreBluetooth's connect API to queue a reconnect — works in background
    /// CB will connect automatically when the peripheral becomes available, even if app is suspended
    func scheduleBackgroundReconnect() {
        guard let uuidString = UserDefaults.standard.string(forKey: savedPeripheralKey),
              let uuid = UUID(uuidString: uuidString) else { return }
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        if let saved = peripherals.first {
            Log.ble("queued background reconnect for \(saved.name ?? uuid.uuidString)")
            saved.delegate = self
            // CB will auto-connect when peripheral is in range — even from background/suspended
            captureMode = "bg_auto"
            centralManager.connect(saved, options: nil)
        }
    }

    private func clearPeripheralState() {
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        setupDataStream()
    }
}

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn {
                Log.ble("Bluetooth powered on")
                if autoModeEnabled && connectionState == .disconnected {
                    let isForeground = UIApplication.shared.applicationState == .active
                    captureMode = isForeground ? "fg_timer" : "bg_auto"
                    startScanning()
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                     advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let upperName = name.uppercased()
        guard !name.isEmpty, knownNames.contains(where: { upperName.contains($0.uppercased()) }) else { return }
        Task { @MainActor in
            Log.ble("found OBD adapter: \(name)")
            self.peripheral = peripheral
            peripheral.delegate = self
            centralManager.stopScan()
            connectionState = .connecting
            // Save UUID for direct reconnection next time
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedPeripheralKey)
            centralManager.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            Log.ble("connected to \(peripheral.name ?? "device")")
            self.peripheral = peripheral
            peripheral.delegate = self
            connectionState = .connected
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let reason = error?.localizedDescription ?? "clean"
            Log.ble("disconnected: \(reason)")
            connectionState = .disconnected
            clearPeripheralState()

            if isIntentionalDisconnect {
                // We disconnected on purpose after a read — background reconnect already queued
                isIntentionalDisconnect = false
                Log.ble("intentional disconnect — background reconnect queued")
            } else if error != nil {
                // Unexpected disconnect (another app took over, out of range, etc.)
                // Queue a CB reconnect — iOS will reconnect when peripheral is available again
                wasDisconnectedByOtherApp = true
                Log.ble("unexpected disconnect — queuing background reconnect")
                scheduleBackgroundReconnect()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            Log.ble("failed to connect: \(error?.localizedDescription ?? "unknown")")
            connectionState = .disconnected
            // Don't retry immediately — wait for next auto-scan
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            Task { @MainActor in
                self.peripheral = restored
                restored.delegate = self
                self.captureMode = "bg_auto"
                Log.ble("restored peripheral from background (state: \(restored.state.rawValue))")
                switch restored.state {
                case .connected:
                    connectionState = .connected
                    restored.discoverServices(nil)
                case .connecting:
                    connectionState = .connecting
                    Log.ble("restored: still connecting...")
                case .disconnected, .disconnecting:
                    connectionState = .disconnected
                    // Re-queue background reconnect
                    scheduleBackgroundReconnect()
                @unknown default:
                    break
                }
            }
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        Task { @MainActor in
            Log.ble("discovered \(services.count) services: \(services.map { $0.uuid.uuidString })")
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            let chars = service.characteristics ?? []
            Log.ble("service \(service.uuid): \(chars.map { "\($0.uuid)(\($0.properties.rawValue))" })")

            for char in chars {
                if writeCharacteristic == nil {
                    if knownWriteUUIDs.contains(char.uuid) ||
                       (char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse)) &&
                       knownServiceUUIDs.contains(service.uuid) {
                        writeCharacteristic = char
                        Log.ble("using write characteristic: \(char.uuid)")
                    }
                }

                if notifyCharacteristic == nil {
                    if knownNotifyUUIDs.contains(char.uuid) ||
                       char.properties.contains(.notify) && knownServiceUUIDs.contains(service.uuid) {
                        notifyCharacteristic = char
                        peripheral.setNotifyValue(true, for: char)
                        Log.ble("using notify characteristic: \(char.uuid)")
                    }
                }
            }

            if writeCharacteristic != nil && notifyCharacteristic != nil {
                connectionState = .ready
                Log.ble("ready - characteristics discovered")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor in
            dataBuffer.append(data)
            if let str = String(data: dataBuffer, encoding: .ascii), str.contains(">") {
                dataContinuation?.yield(dataBuffer)
                dataBuffer = Data()
            }
        }
    }
}
