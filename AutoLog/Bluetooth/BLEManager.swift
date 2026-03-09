import Foundation
import CoreBluetooth
import Combine

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

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var reconnectTimer: Timer?
    private var dataBuffer = Data()

    private var dataContinuation: AsyncStream<Data>.Continuation?
    private(set) var dataStream: AsyncStream<Data>!

    // Common ELM327/OBD adapter BLE names
    private let knownNames = [
        "Vgate", "iCar", "ELM327", "OBD", "OBDII", "OBD2",
        "V-LINK", "Vlink", "IOS-Vlink", "VEEPEAK", "LELink",
        "Carista", "Konnwei", "Elm", "AutoScan", "Scan Tool", "BT-OBD"
    ]

    // Common ELM327 service/characteristic UUIDs across adapters
    private let knownServiceUUIDs = [
        CBUUID(string: "FFF0"),           // Vgate, many Chinese adapters
        CBUUID(string: "FFE0"),           // Some ELM327 clones
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"), // LELink
        CBUUID(string: "18F0"),           // Some OBD adapters
        CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB"), // Full FFF0
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
    }

    func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        if let peripheral = peripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectionState = .disconnected
        Log.ble("disconnected")
    }

    func send(_ command: String) {
        guard let characteristic = writeCharacteristic,
              let peripheral = peripheral,
              let data = "\(command)\r".data(using: .ascii) else { return }
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: writeType)
        Log.obd("sending: \(command)")
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: Config.bleReconnectInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.startScanning()
            }
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn {
                Log.ble("Bluetooth powered on")
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
            centralManager.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            Log.ble("connected to \(peripheral.name ?? "device")")
            connectionState = .connected
            // Discover all services — different adapters use different UUIDs
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            Log.ble("disconnected: \(error?.localizedDescription ?? "clean")")
            connectionState = .disconnected
            self.peripheral = nil
            writeCharacteristic = nil
            notifyCharacteristic = nil
            setupDataStream()
            scheduleReconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            Log.ble("failed to connect: \(error?.localizedDescription ?? "unknown")")
            connectionState = .disconnected
            scheduleReconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            Task { @MainActor in
                self.peripheral = restored
                restored.delegate = self
                Log.ble("restored peripheral")
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
        // Try known service UUIDs first, then discover characteristics on all services
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            let chars = service.characteristics ?? []
            Log.ble("service \(service.uuid): \(chars.map { "\($0.uuid)(\($0.properties.rawValue))" })")

            for char in chars {
                // Match write characteristic: known UUID or has .write/.writeWithoutResponse property
                if writeCharacteristic == nil {
                    if knownWriteUUIDs.contains(char.uuid) ||
                       (char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse)) &&
                       knownServiceUUIDs.contains(service.uuid) {
                        writeCharacteristic = char
                        Log.ble("using write characteristic: \(char.uuid)")
                    }
                }

                // Match notify characteristic: known UUID or has .notify property
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
