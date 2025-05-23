import SwiftUI
import Combine
import CoreBluetooth

// MARK: - BLE Constants
struct BLEConstants {
    static let fileTransferServiceUUID = CBUUID(string: "FFE0")
    static let batteryServiceUUID = CBUUID(string: "180F")
    
    static let fileControlCharUUID = CBUUID(string: "FFE6")
    static let fileInfoCharUUID = CBUUID(string: "FFE7")
    static let fileDataCharUUID = CBUUID(string: "FFE8")
    static let fileAckCharUUID = CBUUID(string: "FFE9")
    static let fileErrCharUUID = CBUUID(string: "FFEA")
    
    static let deviceControlCharUUID = CBUUID(string: "FFEB")
    static let batteryLevelCharUUID = CBUUID(string: "2A19")
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

enum DeviceControlMode {
    case none
    case readStatus
    case putToSleep
    case wakeUp
    case shutdown
    case turnOnWiFi
    case turnOffWifi
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
    private var fileDataChar: CBCharacteristic?
    private var fileAcknowledgmentCharacteristic: CBCharacteristic?
    private var fileErrorCharacteristic: CBCharacteristic?
    private var deviceControlChar: CBCharacteristic?
    private var batteryLevelChar: CBCharacteristic?
    
    private var completionHandler: ((URL?, Error?) -> Void)?
    
    private var fileData = Data()
    private var transferState: UInt8 = 0 // 0: IDLE, 1: IN_PROGRESS
    private var chunkSize: Int = 180
    private var fileListDataBuffer = Data()
    private var fileList: [CommandData] = []
    private var fileTransferMode: FileTransferMode = .none
    private var deviceControlMode: DeviceControlMode = .none
    
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
        
//        requestFileList()
        commandWriteFileName(fileName: "test.txt")
        //        commandReadDeviceStatus()
        //        commandPutDeviceSleep()
        //        commandWakeUpDevice()
        //        commandShutdownDevice()
        //        commandTurnOnWiFiDevice()
//        commandReadBatteryLevel()
        
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
        guard let peripheral, let fileControlChar, let fileDataChar else {
            return
        }
        // Start File Transfer: 0x11 - 0x00
        let commandData = Data([0x11, 0x00])
        peripheral.writeValue(commandData, for: fileControlChar, type: .withResponse)
        
        // Then read the data on E8
        peripheral.readValue(for: fileDataChar)
    }
    
    func commandRequestNextFileChunk() {
        guard let peripheral, let fileControlChar, let fileDataChar else {
            return
        }
        // Get File List: 0x11 - 0x01
        let commandData = Data([0x11, 0x01])
        peripheral.writeValue(commandData, for: fileControlChar, type: .withResponse)
        peripheral.readValue(for: fileDataChar)
    }
    
    func commandReadInfo() {
        guard let peripheral, let fileInfoChar else {
            return
        }
        // Read info at FFE7
        peripheral.readValue(for: fileInfoChar)
    }
    
    func commandReadDeviceStatus() {
        /* Purpose: check TDMouse live or not.
          - For success command: `1`
          - For unsuccess command: `0`
          - Invalid command: `2`
         */
        guard let peripheral, let deviceControlChar else {
            return
        }
        
        deviceControlMode = .readStatus
        
        // Read TDMouse Status
        let commandData = Data([0x01])
        peripheral.writeValue(
            commandData,
            for: deviceControlChar,
            type: .withResponse
        )
        peripheral.readValue(for: deviceControlChar)
    }
    
    func commandPutDeviceSleep() {
        /*
         - For success command: `1`
         - For unsuccess command: `0`
         - Invalid command: `2`
         */
        guard let peripheral, let deviceControlChar else {
            return
        }
        
        deviceControlMode = .putToSleep
        
        // Put TDMouse Sleep
        let commandData = Data([0x02])
        peripheral.writeValue(
            commandData,
            for: deviceControlChar,
            type: .withResponse
        )
        peripheral.readValue(for: deviceControlChar)
    }
    
    func commandWakeUpDevice() {
        /*
         - For success command: `1`
         - For unsuccess command: `0`
         - Invalid command: `2`
         */
        guard let peripheral, let deviceControlChar else {
            return
        }
        
        deviceControlMode = .wakeUp
        
        // Put TDMouse Sleep
        let commandData = Data([0x03])
        peripheral.writeValue(
            commandData,
            for: deviceControlChar,
            type: .withResponse
        )
        peripheral.readValue(for: deviceControlChar)
    }
    
    func commandShutdownDevice() {
        /*
         - For success command: `1`
         - For unsuccess command: `0`
         - Invalid command: `2`
         */
        guard let peripheral, let deviceControlChar else {
            return
        }
        
        deviceControlMode = .shutdown
        
        // Put TDMouse Sleep
        let commandData = Data([0x04])
        peripheral.writeValue(
            commandData,
            for: deviceControlChar,
            type: .withResponse
        )
        peripheral.readValue(for: deviceControlChar)
    }
    
    func commandTurnOnWiFiDevice() {
        /*
         - For success command: `1`
         - For unsuccess command: `0`
         - Invalid command: `2`
         */
        guard let peripheral, let deviceControlChar else {
            return
        }
        
        deviceControlMode = .turnOnWiFi
        
        // Put TDMouse Sleep
        let commandData = Data([0x05])
        peripheral.writeValue(
            commandData,
            for: deviceControlChar,
            type: .withResponse
        )
        peripheral.readValue(for: deviceControlChar)
    }
    
    func commandTurnOffWiFiDevice() {
        /*
         - For success command: `1`
         - For unsuccess command: `0`
         - Invalid command: `2`
         */
        guard let peripheral, let deviceControlChar else {
            return
        }
        
        deviceControlMode = .turnOffWifi
        
        // Put TDMouse Sleep
        let commandData = Data([0x06])
        peripheral.writeValue(
            commandData,
            for: deviceControlChar,
            type: .withResponse
        )
        peripheral.readValue(for: deviceControlChar)
    }
    
    func commandReadBatteryLevel() {
        guard let peripheral, let batteryLevelChar else {
            return
        }
        
        peripheral.readValue(for: batteryLevelChar)
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
            guard let commandData = parseCommandDataJSON(jsonString: completedDataString) else { return }
            fileList.append(commandData)
        } else {
            commandRequestNextFileListChunk()
        }
    }
    
    func parseCommandDataJSON(jsonString: String) -> CommandData? {
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
    
    func commandWriteFileName(fileName: String) {
        guard let peripheral, let fileInfoChar else { return }
        
        fileTransferMode = .fileTransfer
        fileData.removeAll()
        
        // Note: file_path + file_name, if file is at home, only need file_name
        guard let jsonData = fileName.data(using: .utf8) else { return }
        
        peripheral.writeValue(
            jsonData,
            for: fileInfoChar,
            type: .withResponse
        )
        
        // start file tranfer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
            self.commandStartFileTransfer()
        })
    }
    
    func processFileDataChunk(_ data: Data) {
        fileData.append(data)
        guard let dataString = fileData.string else {
            return
        }
        print("Current buffer: \(dataString)")
        
        // This marks the end of the file list data array
        if dataString.contains("}}") {
            print("Found complete JSON with closing brackets")
            let completedDataString = dataString.removingNullBytes()
            print("completed Data String: \(completedDataString)")
            
            // parse json
            guard let commandData = parseFileDownloadDataJSON(jsonString: completedDataString) else { return }
            print("parsed json: \(commandData)")
            // We got file data here (commandData) --> complete file download flow
            // TODO: Phuong please help the flow write to local
        } else {
            commandRequestNextFileChunk()
        }
    }
    
    func parseFileDownloadDataJSON(jsonString: String) -> FileDownloadData? {
        guard let jsonData = jsonString.data(using: .utf8) else {
            print("Failed to convert string to data")
            return nil
        }
        
        do {
            let decoder = JSONDecoder()
            let commandData = try decoder.decode(FileDownloadData.self, from: jsonData)
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
        connectedDevice?.discoverServices([
            BLEConstants.fileTransferServiceUUID,
            BLEConstants.batteryServiceUUID
        ])
        
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
                fileDataChar = characteristic
                
            case BLEConstants.fileAckCharUUID:
                print("==> fileAckCharUUID detected: \(characteristic)")
                fileAcknowledgmentCharacteristic = characteristic
                
            case BLEConstants.fileErrCharUUID:
                print("==> fileErrCharUUID detected: \(characteristic)")
                fileErrorCharacteristic = characteristic
                
            case BLEConstants.deviceControlCharUUID:
                print("==> deviceControlCharUUID detected: \(characteristic)")
                deviceControlChar = characteristic
                
            case BLEConstants.batteryLevelCharUUID:
                print("==> batteryLevelCharUUID detected: \(characteristic)")
                batteryLevelChar = characteristic
                
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
        
        if let data = characteristic.value {
            if let dataStr = data.string {
                print("==> didUpdateValueFor raw data: \(dataStr)")
            }
        }
        
        switch characteristic.uuid {
        case BLEConstants.fileControlCharUUID: // FFE6
            break
            
        case BLEConstants.fileInfoCharUUID: // FFE7
            guard let data = characteristic.value else { return }
            
            switch fileTransferMode {
            case .fileList:
                processFileListChunk(data)
//            case .fileTransfer:
//                command
                
            default:
                return
            }
            
        case BLEConstants.fileDataCharUUID: // FFE8
            // App writes file name want to upload TDMouse
            guard let data = characteristic.value else { return  }
            processFileDataChunk(data)
            
        case BLEConstants.fileErrCharUUID:
            break
            
        case BLEConstants.fileAckCharUUID:
            break
            
        case BLEConstants.deviceControlCharUUID: // FFEB
            guard let data = characteristic.value, let dataInt = data.string?.unicodeValue else { return }
            
            var status = ""
            switch dataInt {
            case 1:
                status = "Success"
            case 2:
                status = "Invalid"
            default:
                status = "Failed"
            }
            
            switch deviceControlMode {
            case .readStatus:
                print("Device status: \(status)")
            case .putToSleep:
                print("Put device sleep: \(status)")
            case .wakeUp:
                print("Wake up device: \(status)")
            case .shutdown:
                print("Shutdown device: \(status)")
            case .turnOnWiFi:
                print("Turn on Wifi device: \(status)")
            case .turnOffWifi:
                print("Turn off Wifi device: \(status)")
            default:
                return
            }
            
        case BLEConstants.batteryLevelCharUUID: // 2A19
            guard let data = characteristic.value, let dataInt = data.string?.unicodeValue else { return }
            print("Battery level: \(dataInt)%")
            
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
    
    /// Converts a hex string like "01" or "14" to its corresponding control character
    static func controlCharacterFromHex(_ hexString: String) -> String? {
        guard let value = Int(hexString, radix: 16) else { return nil }
        guard let unicodeScalar = UnicodeScalar(value) else { return nil }
        return String(unicodeScalar)
    }
    
    /// Returns the decimal value of the first character in the string
    var unicodeValue: UInt32? {
        return first?.unicodeValue
    }
    
    /// Returns the hex representation of the first character
    var hexValue: String? {
        guard let value = unicodeValue else { return nil }
        return String(format: "%02X", value)
    }
    
    /// Checks if this string contains any control characters (0x00-0x1F)
    var containsControlCharacters: Bool {
        return unicodeScalars.contains { $0.value < 32 }
    }
    
    /// Removes all control characters from the string
    var removingControlCharacters: String {
        return String(unicodeScalars.filter { $0.value >= 32 || $0 == "\t" || $0 == "\n" || $0 == "\r" })
    }
    
    /// Splits string by a specific control character
    func splitByControlCharacter(_ hexValue: String) -> [String] {
        guard let separator = String.controlCharacterFromHex(hexValue) else { return [self] }
        return self.components(separatedBy: separator)
    }
    
    /// Escapes control characters for display purposes
    var escapingControlCharacters: String {
        return unicodeScalars.map {
            if $0.value < 32 {
                return "\\u{\(String(format: "%X", $0.value))}"
            } else {
                return String($0)
            }
        }.joined()
    }
    
    /// Join array with a control character as separator
    static func join(_ array: [String], withControlCharHex hex: String) -> String? {
        guard let separator = controlCharacterFromHex(hex) else { return nil }
        return array.joined(separator: separator)
    }
}

extension Character {
    /// Returns the Unicode scalar value of the character
    var unicodeValue: UInt32? {
        return unicodeScalars.first?.value
    }
    
    /// Checks if this character is a control character (0x00-0x1F)
    var isControlCharacter: Bool {
        guard let value = unicodeValue else { return false }
        return value < 32
    }
    
    /// Returns the hex representation of this character
    var hexString: String? {
        guard let value = unicodeValue else { return nil }
        return String(format: "%02X", value)
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

struct FileUploadData: Codable {
    let path: String
}

struct FileDownloadData: Codable {
    let category: Int
    let command: Int
    let data: FileDownloadItemData
}

struct FileDownloadItemData: Codable {
    let content: String
}
