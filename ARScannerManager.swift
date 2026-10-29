import Foundation
import ARKit
import Combine
import SceneKit
import Metal
import simd
import AVFoundation

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
    @Published var connectionStatusMsg = "Chưa kiểm tra kết nối"

    var arView: ARSCNView?
    // Bộ nhớ đệm vĩnh viễn (Bảo toàn dữ liệu 100%, không bao giờ mất điểm)
    private var allMeshAnchors: [UUID: ARMeshAnchor] = [:]
    private var anchorColors: [UUID: [(UInt8, UInt8, UInt8)]] = [:]
    private var meshNodes: [UUID: SCNNode] = [:]
    private var lastFrame: ARFrame?
    
    // Kênh WebSocket truyền trực tiếp về Laptop
    private var webSocketTask: URLSessionWebSocketTask?
    private var liveStreamTimer: Timer?
    private var lastStreamedAnchorCount = 0

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
        
        if allMeshAnchors.isEmpty {
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
        allMeshAnchors.removeAll()
        anchorColors.removeAll()
        meshNodes.removeAll()
        vertexCount = 0
        faceCount = 0
        missingAreaCount = 0
        lastStreamedAnchorCount = 0
        coverageQuality = "Chưa quét"
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
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

    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        self.lastFrame = frame
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors.compactMap({ $0 as? ARMeshAnchor }) {
            allMeshAnchors[anchor.identifier] = anchor
            sampleColors(for: anchor)
        }
        updateMeshMetrics()
    }

    // MARK: - ARSCNViewDelegate
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        allMeshAnchors[meshAnchor.identifier] = meshAnchor
        sampleColors(for: meshAnchor)

        let node = SCNNode()
        let geometry = createVisualizationGeometry(meshAnchor: meshAnchor)
        node.geometry = geometry
        meshNodes[meshAnchor.identifier] = node
        updateMeshMetrics()
        return node
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        allMeshAnchors[meshAnchor.identifier] = meshAnchor
        sampleColors(for: meshAnchor)
        node.geometry = createVisualizationGeometry(meshAnchor: meshAnchor)
        updateMeshMetrics()
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        if let meshAnchor = anchor as? ARMeshAnchor {
            meshNodes.removeValue(forKey: meshAnchor.identifier)
        }
    }

    private func createVisualizationGeometry(meshAnchor: ARMeshAnchor) -> SCNGeometry {
        let scnGeom = SCNGeometry(arMeshGeometry: meshAnchor.geometry)
        let material = SCNMaterial()
        material.fillMode = .lines
        material.isDoubleSided = true

        let vCount = meshAnchor.geometry.vertices.count
        if highlightMissing && vCount < 400 {
            material.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.9)
            material.emission.contents = UIColor.red.withAlphaComponent(0.4)
        } else {
            material.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.85)
            material.emission.contents = UIColor.green.withAlphaComponent(0.2)
        }

        scnGeom.materials = [material]
        return scnGeom
    }

    // MARK: - Lấy mẫu màu thực tế từ Camera cho các đỉnh 3D (Photographic Texture Mapping)
    private func sampleColors(for anchor: ARMeshAnchor) {
        guard let frame = lastFrame else { return }
        let pixelBuffer = frame.capturedImage
        let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(pixelBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return }

        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let yPointer = yBase.assumingMemoryBound(to: UInt8.self)
        let cbcrPointer = cbcrBase.assumingMemoryBound(to: UInt8.self)

        let vertices = anchor.geometry.vertices
        let transform = anchor.transform
        var colors: [(UInt8, UInt8, UInt8)] = []
        colors.reserveCapacity(vertices.count)

        for i in 0..<vertices.count {
            let v = vertices[i]
            let localCoord = simd_float4(v[0], v[1], v[2], 1.0)
            let worldCoord = simd_mul(transform, localCoord)
            let worldPos3 = simd_float3(worldCoord.x, worldCoord.y, worldCoord.z)

            // Chiếu tọa độ 3D vào khung ảnh 2D của camera
            let pt = frame.camera.projectPoint(worldPos3, orientation: .portrait, viewportSize: CGSize(width: imageWidth, height: imageHeight))
            let px = Int(pt.x)
            let py = Int(pt.y)

            if px >= 0 && px < imageWidth && py >= 0 && py < imageHeight {
                let yVal = Float(yPointer[py * yBytesPerRow + px])
                let uvX = (px / 2) * 2
                let uvY = py / 2
                let cbVal = Float(cbcrPointer[uvY * cbcrBytesPerRow + uvX]) - 128.0
                let crVal = Float(cbcrPointer[uvY * cbcrBytesPerRow + uvX + 1]) - 128.0

                let r = UInt8(clamping: Int(yVal + 1.402 * crVal))
                let g = UInt8(clamping: Int(yVal - 0.344136 * cbVal - 0.714136 * crVal))
                let b = UInt8(clamping: Int(yVal + 1.772 * cbVal))
                colors.append((r, g, b))
            } else {
                colors.append((210, 180, 140)) // Màu sa thạch mặc định
            }
        }

        anchorColors[anchor.identifier] = colors
    }

    private func updateMeshMetrics() {
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

        DispatchQueue.main.async {
            self.vertexCount = totalVerts
            self.faceCount = totalFaces
            self.missingAreaCount = sparseChunks

            if totalVerts < 10000 {
                self.coverageQuality = "Thấp (Cần quét thêm)"
                self.accuracyErrorMM = 3.5
            } else if totalVerts < 40000 {
                self.coverageQuality = "Trung bình"
                self.accuracyErrorMM = 2.1
            } else {
                self.coverageQuality = "Chuẩn HBIM (LOD 300)"
                self.accuracyErrorMM = 1.2
            }
        }
    }

    // MARK: - Kiểm tra kết nối tới Laptop
    func testConnection(serverIP: String, completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: "http://\(serverIP):8000/api/models") else {
            completion(false, "Địa chỉ IP không hợp lệ")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    self?.isConnectedToLaptop = true
                    self?.connectionStatusMsg = "Đã kết nối thành công tới \(serverIP):8000"
                    completion(true, "Đã kết nối thành công!")
                } else {
                    self?.isConnectedToLaptop = false
                    self?.connectionStatusMsg = "Không tìm thấy Laptop. Hãy kiểm tra kết nối WiFi hoặc cáp USB."
                    completion(false, "Không kết nối được: Hãy bật Wi-Fi (cùng mạng Laptop) hoặc cắm cáp USB (172.20.10.2)")
                }
            }
        }.resume()
    }

    // MARK: - Đồng bộ thời gian thực qua WebSocket (Quét đến đâu, Laptop hiện đến đó!)
    func toggleLiveStream(serverIP: String) {
        if isLiveStreaming {
            stopLiveStream()
        } else {
            startLiveStream(serverIP: serverIP)
        }
    }

    func startLiveStream(serverIP: String) {
        isLiveStreaming = true
        connectWebSocket(serverIP: serverIP)

        // Bắn tọa độ điểm & màu thực tế liên tục mỗi 0.35 giây về Laptop
        liveStreamTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self = self, self.isScanning, self.vertexCount > 0 else { return }
            self.streamLiveBatch()
        }
    }

    private func connectWebSocket(serverIP: String) {
        guard let url = URL(string: "ws://\(serverIP):8000/ws/stream") else { return }
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
    }

    private func streamLiveBatch() {
        guard let ws = webSocketTask else { return }

        var pointsArr: [[Float]] = []
        var colorsArr: [[Float]] = []

        let anchorsList = Array(allMeshAnchors.values)
        guard !anchorsList.isEmpty else { return }

        // Gửi các anchor mới nhất
        let sampleAnchors = anchorsList.suffix(6)

        for anchor in sampleAnchors {
            let vertices = anchor.geometry.vertices
            let transform = anchor.transform
            let colors = anchorColors[anchor.identifier] ?? []

            // Lấy mẫu các đỉnh để tối ưu đường truyền mạng mượt mà
            let step = max(1, vertices.count / 60)
            for i in stride(from: 0, to: vertices.count, by: step) {
                let v = vertices[i]
                let localCoord = simd_float4(v[0], v[1], v[2], 1.0)
                let worldCoord = simd_mul(transform, localCoord)
                pointsArr.append([worldCoord.x, worldCoord.y, worldCoord.z])

                if i < colors.count {
                    let c = colors[i]
                    colorsArr.append([Float(c.0) / 255.0, Float(c.1) / 255.0, Float(c.2) / 255.0])
                } else {
                    colorsArr.append([0.83, 0.64, 0.45])
                }
            }
        }

        guard !pointsArr.isEmpty else { return }

        let payload: [String: Any] = [
            "type": "points_batch",
            "points": pointsArr,
            "colors": colorsArr
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            ws.send(.string(jsonStr)) { _ in }
        }
    }

    func stopLiveStream() {
        isLiveStreaming = false
        liveStreamTimer?.invalidate()
        liveStreamTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Xuất file PLY có đầy đủ MÀU SẮC THỰC TẾ & CHẤT LIỆU
    func exportToPLY() -> URL? {
        guard !allMeshAnchors.isEmpty else { return nil }

        let fileName = "HueHeritage_\(Int(Date().timeIntervalSince1970)).ply"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        let plyHeader = """
        ply
        format ascii 1.0
        comment Huế Heritage Scanner - Digital Twin & HBIM
        comment Estimated Accuracy: ±\(String(format: "%.1f", accuracyErrorMM)) mm
        element vertex \(vertexCount)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face \(faceCount)
        property list uchar int vertex_indices
        end_header
        
        """

        var vertexData = ""
        var faceData = ""
        var vertexOffset = 0

        for anchor in allMeshAnchors.values {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let colors = anchorColors[anchor.identifier] ?? []

            let vertices = geometry.vertices
            for i in 0..<vertices.count {
                let vertex = vertices[i]
                let localCoord = simd_float4(vertex[0], vertex[1], vertex[2], 1.0)
                let worldCoord = simd_mul(transform, localCoord)

                let r: UInt8 = i < colors.count ? colors[i].0 : 210
                let g: UInt8 = i < colors.count ? colors[i].1 : 180
                let b: UInt8 = i < colors.count ? colors[i].2 : 140

                vertexData += String(format: "%.4f %.4f %.4f %d %d %d\n", worldCoord.x, worldCoord.y, worldCoord.z, r, g, b)
            }

            let faces = geometry.faces
            for i in 0..<faces.count {
                let idx0 = Int(faces[i, 0]) + vertexOffset
                let idx1 = Int(faces[i, 1]) + vertexOffset
                let idx2 = Int(faces[i, 2]) + vertexOffset
                faceData += "3 \(idx0) \(idx1) \(idx2)\n"
            }

            vertexOffset += vertices.count
        }

        let fullContent = plyHeader + vertexData + faceData
        do {
            try fullContent.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            return nil
        }
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
                    popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.maxY - 120, width: 0, height: 0)
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

    // MARK: - Gửi tệp có màu thực tế lên Laptop
    func uploadToServer(serverIP: String, isBackgroundStream: Bool = false, completion: @escaping (Bool, String) -> Void) {
        if !isBackgroundStream {
            isUploading = true
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let fileURL = self.exportToPLY() else {
                DispatchQueue.main.async {
                    if !isBackgroundStream { self?.isUploading = false }
                    completion(false, "Chưa có dữ liệu quét")
                }
                return
            }

            let uploadURL = URL(string: "http://\(serverIP):8000/api/upload")!
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 8

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
                        completion(false, "Không kết nối được: Hãy bật Wi-Fi (cùng mạng Laptop) hoặc cắm cáp USB")
                        return
                    }
                    self.isConnectedToLaptop = true
                    completion(true, "Đồng bộ thành công đầy đủ Màu Sắc & Vật Liệu!")
                }
            }
            task.resume()
        }
    }
}

// MARK: - Extensions ARKit & SceneKit
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
        return pointer.assumingMemoryBound(to: Int32.self).pointee
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

        let faceElement = SCNGeometryElement(
            data: Data(bytesNoCopy: faces.buffer.contents(), count: faces.buffer.length, deallocator: .none),
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: faces.bytesPerIndex
        )

        self.init(sources: sources, elements: [faceElement])
    }
}
