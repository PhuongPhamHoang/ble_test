import SwiftUI
import Combine
import CoreBluetooth

// MARK: - BLE Constants
struct BLEConstants {
    static let serviceUUID = CBUUID(string: "FFE0")
    static let fileControlCharUUID = CBUUID(string: "FFE6")
    static let fileInfoCharUUID = CBUUID(string: "FFE7")
    static let fileDataCharUUID = CBUUID(string: "FFE8")
    static let fileAckCharUUID = CBUUID(string: "FFE9")
    static let fileErrCharUUID = CBUUID(string: "FFEA")
}

// MARK: - File Command Codes
enum FileCommand: UInt8 {
    case startTransfer = 0x01
    case abortTransfer = 0x02
    case continueTransfer = 0x03
    case requestChunk = 0x06
    case chunkReceived = 0x07
    case complete = 0x08
}

// MARK: - File Transfer State
enum TransferState: Equatable {
    case idle
    case connecting
    case preparing
    case transferring
    case saving
    case complete
    case error(String)
    
    var errorMessage: String? {
        if case .error(let message) = self {
            return message
        }
        return nil
    }
}

// MARK: - BLE File Transfer Manager
class BLEFileTransferManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var state: TransferState = .idle
    @Published var connectedDevice: CBPeripheral?
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var progress: Double = 0.0
    @Published var fileName: String = "received_file.txt"
    @Published var fileSize: Int = 0
    @Published var currentChunk: Int = 0
    @Published var totalChunks: Int = 0
    @Published var errorMessage: String = ""
    @Published var transferCompletedFiles: [URL] = []
    
    // MARK: - Private Properties
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var fileControlCharacteristic: CBCharacteristic?
    private var fileInfoCharacteristic: CBCharacteristic?
    private var fileDataCharacteristic: CBCharacteristic?
    private var fileAcknowledgmentCharacteristic: CBCharacteristic?
    private var fileErrorCharacteristic: CBCharacteristic?
    
    private var completionHandler: ((URL?, Error?) -> Void)?
    
    private var fileData = Data()
    private var transferState: UInt8 = 0 // 0: IDLE, 1: IN_PROGRESS
    private var chunkSize: Int = 20
    
    // MARK: - Initialization
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Public Methods
    func startScanning() {
        if centralManager.state == .poweredOn {
            discoveredDevices = []
            centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            state = .connecting
        } else {
            state = .error("Bluetooth is not powered on")
        }
    }
    
    func stopScanning() {
        centralManager.stopScan()
    }
    
    func connect(to peripheral: CBPeripheral) {
        self.peripheral = peripheral
        centralManager.connect(peripheral, options: nil)
    }
    
    func disconnect() {
        guard let peripheral = peripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
        self.state = .idle
    }
    
    func startTransfer() {
        guard let characteristic = fileControlCharacteristic else {
            state = .error("File control characteristic not found")
            return
        }
        
        // Reset transfer state
        fileData = Data()
        currentChunk = 0
        transferState = 1
        state = .preparing
        
        
        let commandData = Data([FileCommand.startTransfer.rawValue, 0])
        peripheral!.writeValue(commandData, for: fileControlCharacteristic!, type: .withResponse)
        print("Starting file transfer...")
        
        if let infoCharacteristic = fileInfoCharacteristic {
            peripheral!.readValue(for: infoCharacteristic)
        }
    }
    
    func requestChunk(_ chunkNum: UInt8) {
        guard let characteristic = fileControlCharacteristic else {
            state = .error("File control characteristic not found")
            return
        }
        
        if let peripheral {
            let requestCommand = Data([FileCommand.requestChunk.rawValue, chunkNum])
            peripheral.writeValue(requestCommand, for: characteristic, type: .withResponse)
        }
    }
    
    func saveFile() -> URL? {
        state = .saving
        
        let dataFinal = String(data: fileData, encoding: .utf8)
        print("==> FInal: \(dataFinal)")
        
        return nil
    }
    
    // Helper method to check if all characteristics are available
    func isReadyForTransfer() -> Bool {
        return fileControlCharacteristic != nil &&
               fileInfoCharacteristic != nil &&
               fileDataCharacteristic != nil &&
               fileAcknowledgmentCharacteristic != nil
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEFileTransferManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth is powered on")
        case .poweredOff:
            state = .error("Bluetooth is powered off")
        case .resetting:
            state = .error("Bluetooth is resetting")
        case .unauthorized:
            state = .error("Bluetooth is unauthorized")
        case .unsupported:
            state = .error("Bluetooth is not supported")
        case .unknown:
            state = .error("Bluetooth state is unknown")
        @unknown default:
            state = .error("Unknown Bluetooth state")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard let name = peripheral.name, name.starts(with: "TD") else { return }
        
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            DispatchQueue.main.async {
                self.discoveredDevices.append(peripheral)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedDevice = peripheral
        connectedDevice?.delegate = self
        connectedDevice?.discoverServices([BLEConstants.serviceUUID])
        print("Connected to \(peripheral.name ?? "unknown device")")
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .error("Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedDevice = nil
        state = .idle
        print("Disconnected from \(peripheral.name ?? "unknown device")")
    }
}

// MARK: - CBPeripheralDelegate
extension BLEFileTransferManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            state = .error("Error discovering services: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else { return }
        
        for service in services {
            print("==> didDiscoverServices \(service)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            state = .error("Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            switch characteristic.uuid {
            case BLEConstants.fileControlCharUUID:
                fileControlCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                print("==> fileControlCharUUID detected: \(characteristic)")
                
            case BLEConstants.fileInfoCharUUID:
                print("fileInfoCharUUID detected: \(characteristic)")
                fileInfoCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                
            case BLEConstants.fileDataCharUUID:
                print("fileDataCharUUID detected: \(characteristic)")
                fileDataCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                
            case BLEConstants.fileAckCharUUID:
                print("fileAckCharUUID detected: \(characteristic)")
                fileAcknowledgmentCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                
            case BLEConstants.fileErrCharUUID:
                print("fileErrCharUUID detected: \(characteristic)")
                fileErrorCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                
            default:
                break
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            state = .error("Error reading characteristic value: \(error.localizedDescription)")
            return
        }
        
        if characteristic.uuid == BLEConstants.fileControlCharUUID {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        
        print("==> didUpdateValueFor : \(characteristic)")
        
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case BLEConstants.fileInfoCharUUID:
            print("==> fileInfoCharUUID: \(characteristic)")
            processFileInfo(data)
            
        case BLEConstants.fileDataCharUUID:
            print("==> fileDataCharUUID: \(characteristic)")
            processChunkData(data)
            
        case BLEConstants.fileErrCharUUID:
            print("==> didUpdateValueFor fileErrCharUUID: \(characteristic)")
            print("Error received: \(data.hex)")
            
        default:
            break
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        print("== > didWriteValueFor called for \(characteristic.uuid)")
        
        if let error = error {
            state = .error("Error writing value: \(error.localizedDescription)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        print("didUpdateNotificationStateFor \(characteristic) - value: \(String(describing: characteristic.value))")
    }
    
    private func processFileInfo(_ data: Data) {
        guard data.count > 1 else {
            print("Invalid file info data")
            return
        }
        
        let nameLength = Int(data[0])
        guard data.count >= nameLength + 5 else {
            print("Invalid file info format")
            return
        }
        
        // Extract file name
        if let nameData = data.subdata(in: 1..<(nameLength+1)).string {
            fileName = nameData.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        
        // Extract file size (4 bytes, little-endian)
        let fileSizeData = data.subdata(in: (nameLength+1)..<(nameLength+5))
        fileSize = Int(UInt32(littleEndian: fileSizeData.withUnsafeBytes { $0.load(as: UInt32.self) }))
        
        // Calculate total chunks
        totalChunks = Int((fileSize + 19) / 20)  // Chunk size is 20 bytes
        
        print("==> File info received: \(fileName), \(fileSize) bytes, \(totalChunks) chunks")
        
        // Start requesting chunks
        currentChunk = 0
        requestNextChunk()
    }
    
    private func requestNextChunk() {
        guard currentChunk < totalChunks else {
            completeTransfer()
            return
        }
        
        requestChunk(UInt8(currentChunk))
    }
    
    private func completeTransfer() {
        state = .complete
        print("Transfer completed")
        
        // Save file
        do {
            let fileURL = saveFile()
            print("File saved to \(String(describing: fileURL?.path))")
            completionHandler?(fileURL, nil)
        } catch {
            print("Error saving file: \(error.localizedDescription)")
            completionHandler?(nil, error)
        }
    }
    
    private func processChunkData(_ data: Data) {
        // Append chunk data to file data
        fileData.append(data)
        print("==>Received chunk \(currentChunk): \(data.count) bytes")
        print("current chunk: \(currentChunk) - totals: \(totalChunks)")
        
        // Send chunk acknowledgement
        if let ackCharacteristic = fileAcknowledgmentCharacteristic, let peripheral = peripheral {
            let ackData = Data([FileCommand.chunkReceived.rawValue, UInt8(currentChunk)])
            peripheral.writeValue(ackData, for: ackCharacteristic, type: .withResponse)
            peripheral.readValue(for: fileDataCharacteristic!)
        }
        
        // Check if transfer is complete
        if currentChunk + 1 >= totalChunks {
            completeTransfer()
        } else {
            currentChunk += 1
            requestNextChunk()
        }
    }
}

// MARK: - Views
struct ContentView: View {
    @StateObject private var bleManager = BLEFileTransferManager()
    @State private var showingBLEDevicesSheet = false
    @State private var showingFilePickerSheet = false
    @State private var selectedFileURL: URL?
    
    var body: some View {
        NavigationView {
            VStack {
                // BLE Connection Status
                Group {
                    HStack {
                        Image(systemName: bleManager.connectedDevice != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(bleManager.connectedDevice != nil ? .green : .red)
                        Text(bleManager.connectedDevice != nil ? "Connected to: \(bleManager.connectedDevice?.name ?? "")" : "Not Connected")
                        Spacer()
                        if bleManager.connectedDevice != nil {
                            Button("Disconnect") {
                                bleManager.disconnect()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Connect") {
                                bleManager.startScanning()
                                showingBLEDevicesSheet = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                }
                
                Divider()
                
                // Transfer Status
                Group {
                    if bleManager.state == .transferring {
                        VStack(spacing: 10) {
                            ProgressView(value: bleManager.progress)
                                .padding(.horizontal)
                            
                            Text("Transferring: \(bleManager.fileName)")
                                .font(.headline)
                            
                            Text("\(Int(bleManager.progress * 100))% - Chunk \(bleManager.currentChunk)/\(bleManager.totalChunks)")
                                .font(.subheadline)
                        }
                        .padding()
                    } else if bleManager.state == .complete {
                        VStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.largeTitle)
                            
                            Text("Transfer Complete!")
                                .font(.headline)
                                .padding(.top, 5)
                            
                            Text(bleManager.fileName)
                                .font(.subheadline)
                        }
                        .padding()
                    }
                }
                
                Divider()
                
                // Action Buttons
                if bleManager.connectedDevice != nil && bleManager.state != .transferring {
                    Button("Start File Transfer") {
                        bleManager.startTransfer()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bleManager.state == .transferring)
                    .padding()
                }
                
                // Completed Files
                if !bleManager.transferCompletedFiles.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Transferred Files:")
                            .font(.headline)
                            .padding(.bottom, 5)
                        
                        ScrollView {
                            LazyVStack(alignment: .leading) {
                                ForEach(bleManager.transferCompletedFiles, id: \.self) { fileURL in
                                    HStack {
                                        Image(systemName: "doc.fill")
                                            .foregroundColor(.blue)
                                        Text(fileURL.lastPathComponent)
                                        Spacer()
                                    }
                                    .padding(.vertical, 5)
                                }
                            }
                        }
                    }
                    .padding()
                } else {
                    Spacer()
                    Text("No files transferred yet")
                        .foregroundColor(.gray)
                    Spacer()
                }
            }
            .navigationTitle("BLE File Transfer")
            .alert(isPresented: .constant(bleManager.state.errorMessage != nil)) {
                Alert(
                    title: Text("Error"),
                    message: Text(bleManager.state.errorMessage ?? "Unknown error"),
                    dismissButton: .default(Text("OK"))
                )
            }
            .sheet(isPresented: $showingBLEDevicesSheet) {
                BLEDevicesView(
                    devices: bleManager.discoveredDevices,
                    onSelect: { device in
                        bleManager.connect(to: device)
                        showingBLEDevicesSheet = false
                    }
                )
            }
        }
    }
}

struct BLEDevicesView: View {
    let devices: [CBPeripheral]
    let onSelect: (CBPeripheral) -> Void
    
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            List {
                if devices.isEmpty {
                    Text("Scanning for TD devices...")
                } else {
                    ForEach(devices, id: \.identifier) { device in
                        Button(action: {
                            onSelect(device)
                        }) {
                            HStack {
                                Image(systemName: "wave.3.right")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading) {
                                    Text(device.name ?? "Unknown Device")
                                        .font(.headline)
                                    Text(device.identifier.uuidString)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Available BLE Devices")
            .navigationBarItems(trailing: Button("Cancel") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}
