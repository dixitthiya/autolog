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

    private let targetName = "Vgate iCar Pro"
    private let serviceUUID = CBUUID(string: "FFF0")
    private let writeUUID = CBUUID(string: "FFF2")
    private let notifyUUID = CBUUID(string: "FFF1")

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
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
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
        guard let name = peripheral.name, name.contains(targetName) else { return }
        Task { @MainActor in
            Log.ble("found \(name)")
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
            peripheral.discoverServices([serviceUUID])
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
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else { return }
        peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for char in service.characteristics ?? [] {
                if char.uuid == writeUUID {
                    writeCharacteristic = char
                } else if char.uuid == notifyUUID {
                    notifyCharacteristic = char
                    peripheral.setNotifyValue(true, for: char)
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
