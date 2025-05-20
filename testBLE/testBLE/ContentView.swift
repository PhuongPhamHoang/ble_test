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
    
    // Upload commands
    case startSendFile = 0x10  // Start send file from app to tdmouse
    case requestChunkFromApp = 0x11  // request chunk file from app to FW
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
    private var fileControlCharacteristic: CBCharacteristic?
    private var fileInfoCharacteristic: CBCharacteristic?
    private var fileDataCharacteristic: CBCharacteristic?
    private var fileAcknowledgmentCharacteristic: CBCharacteristic?
    private var fileErrorCharacteristic: CBCharacteristic?
    
    private var completionHandler: ((URL?, Error?) -> Void)?
    
    private var fileData = Data()
    private var transferState: UInt8 = 0 // 0: IDLE, 1: IN_PROGRESS
    private var chunkSize: Int = 180
    
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
    
    func requestChunk(_ chunkNum: UInt8) {
        guard let peripheral else {
            state = .error("BLE is not connected, please try again!")
            return
        }
        
        guard let fileControlChar = fileControlCharacteristic else {
            state = .error("File control characteristic is not ready, please try again!")
            return
        }
        
        let requestChunkCommand = Data([FileCommand.requestChunk.rawValue, chunkNum]) // 0x06
        peripheral.writeValue(
            requestChunkCommand,
            for: fileControlChar,
            type: .withResponse
        )
        
        print("==> Sent request chunk command")
        
        print("==> Step 5: Read file data")
        guard let fileDataCharacteristic else {
            state = .error("File data characteristic is not ready, please try again!")
            return
        }
        peripheral.readValue(for: fileDataCharacteristic)
    }
    
    func saveFile() -> URL? {
        state = .saving
        
        let dataFinal = String(data: fileData, encoding: .utf8)
        print("==> FInal: \(dataFinal)")
        
        return nil
        
        // save file to local
//        state = .saving
//        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
//            
//        do {
//            try fileData.write(to: fileURL)
//            transferCompletedFiles.append(fileURL)
//            return fileURL
//        } catch {
//            state = .error("Failed to save file: \(error.localizedDescription)")
//            return nil
//        }
    }
    
    // Start upload
    func startUploadFile() {
        // Create a text file
        uploadSelectedFile(sampleText.data(using: .utf8))
    }
    
    // Upload file
    func uploadSelectedFile(_ fileData: Data?) {
        guard let peripheral = self.peripheral else {
            state = .error("BLE Not Connected!")
            print("BLE Not Connected!")
            return
        }
        
        guard let fileData else {
            state = .error("Can not convert sample string to data!")
            print("Can not convert sample string to data")
            return
        }
        
        do {
            // Load file data
            uploadFileData = fileData
            uploadFileName = "sampleText.txt"
            let uploadFileSize = uploadFileData?.count ?? 0
            
            // Calculate chunks
            uploadCurrentChunk = 0
            uploadTotalChunks = Int((uploadFileSize + chunkSize - 1) / chunkSize)
            
            print("==> Starting file upload: \(uploadFileName ?? "unknown"), \(uploadFileSize) bytes, \(uploadTotalChunks) chunks")
            
            // Send start upload command
            guard let fileControlChar = fileControlCharacteristic else {
                state = .error("File control characteristic not found")
                print("File control characteristic not found")
                return
            }
            
            // Reset state for upload
            state = .preparing
            
            // Step 1: Send start upload command (0x10 0x00)
            let startUploadCmd = Data([0x10, 0x00])
            peripheral.writeValue(
                startUploadCmd,
                for: fileControlChar,
                type: .withResponse
            )
            
            print("==> Sent start upload command")
            
            // Step 2: Prepare file metadata
            prepareFileMetadata()
            
        } catch {
            state = .error("Failed to read file: \(error.localizedDescription)")
            print("Failed to read file: \(error.localizedDescription)")
        }
    }
    
    private func prepareFileMetadata() {
        guard let peripheral = self.peripheral,
              let fileInfoChar = fileInfoCharacteristic,
              let fileName = uploadFileName,
              let fileData = uploadFileData else {
            state = .error("Upload preparation failed")
            return
        }
        
        // File info format:
        // byte 0: file name length
        // byte 1-n: file name
        // byte n+1-n+4: file size (4 bytes, little endian)
        var fileInfoData = Data()
        
        let fileNameData = Data(fileName.utf8)
        fileInfoData.append(fileNameData)
        
        // Add file size (4 bytes, little endian)
        var fileSize = UInt32(fileData.count)
        let fileSizeData = withUnsafeBytes(of: &fileSize) { Data($0) }
        fileInfoData.append(fileSizeData)
        
        // Send file metadata
        peripheral.writeValue(
            fileInfoData,
            for: fileInfoChar,
            type: .withResponse
        )
        
        print("==> Sent file metadata: name=\(fileName), size=\(fileData.count)")
        state = .transferring
    }
}

// MARK: - Public Functions
extension BLEFileTransferManager {
    
    func startTransfer() {
        guard let peripheral else {
            state = .error("BLE Not Connected!")
            return
        }
   
//
//        // Reset transfer state
//        fileData = Data()
//        currentChunk = 0
//        state = .preparing
        
        // Step 1: Request start transfer file
        print("==> Step 1: Request start transfer file")
        guard let fileControlTransferChar = fileControlCharacteristic else {
            state = .error("File control characteristic not ready, please retry again!")
            return
        }
        
        let startTransferCmd = Data([FileCommand.startTransfer.rawValue, 0]) // 0x01
        peripheral.writeValue(
            startTransferCmd,
            for: fileControlTransferChar,
            type: .withResponse
        )
        
        print("==> Send request transfer file")
        state = .transferring
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
                fileControlCharacteristic = characteristic
                print("==> fileControlCharUUID detected: \(characteristic)")
                
            case BLEConstants.fileInfoCharUUID:
                print("==> fileInfoCharUUID detected: \(characteristic)")
                fileInfoCharacteristic = characteristic
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

        switch characteristic.uuid {
        case BLEConstants.fileControlCharUUID: // FFE6
            if state == .transferring && totalChunks == -1 {
                // Download flow
                print("==> Step 2: Read file info")
                guard let fileInfoCharacteristic else {
                    state = .error("File Info Characteristic is not ready, please retry again")
                    return
                }
                peripheral.readValue(for: fileInfoCharacteristic)
            } else if data.count >= 2 && data[0] == FileCommand.requestChunkFromApp.rawValue {
                // Upload flow
                print("==> Firmware requesting chunk \(data[1])")
                processChunkRequest(data)
            }
                
        case BLEConstants.fileInfoCharUUID: // FFE7
            if state == .transferring && totalChunks == -1 {
                // Download flow
                print("===> Step 3: Received file info, do the processing file info")
                print("====> process file info data: \(String(describing: data.string))")
                processFileInfo(data)
            }
                
        case BLEConstants.fileDataCharUUID: // FFE8
            if state == .transferring && totalChunks != -1 {
                // Download flow
                print("====> process chunk data: \(String(describing: data.string))")
                processChunkData(data)
            }
                
        case BLEConstants.fileErrCharUUID:
            print("====> error received: \(String(describing: data.string))")
                
        case BLEConstants.fileAckCharUUID:
            print("====> process ack data: \(String(describing: data.string))")
            
            if data.count >= 2 {
                if data[0] == FileCommand.chunkReceived.rawValue || data[0] == 0x01 {
                    // Download flow
                    handleAckResponse(data)
                } else if data[0] == 0x10 || data[0] == 0x08 {
                    // Upload flow
                    handleUploadAckResponse(data)
                }
            }
                
        default:
            break
        }
    }
    
//    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
//        if let error = error {
//            state = .error("Error reading characteristic value: \(error.localizedDescription)")
//            return
//        }
//        
//        print("==> [Delegate] didUpdateValueFor : \(characteristic)")
//        
//        guard let data = characteristic.value else { return }
//
//        switch characteristic.uuid {
//        case BLEConstants.fileControlCharUUID: // FFE6
//            print("==> Step 2: Read file info")
//            guard let fileInfoCharacteristic else {
//                state = .error("File Info Characteristic is not ready, please retry again")
//                return
//            }
//            if totalChunks == -1 && state == .transferring {
//                peripheral.readValue(for: fileInfoCharacteristic)
//            }
//            
//        case BLEConstants.fileInfoCharUUID: // FFE7
//            print("===> Step 3: Received file info, do the processing file info")
//            print("====> process file info data: \(String(describing: data.string))")
//            processFileInfo(data)
//            
//        case BLEConstants.fileDataCharUUID: // FFE8
//            print("====> process chunk data: \(String(describing: data.string))")
//            processChunkData(data)
//            
//        case BLEConstants.fileErrCharUUID:
//            print("====> error received: \(String(describing: data.string))")
//            
//        case BLEConstants.fileAckCharUUID:
//            print("====> process ack data: \(String(describing: data.string))")
//            handleAckResponse(data)
//            
//        default:
//            break
//        }
//    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        print("==> didWriteValueFor called for \(characteristic.uuid)")
        
        if let error = error {
            state = .error("Error writing value: \(error.localizedDescription)")
        }
        
        switch characteristic.uuid {
        case BLEConstants.fileControlCharUUID:
            if totalChunks == -1 && state == .transferring {
                peripheral.readValue(for: characteristic)
            }
            
        default:
            break
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
    }
    // Upload
    func processChunkRequest(_ data: Data) {
        
    }
    // Upload
    func handleUploadAckResponse(_ data: Data) {
    }
    
    private func processFileInfo(_ data: Data) {
        guard data.count > 1 else {
            state = .error("File info is invalid, please retry again")
            return
        }
        
        if totalChunks == -1 {
//            let nameLength = Int(data[0])
//            guard data.count >= nameLength + 5 else {
//                state = .error("File info has invalid format, please retry again")
//                return
//            }
            
            let nameLength = Int(data[0]) | (Int(data[1]) << 8)
            
            // Extract file name
            if let nameData = data.subdata(in: 1..<(nameLength+1)).string {
                fileName = nameData.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
            
            // Extract file size (4 bytes, little-endian)
            let fileSizeData = data.subdata(in: (nameLength+1)..<(nameLength+5))
            fileSize = Int(UInt32(littleEndian: fileSizeData.withUnsafeBytes { $0.load(as: UInt32.self) }))
            
            // Calculate total chunks
            totalChunks = Int((fileSize + chunkSize - 1) / chunkSize)  // Chunk size is 20 bytes
            
            currentChunk = 0
            fileData = Data()
            
            print("==> File info received: \(fileName), \(fileSize) bytes, \(totalChunks) chunks")
            
            // Start requesting chunks
            requestNextChunk()
        } else {
            // Continue request chunks
            currentChunk += 1
            requestNextChunk()
        }
    }
    
    private func requestNextChunk() {
        guard currentChunk < totalChunks else {
            completeTransfer()
            return
        }
        
        print("==> Step \(4 + currentChunk): Request next chunk with current chunk is: \(currentChunk)/\(totalChunks)")
        requestChunk(UInt8(currentChunk))
    }
    
    private func completeTransfer() {
        state = .complete
        currentChunk = 0
        totalChunks = -1
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
        // Read ack data to know the status
        guard let peripheral else {
            return
        }
        
        guard let fileAckChar = fileAcknowledgmentCharacteristic else {
            return
        }
        peripheral.readValue(for: fileAckChar)
    }
    
    func handleAckResponse(_ data: Data) {
        guard data.count >= 2 else {
            state = .error("Invalid response format")
            return
        }
        
        let responseCode = data[0]
        let statusCode = data[1]
        
        if responseCode == 0x01 {
            if statusCode == 0x00 {
                // Success case
                print("===> Transfer started successfully")
                
            } else {
                // Error case
                state = .error("===> Failed to start transfer, error code: \(statusCode)")
            }
        }
    }
    
    private func processChunkData(_ data: Data) {
        // Prevent un-wanted returned chunk
        guard totalChunks != -1 else { return }
        // Append chunk data to file data
        fileData.append(data)
        print("==> Received chunk \(currentChunk): \(data.count) bytes")
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
//                    .disabled(bleManager.state == .transferring)
                    .disabled(bleManager.isEnabledButton)
                    .padding()
                    
                    // Upload file
                    Button("Upload File") {
                        bleManager.startUploadFile()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bleManager.isEnabledButton)
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
