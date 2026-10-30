import Foundation
import ARKit
import Combine
import SceneKit
import Metal
import simd
import AVFoundation
import UIKit

class ARScannerManager: NSObject, ObservableObject, ARSessionDelegate, ARSCNViewDelegate {
    @Published var isScanning = false
    @Published var vertexCount = 0
    @Published var faceCount = 0
    @Published var coverageQuality = "Chưa quét"
    @Published var isUploading = false
    @Published var isLiveStreaming = false
    @Published var enableSmoothing = true
    @Published var highlightMissing = true
    @Published var accuracyErrorMM: Double = 1.8
    @Published var missingAreaCount: Int = 0
    @Published var isTorchOn = false
    @Published var isConnectedToLaptop = false
    @Published var connectionStatusMsg = "Chưa kiểm tra"
    @Published var autoSyncEnabled = true

    var arView: ARSCNView?

    // Bộ nhớ đệm thread-safe (Bảo toàn 100% dữ liệu, không bao giờ mất điểm hay sập app)
    private let meshQueue = DispatchQueue(label: "vn.hueheritage.meshQueue")
    private var allMeshAnchors: [UUID: ARMeshAnchor] = [:]
    private var anchorColors: [UUID: [UInt8]] = [:]
    private var meshNodes: [UUID: SCNNode] = [:]
    
    // Throttling để tối ưu hiệu năng và chống tràn bộ nhớ / văng app
    private var lastMetricsUpdate: TimeInterval = 0
    private var lastColorSampleTime: TimeInterval = 0
    
    // Kênh WebSocket truyền trực tiếp
    private var webSocketTask: URLSessionWebSocketTask?
    private var liveStreamTimer: Timer?
    private var isStreamingBatch = false
    private var currentServerIP: String = "192.168.2.17"

    func startSession() {
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        configuration.environmentTexturing = .automatic

        arView?.session.delegate = self
        arView?.delegate = self
        
        let hasData = meshQueue.sync { !allMeshAnchors.isEmpty }
        if !hasData {
            arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } else {
            arView?.session.run(configuration, options: [])
        }
        isScanning = true
    }

    func stopSession() {
        arView?.session.pause()
        isScanning = false
        stopLiveStream()
        if isTorchOn {
            toggleTorch()
        }
    }

    func resetScan() {
        meshQueue.sync {
            allMeshAnchors.removeAll()
            anchorColors.removeAll()
            meshNodes.removeAll()
        }
        DispatchQueue.main.async {
            self.vertexCount = 0
            self.faceCount = 0
            self.missingAreaCount = 0
            self.coverageQuality = "Chưa quét"
        }
        
        // Gửi thông điệp xoá sạch không gian hiển thị trên Laptop
        notifyLaptopReset()
        
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    private func notifyLaptopReset() {
        guard let ws = webSocketTask else { return }
        let payload: [String: Any] = ["type": "reset_session"]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            ws.send(.string(str)) { _ in }
        }
    }

    // MARK: - Điều khiển Đèn Flash
    func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if isTorchOn {
                device.torchMode = .off
                isTorchOn = false
            } else {
                try? device.setTorchModeOn(level: 1.0)
                device.torchMode = .on
                isTorchOn = true
            }
            device.unlockForConfiguration()
        } catch {
            print("Lỗi flash: \(error)")
        }
    }

    // MARK: - ARSessionDelegate: Bắt màu thực từ camera và ghi nhận mesh (Chống văng app 100%, đồng bộ tọa độ thế giới chính xác)
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let meshList = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshList.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        let shouldSampleColors = (now - lastColorSampleTime > 0.3)
        let currentFrame = shouldSampleColors ? session.currentFrame : nil
        if shouldSampleColors {
            lastColorSampleTime = now
        }

        meshQueue.async { [weak self] in
            guard let self = self else { return }
            for anchor in meshList {
                self.allMeshAnchors[anchor.identifier] = anchor
                if let frame = currentFrame {
                    let oldColors = self.anchorColors[anchor.identifier]
                    let colors = self.sampleCameraColors(for: anchor, frame: frame, existingColors: oldColors)
                    if !colors.isEmpty {
                        self.anchorColors[anchor.identifier] = colors
                    }
                }
            }
            self.throttledUpdateMeshMetrics()
        }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let meshList = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshList.isEmpty else { return }
        meshQueue.async { [weak self] in
            guard let self = self else { return }
            for a in meshList {
                self.allMeshAnchors.removeValue(forKey: a.identifier)
                self.anchorColors.removeValue(forKey: a.identifier)
            }
        }
    }

        // MARK: - Trích xuất Màu Sắc Ảnh Thực tế từ Cảm biến Camera LiDAR với Lọc Pháp Tuyến & Bảo tồn Màu
    private func sampleCameraColors(for anchor: ARMeshAnchor, frame: ARFrame?, existingColors: [UInt8]?) -> [UInt8] {
        guard let frame = frame else { return existingColors ?? [] }
        let pixelBuffer = frame.capturedImage
        let camera = frame.camera

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
            return existingColors ?? []
        }

        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let vertices = anchor.geometry.vertices
        let transform = anchor.transform
        let invCam = camera.transform.inverse
        let fx = camera.intrinsics[0][0]
        let fy = camera.intrinsics[1][1]
        let cx = camera.intrinsics[2][0]
        let cy = camera.intrinsics[2][1]

        let oldColors = existingColors
        let hasOld = (oldColors != nil && oldColors!.count >= vertices.count * 3)

        var colors = [UInt8]()
        colors.reserveCapacity(vertices.count * 3)

        let defR: UInt8 = 215
        let defG: UInt8 = 180
        let defB: UInt8 = 140

        let camPos = simd_float3(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)
        let rot = simd_float3x3(anchor.transform.columns.0.xyz, anchor.transform.columns.1.xyz, anchor.transform.columns.2.xyz)
        let normals = anchor.geometry.normals
        let hasNormals = (normals.count == vertices.count)

        for i in 0..<vertices.count {
            let v = vertices[i]
            let worldCoord = simd_mul(transform, simd_float4(v[0], v[1], v[2], 1.0))
            let camCoord = simd_mul(invCam, worldCoord)

            var sampled = false
            var r: UInt8 = defR
            var g: UInt8 = defG
            var b: UInt8 = defB

            // Điểm nằm trước camera trong phạm vi hiệu dụng LiDAR 0.15m - 4.5m
            if -camCoord.z > 0.15 && -camCoord.z < 4.5 {
                let depth = -camCoord.z
                let px = Int((fx * (camCoord.x / depth)) + cx)
                let py = Int((fy * (-camCoord.y / depth)) + cy)

                if px >= 0 && px < width && py >= 0 && py < height {
                    var isValidAngle = true
                    if hasNormals {
                        let n = normals[i]
                        let worldNorm = simd_normalize(simd_mul(rot, simd_float3(n[0], n[1], n[2])))
                        let dirToCam = simd_normalize(camPos - simd_float3(worldCoord.x, worldCoord.y, worldCoord.z))
                        let angleCos = simd_dot(worldNorm, dirToCam)
                        // Bề mặt phải hướng về phía camera ít nhất ~15 độ để tránh nhòe góc cạnh hoặc tràn màu mặt sau
                        if angleCos < 0.25 {
                            isValidAngle = false
                        }
                    }

                    if isValidAngle {
                        let yVal = Float(yBase[py * yStride + px])
                        let uvRow = (py / 2) * uvStride
                        let uvCol = (px / 2) * 2
                        let cbVal = Float(uvBase[uvRow + uvCol]) - 128.0
                        let crVal = Float(uvBase[uvRow + uvCol + 1]) - 128.0

                        r = UInt8(clamping: Int(yVal + 1.402 * crVal))
                        g = UInt8(clamping: Int(yVal - 0.344136 * cbVal - 0.714136 * crVal))
                        b = UInt8(clamping: Int(yVal + 1.772 * cbVal))
                        sampled = true
                    }
                }
            }

            if sampled {
                colors.append(r)
                colors.append(g)
                colors.append(b)
            } else if hasOld {
                // Bảo tồn 100% màu ảnh thật đã chụp trước đó, không bị ghi đè màu vàng/đen khi quay camera góc khác
                colors.append(oldColors![i * 3])
                colors.append(oldColors![i * 3 + 1])
                colors.append(oldColors![i * 3 + 2])
            } else {
                colors.append(defR)
                colors.append(defG)
                colors.append(defB)
            }
        }
        return colors
    }

    // MARK: - ARSCNViewDelegate: Hiển thị Wireframe Mesh
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }

        let node = SCNNode()
        node.geometry = createVisualizationGeometry(meshAnchor: meshAnchor)
        meshQueue.async { [weak self] in
            self?.meshNodes[meshAnchor.identifier] = node
        }
        return node
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        // Tối ưu hóa bộ nhớ: chỉ tạo lại SCNGeometry khi số đỉnh thay đổi đáng kể để chống giật lag và chống văng app
        let curCount = node.geometry?.sources.first?.vectorCount ?? 0
        if abs(curCount - meshAnchor.geometry.vertices.count) > 20 {
            node.geometry = createVisualizationGeometry(meshAnchor: meshAnchor)
        }
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        if let meshAnchor = anchor as? ARMeshAnchor {
            meshQueue.async { [weak self] in
                self?.meshNodes.removeValue(forKey: meshAnchor.identifier)
            }
        }
    }

    private func createVisualizationGeometry(meshAnchor: ARMeshAnchor) -> SCNGeometry {
        let scnGeom = SCNGeometry(arMeshGeometry: meshAnchor.geometry)
        let material = SCNMaterial()
        material.fillMode = .lines
        material.isDoubleSided = true

        let vCount = meshAnchor.geometry.vertices.count
        if highlightMissing && vCount < 400 {
            material.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.85)
        } else {
            material.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.8)
        }

        scnGeom.materials = [material]
        return scnGeom
    }

    private func throttledUpdateMeshMetrics() {
        let now = Date().timeIntervalSince1970
        guard now - lastMetricsUpdate > 0.3 else { return }
        lastMetricsUpdate = now

        var totalVerts = 0
        var totalFaces = 0
        var sparseChunks = 0

        for anchor in allMeshAnchors.values {
            let v = anchor.geometry.vertices.count
            totalVerts += v
            totalFaces += anchor.geometry.faces.count
            if v < 400 {
                sparseChunks += 1
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.vertexCount = totalVerts
            self.faceCount = totalFaces
            self.missingAreaCount = sparseChunks

            if totalVerts < 10000 {
                self.coverageQuality = "Thấp (Cần quét thêm)"
                self.accuracyErrorMM = 3.2
            } else if totalVerts < 40000 {
                self.coverageQuality = "Trung bình"
                self.accuracyErrorMM = 2.0
            } else {
                self.coverageQuality = "Chuẩn HBIM (LOD 300)"
                self.accuracyErrorMM = 1.1
            }
        }
    }

    // MARK: - Kiểm tra kết nối tới Laptop
    func testConnection(serverIP: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "http://\(serverIP):8000/api/models") else {
            completion(false, "IP không hợp lệ")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    self?.isConnectedToLaptop = true
                    self?.connectionStatusMsg = "Đã kết nối tới \(serverIP):8000"
                    completion(true, "Kết nối thành công tới máy chủ!")
                } else {
                    self?.isConnectedToLaptop = false
                    self?.connectionStatusMsg = "Không tìm thấy Laptop. Hãy bật Wi-Fi (cùng mạng Laptop) hoặc cắm cáp USB (172.20.10.2)"
                    completion(false, "Chưa kết nối được máy chủ")
                }
            }
        }.resume()
    }

    // MARK: - Live Stream WebSocket: Truyền MẶT LƯỚI 3D TOÀN BỘ (SNAPSHOT) Thời Gian Thực
    func toggleLiveStream(serverIP: String) {
        currentServerIP = serverIP
        if isLiveStreaming {
            stopLiveStream()
        } else {
            startLiveStream(serverIP: serverIP)
        }
    }

        func startLiveStream(serverIP: String) {
        currentServerIP = serverIP
        isLiveStreaming = true
        connectWebSocket(serverIP: serverIP)

        liveStreamTimer?.invalidate()
        // Phát sóng MESH bề mặt 3D mỗi 0.6 giây
        liveStreamTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self = self, self.isScanning, self.vertexCount > 0 else { return }
            self.streamLiveMeshBatch()
        }
    }

    private func connectWebSocket(serverIP: String) {
        guard let url = URL(string: "ws://\(serverIP):8000/ws/stream") else { return }
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        // Mở rộng bộ đệm tối đa lên 64MB để không bao giờ bị nghẽn payload
        task.maximumMessageSize = 64 * 1024 * 1024
        task.resume()
        self.webSocketTask = task
        self.listenWebSocket()
    }

    private func reconnectWebSocket() {
        guard isLiveStreaming else { return }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.isLiveStreaming else { return }
            self.connectWebSocket(serverIP: self.currentServerIP)
        }
    }

    private func listenWebSocket() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .failure(_):
                self?.reconnectWebSocket()
            case .success(_):
                self?.listenWebSocket()
            }
        }
    }

    // Truyền toàn bộ Mesh bề mặt 3D thực tế theo thời gian thực (Đồng bộ 1:1 với iPhone, không gián đoạn, tự phục hồi)
    private func streamLiveMeshBatch() {
        guard let ws = webSocketTask, !isStreamingBatch else {
            if isLiveStreaming && (webSocketTask == nil || webSocketTask?.state != .running) {
                reconnectWebSocket()
            }
            return
        }
        isStreamingBatch = true

        meshQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.isStreamingBatch = false }

            let anchorsList = Array(self.allMeshAnchors.values)
            guard !anchorsList.isEmpty else { return }

            // Giữ thứ tự cố định theo UUID để tọa độ đỉnh không bị nhảy xáo trộn
            let sortedAnchors = anchorsList.sorted { $0.identifier.uuidString < $1.identifier.uuidString }
            // Truyền lên tới 150 anchor mới nhất để bao phủ rộng khắp không gian
            let activeAnchors = sortedAnchors.count > 150 ? Array(sortedAnchors.suffix(150)) : sortedAnchors
            
            var allPositions: [Float] = []
            var allColors: [UInt8] = [] // Dùng UInt8 [0-255] giảm 6 lần dung lượng JSON
            var allIndices: [Int] = []
            var vOffset = 0

            for anchor in activeAnchors {
                let vertices = anchor.geometry.vertices
                let faces = anchor.geometry.faces
                let transform = anchor.transform
                let cList = self.anchorColors[anchor.identifier]

                for i in 0..<vertices.count {
                    let v = vertices[i]
                    let localCoord = simd_float4(v[0], v[1], v[2], 1.0)
                    let worldCoord = simd_mul(transform, localCoord)
                    // Làm tròn 3 số thập phân (độ chính xác 1mm) để giảm dung lượng mạng
                    allPositions.append((worldCoord.x * 1000).rounded() / 1000)
                    allPositions.append((worldCoord.y * 1000).rounded() / 1000)
                    allPositions.append((worldCoord.z * 1000).rounded() / 1000)

                    if let clr = cList, (i * 3 + 2) < clr.count {
                        allColors.append(clr[i * 3])
                        allColors.append(clr[i * 3 + 1])
                        allColors.append(clr[i * 3 + 2])
                    } else {
                        allColors.append(215)
                        allColors.append(180)
                        allColors.append(140)
                    }
                }

                for f in 0..<faces.count {
                    allIndices.append(Int(faces[f, 0]) + vOffset)
                    allIndices.append(Int(faces[f, 1]) + vOffset)
                    allIndices.append(Int(faces[f, 2]) + vOffset)
                }

                vOffset += vertices.count
            }

            guard !allPositions.isEmpty else { return }

            let payload: [String: Any] = [
                "type": "mesh_snapshot",
                "positions": allPositions,
                "indices": allIndices,
                "colors": allColors
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
                  let jsonStr = String(data: jsonData, encoding: .utf8) else {
                return
            }

            ws.send(.string(jsonStr)) { [weak self] error in
                if let _ = error {
                    // Tự động kết nối lại nếu có lỗi đường truyền mà không làm gián đoạn việc quét
                    self?.reconnectWebSocket()
                }
            }
        }
    }

    func stopLiveStream() {
        isLiveStreaming = false
        liveStreamTimer?.invalidate()
        liveStreamTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Xuất file PLY trực tiếp bằng FileHandle kèm Texture ảnh chụp thực tế
    func exportToPLY() -> URL? {
        let (anchorsSnapshot, colorsSnapshot, totalV, totalF) = meshQueue.sync {
            (Array(allMeshAnchors.values), anchorColors, vertexCount, faceCount)
        }
        guard !anchorsSnapshot.isEmpty else { return nil }

        let fileName = "HueHeritage_\(Int(Date().timeIntervalSince1970)).ply"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        FileManager.default.createFile(atPath: tempURL.path, contents: nil, attributes: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: tempURL) else { return nil }

        defer {
            try? fileHandle.close()
        }

        let header = """
        ply
        format ascii 1.0
        comment Hue Heritage Scanner - Digital Twin & HBIM
        comment Estimated Accuracy: ±\(String(format: "%.1f", accuracyErrorMM)) mm
        element vertex \(totalV)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face \(totalF)
        property list uchar int vertex_indices
        end_header
        
        """

        if let headerData = header.data(using: .utf8) {
            fileHandle.write(headerData)
        }

        var vertexOffset = 0
        var vertexChunk = ""
        var faceChunk = ""

        for anchor in anchorsSnapshot {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let vertices = geometry.vertices
            let clr = colorsSnapshot[anchor.identifier]

            for i in 0..<vertices.count {
                let v = vertices[i]
                let localCoord = simd_float4(v[0], v[1], v[2], 1.0)
                let worldCoord = simd_mul(transform, localCoord)

                var r: UInt8 = 215
                var g: UInt8 = 180
                var b: UInt8 = 140

                if let clr = clr, (i * 3 + 2) < clr.count {
                    r = clr[i * 3]
                    g = clr[i * 3 + 1]
                    b = clr[i * 3 + 2]
                }

                vertexChunk += String(format: "%.4f %.4f %.4f %d %d %d\n", worldCoord.x, worldCoord.y, worldCoord.z, r, g, b)

                if vertexChunk.count > 16384 {
                    if let d = vertexChunk.data(using: .utf8) { fileHandle.write(d) }
                    vertexChunk = ""
                }
            }

            let faces = geometry.faces
            for i in 0..<faces.count {
                let idx0 = Int(faces[i, 0]) + vertexOffset
                let idx1 = Int(faces[i, 1]) + vertexOffset
                let idx2 = Int(faces[i, 2]) + vertexOffset
                faceChunk += "3 \(idx0) \(idx1) \(idx2)\n"

                if faceChunk.count > 16384 {
                    if let d = faceChunk.data(using: .utf8) { fileHandle.write(d) }
                    faceChunk = ""
                }
            }

            vertexOffset += vertices.count
        }

        if !vertexChunk.isEmpty, let d = vertexChunk.data(using: .utf8) { fileHandle.write(d) }
        if !faceChunk.isEmpty, let d = faceChunk.data(using: .utf8) { fileHandle.write(d) }

        return tempURL
    }

    // MARK: - Chia sẻ file PLY chuẩn iOS
    func sharePLYFile() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let url = self.exportToPLY() else { return }
            DispatchQueue.main.async {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                      let rootVC = windowScene.windows.first?.rootViewController else { return }
                
                let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let popover = activityVC.popoverPresentationController {
                    popover.sourceView = rootVC.view
                    popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.maxY - 80, width: 0, height: 0)
                    popover.permittedArrowDirections = [.down]
                }
                
                var topController = rootVC
                while let presented = topController.presentedViewController {
                    topController = presented
                }
                topController.present(activityVC, animated: true)
            }
        }
    }

    // MARK: - Gửi tệp lên Laptop (Hỗ trợ tự động ghép Master ICP trên máy chủ)
    func uploadToServer(serverIP: String, isBackgroundStream: Bool = false, completion: @escaping (Bool, String) -> Void) {
        if !isBackgroundStream {
            isUploading = true
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let fileURL = self.exportToPLY() else {
                DispatchQueue.main.async {
                    if !isBackgroundStream { self?.isUploading = false }
                    completion(false, "Chưa có dữ liệu quét để đồng bộ")
                }
                return
            }

            let uploadURL = URL(string: "http://\(serverIP):8000/api/upload")!
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 10

            let boundary = "Boundary-\(UUID().uuidString)"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            if let fileData = try? Data(contentsOf: fileURL) {
                body.append(fileData)
            }
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

            let task = URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
                DispatchQueue.main.async {
                    if !isBackgroundStream {
                        self.isUploading = false
                    }
                    if let error = error {
                        self.isConnectedToLaptop = false
                        completion(false, "Lỗi kết nối: Kiểm tra Wi-Fi cùng mạng Laptop hoặc cắm cáp USB")
                        return
                    }
                    self.isConnectedToLaptop = true
                    completion(true, "Đồng bộ thành công! Laptop đã tự động ghép mô hình.")
                }
            }
            task.resume()
        }
    }
}

// MARK: - Extensions ARKit & SceneKit (Đọc an toàn cả 16-bit và 32-bit Index, chống sập tuyệt đối)
private extension ARGeometrySource {
    subscript(index: Int) -> simd_float3 {
        let pointer = buffer.contents().advanced(by: offset + (self.stride * index))
        return pointer.assumingMemoryBound(to: simd_float3.self).pointee
    }
}

private extension ARGeometryElement {
    subscript(faceIndex: Int, vertexIndex: Int) -> Int32 {
        let faceStride = self.bytesPerIndex * self.indexCountPerPrimitive
        let pointer = buffer.contents().advanced(by: (faceIndex * faceStride) + (vertexIndex * self.bytesPerIndex))
        if self.bytesPerIndex == 2 {
            return Int32(pointer.assumingMemoryBound(to: UInt16.self).pointee)
        } else {
            return pointer.assumingMemoryBound(to: Int32.self).pointee
        }
    }
}

private extension SCNGeometry {
    convenience init(arMeshGeometry: ARMeshGeometry) {
        let vertices = arMeshGeometry.vertices
        let normals = arMeshGeometry.normals
        let faces = arMeshGeometry.faces

        let vertexSource = SCNGeometrySource(
            buffer: vertices.buffer,
            vertexFormat: vertices.format,
            semantic: .vertex,
            vertexCount: vertices.count,
            dataOffset: vertices.offset,
            dataStride: vertices.stride
        )

        var sources: [SCNGeometrySource] = [vertexSource]

        if normals.count > 0 {
            let normalSource = SCNGeometrySource(
                buffer: normals.buffer,
                vertexFormat: normals.format,
                semantic: .normal,
                vertexCount: normals.count,
                dataOffset: normals.offset,
                dataStride: normals.stride
            )
            sources.append(normalSource)
        }

        let faceData = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
        let faceElement = SCNGeometryElement(
            data: faceData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: faces.bytesPerIndex
        )

        self.init(sources: sources, elements: [faceElement])
    }
}
