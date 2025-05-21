import SwiftUI
import Combine
import CoreBluetooth

// MARK: - BLE Constants
struct BLEConstants {
    static let fileTransferServiceUUID = CBUUID(string: "FFE0")
    static let fileControlCharUUID = CBUUID(string: "FFE6")
    static let fileInfoCharUUID = CBUUID(string: "FFE7")
    static let fileDataCharUUID = CBUUID(string: "FFE8")
    static let fileAckCharUUID = CBUUID(string: "FFE9")
    static let fileErrCharUUID = CBUUID(string: "FFEA")
    
}

// MARK: - File Command Codes
enum FileCommand: UInt8 {
    case startFileTransfer = 0x11
    case getFileList = 0x12
    case deviceControl = 0x05
}

enum AckResponse: UInt8 {
    case failed = 0
    case success = 1
    case invalid = 2
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

enum FileTransferMode {
    case none
    case fileList
    case fileTransfer
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
    @Published var totalChunks: Int = -1
    @Published var errorMessage: String = ""
    @Published var transferCompletedFiles: [URL] = []
    
    @State var isEnabledButton: Bool = false
    
    // Upload
    @Published var uploadFileName: String?
    @Published var uploadCurrentChunk: Int = 0
    @Published var uploadTotalChunks: Int = 0
    
    // MARK: - Private Properties
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var fileControlChar: CBCharacteristic?
    private var fileInfoChar: CBCharacteristic?
    private var fileDataCharacteristic: CBCharacteristic?
    private var fileAcknowledgmentCharacteristic: CBCharacteristic?
    private var fileErrorCharacteristic: CBCharacteristic?
    
    private var completionHandler: ((URL?, Error?) -> Void)?
    
    private var fileData = Data()
    private var transferState: UInt8 = 0 // 0: IDLE, 1: IN_PROGRESS
    private var chunkSize: Int = 180
    private var fileListDataBuffer = Data()
    private var fileList: [CommandData] = []
    private var fileTransferMode: FileTransferMode = .none
    
    // Upload
    private var uploadFileData: Data?
    
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
        let maxLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        print("Max length: \(maxLength)")
        centralManager.connect(peripheral, options: nil)
    }
    
    func disconnect() {
        guard let peripheral = peripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
        self.state = .idle
    }
    
    func saveFile() -> URL? {
        state = .saving
        
        let dataFinal = String(data: fileData, encoding: .utf8)
        print("==> FInal: \(dataFinal)")
        
        return nil
    }
}

// MARK: - Working
extension BLEFileTransferManager {
    func startFileTransfer() {
        guard let peripheral else {
            state = .error("BLE Not Connected!")
            return
        }
        
        requestFileList()
    }
    
    func requestFileList() {
        fileTransferMode = .fileList
        fileList.removeAll()
        fileListDataBuffer.removeAll()
        commandGetFileList()
    }
    
    func commandGetFileList() {
        guard let peripheral, let fileControlChar else {
            return
        }
        // Get File List: 0x12 - 0x00
        let commandData = Data([0x12, 0x00])
        peripheral.writeValue(commandData, for: fileControlChar, type: .withResponse)
    }
    
    func commandRequestNextFileListChunk() {
        guard let peripheral, let fileControlChar else {
            return
        }
        // Get File List: 0x12 - 0x01
        let commandData = Data([0x12, 0x01])
        peripheral.writeValue(commandData, for: fileControlChar, type: .withResponse)
    }
    
    func commandStartFileTransfer() {
        guard let peripheral, let fileControlChar else {
            return
        }
        // Start File Transfer: 0x11 - 0x00
        let commandData = Data([0x11, 0x00])
        peripheral.writeValue(commandData, for: fileControlChar, type: .withResponse)
    }
    
    func commandRequestNextFileChunk() {
        guard let peripheral, let fileControlChar else {
            return
        }
        // Get File List: 0x11 - 0x01
        let commandData = Data([0x11, 0x01])
        peripheral.writeValue(commandData, for: fileControlChar, type: .withResponse)
    }
    
    func commandReadInfo() {
        guard let peripheral, let fileInfoChar else {
            return
        }
        // Read info at FFE7
        peripheral.readValue(for: fileInfoChar)
    }
    
    func processFileListChunk(_ data: Data) {
        fileListDataBuffer.append(data)
        guard let dataString = fileListDataBuffer.string else {
            return
        }
        print("Current buffer: \(dataString)")
        
        // This marks the end of the file list data array
        if dataString.contains("]}") {
            print("Found complete JSON with closing brackets")
            let completedDataString = dataString.removingNullBytes()
            print("completed Data String: \(completedDataString)")
            
            // parse json
            guard let commandData = parseJSON(jsonString: completedDataString) else { return }
            fileList.append(commandData)
        } else {
            commandRequestNextFileListChunk()
        }
    }
    
    func parseJSON(jsonString: String) -> CommandData? {
        guard let jsonData = jsonString.data(using: .utf8) else {
            print("Failed to convert string to data")
            return nil
        }
        
        do {
            let decoder = JSONDecoder()
            let commandData = try decoder.decode(CommandData.self, from: jsonData)
            return commandData
        } catch {
            print("Error decoding JSON: \(error)")
            return nil
        }
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
        connectedDevice?.discoverServices([BLEConstants.fileTransferServiceUUID])
        
        print("Connected to \(peripheral.name ?? "unknown device")")
        print("Max: \(connectedDevice!.maximumWriteValueLength(for: .withoutResponse)) - \(connectedDevice!.maximumWriteValueLength(for: .withResponse))")
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
                fileControlChar = characteristic
                print("==> fileControlCharUUID detected: \(characteristic)")
                
            case BLEConstants.fileInfoCharUUID:
                print("==> fileInfoCharUUID detected: \(characteristic)")
                fileInfoChar = characteristic
                isEnabledButton = true
                
            case BLEConstants.fileDataCharUUID:
                print("==> fileDataCharUUID detected: \(characteristic)")
                fileDataCharacteristic = characteristic
                
            case BLEConstants.fileAckCharUUID:
                print("==> fileAckCharUUID detected: \(characteristic)")
                fileAcknowledgmentCharacteristic = characteristic
                
            case BLEConstants.fileErrCharUUID:
                print("==> fileErrCharUUID detected: \(characteristic)")
                fileErrorCharacteristic = characteristic
                
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
        
        print("==> [Delegate] didUpdateValueFor : \(characteristic)")
        
        guard let data = characteristic.value else { return }
        
        if let dataStr = data.string {
            print("==> didUpdateValueFor raw data: \(dataStr)")
        }
        
        switch characteristic.uuid {
        case BLEConstants.fileControlCharUUID: // FFE6
            break
            
        case BLEConstants.fileInfoCharUUID: // FFE7
            switch fileTransferMode {
            case .fileList:
                processFileListChunk(data)
                
            default:
                return
            }
            
        case BLEConstants.fileDataCharUUID: // FFE8
            break
            
        case BLEConstants.fileErrCharUUID:
            print("====> error received: \(String(describing: data.string))")
            
        case BLEConstants.fileAckCharUUID:
            print("====> process ack data: \(String(describing: data.string))")
            
        default:
            break
        }
    }
            
            
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        print("==> didWriteValueFor called for \(characteristic.uuid)")
        
        if let error = error {
            state = .error("Error writing value: \(error.localizedDescription)")
        }
        
        if let data = characteristic.value, let dataStr = data.string {
            print("==> [didWriteValueFor] raw data: \(dataStr)")
        }
        
        switch characteristic.uuid {
        case BLEConstants.fileControlCharUUID: // FFE6
            commandReadInfo()
            
        default:
            return
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
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
                        bleManager.startFileTransfer()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bleManager.isEnabledButton)
                    .padding()
                    
                    //                    // Upload file
                    //                    Button("Upload File") {
                    //                        bleManager.startUploadFile()
                    //                    }
                    //                    .buttonStyle(.borderedProminent)
                    //                    .disabled(bleManager.isEnabledButton)
                    //                    .padding()
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

extension String {
    func removingNullBytes() -> String {
        return self.replacingOccurrences(of: "\0", with: "")
    }
}

struct FileData: Codable {
    let name: String
    let size: Int
}

struct CommandData: Codable {
    let category: Int
    let command: Int
    let data: [FileData]
}
