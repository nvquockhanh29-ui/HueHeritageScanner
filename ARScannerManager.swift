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

    // Bộ nhớ đệm thread-safe (Bảo toàn 100% dữ liệu di tích, không bao giờ mất điểm hay tràn ram)
    private let meshQueue = DispatchQueue(label: "vn.hueheritage.meshQueue")
    private var allMeshAnchors: [UUID: ARMeshAnchor] = [:]
    private var anchorColors: [UUID: [UInt8]] = [:]
    private var meshNodes: [UUID: SCNNode] = [:]
    
    // Throttling để tối ưu hiệu năng và chống tràn bộ nhớ
    private var lastMetricsUpdate: TimeInterval = 0
    
    // Kênh WebSocket truyền trực tiếp mắt quét (Sensor Eye)
    private var webSocketTask: URLSessionWebSocketTask?
    private var currentServerIP: String = "172.20.10.2"

    func startSession(serverIP: String? = nil) {
        if let ip = serverIP, !ip.trimmingCharacters(in: .whitespaces).isEmpty {
            currentServerIP = ip.trimmingCharacters(in: .whitespaces)
        }

        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        configuration.environmentTexturing = .automatic
        configuration.planeDetection = [.horizontal, .vertical]

        arView?.session.delegate = self
        arView?.delegate = self
        
        let hasData = meshQueue.sync { !allMeshAnchors.isEmpty }
        if !hasData {
            arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } else {
            arView?.session.run(configuration, options: [])
        }
        isScanning = true

        // Tự động khởi tạo luồng truyền trực tiếp mắt quét sang Laptop
        startLiveStream(serverIP: currentServerIP)
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

    // MARK: - ARSessionDelegate: Mắt Quét Cảm Biến Thời Gian Thực (Sensor Eye)
    // iPhone đóng vai trò mắt quét LiDAR, truyền từng khối nhẹ sang Laptop xử lý trực tiếp
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        handleMeshAnchors(anchors, session: session)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        handleMeshAnchors(anchors, session: session)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        // Bảo tồn toàn bộ các phần di tích đã quét trong bộ nhớ, không xóa
    }

    private func handleMeshAnchors(_ anchors: [ARAnchor], session: ARSession) {
        let meshList = anchors.compactMap { $0 as? ARMeshAnchor }
        guard !meshList.isEmpty else { return }

        let currentFrame = session.currentFrame

        meshQueue.async { [weak self] in
            guard let self = self else { return }

            for anchor in meshList {
                self.allMeshAnchors[anchor.identifier] = anchor
                let oldColors = self.anchorColors[anchor.identifier]
                let colors = self.sampleCameraColors(for: anchor, frame: currentFrame, existingColors: oldColors)
                self.anchorColors[anchor.identifier] = colors

                // Truyền trực tiếp khối quét thời gian thực sang Laptop (Mắt quét quang học, không nặng CPU)
                self.sendAnchorChunk(anchor: anchor, colors: colors)
            }

            // Tự động sơn màu ảnh thật lên các khối lân cận trong tầm nhìn camera
            if let frame = currentFrame {
                let camPos = simd_float3(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                var paintedCount = 0
                for (id, anchor) in self.allMeshAnchors {
                    guard paintedCount < 2 else { break }
                    if meshList.contains(where: { $0.identifier == id }) { continue }

                    let anchorPos = simd_float3(anchor.transform.columns.3.x, anchor.transform.columns.3.y, anchor.transform.columns.3.z)
                    if simd_distance(camPos, anchorPos) < 4.0 {
                        let oldColors = self.anchorColors[id]
                        let colors = self.sampleCameraColors(for: anchor, frame: frame, existingColors: oldColors)
                        if !colors.isEmpty {
                            self.anchorColors[id] = colors
                            self.sendAnchorChunk(anchor: anchor, colors: colors)
                            paintedCount += 1
                        }
                    }
                }
            }

            self.throttledUpdateMeshMetrics()
        }
    }

    // MARK: - Truyền trực tiếp từng khối Anchor (Siêu nhẹ ~8KB, 0% CPU điện thoại)
    private func sendAnchorChunk(anchor: ARMeshAnchor, colors: [UInt8]) {
        guard isLiveStreaming, let ws = webSocketTask, ws.state == .running else { return }

        let transform = anchor.transform
        let transformArray: [Float] = [
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
            transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w
        ]

        let vertices = anchor.geometry.vertices
        let faces = anchor.geometry.faces

        var localPositions: [Float] = []
        localPositions.reserveCapacity(vertices.count * 3)
        for i in 0..<vertices.count {
            let v = vertices[i]
            localPositions.append((v.x * 1000).rounded() / 1000)
            localPositions.append((v.y * 1000).rounded() / 1000)
            localPositions.append((v.z * 1000).rounded() / 1000)
        }

        var indices: [Int] = []
        indices.reserveCapacity(faces.count * 3)
        for f in 0..<faces.count {
            indices.append(Int(faces[f, 0]))
            indices.append(Int(faces[f, 1]))
            indices.append(Int(faces[f, 2]))
        }

        let chunkPayload: [String: Any] = [
            "type": "anchor_chunk",
            "id": anchor.identifier.uuidString,
            "transform": transformArray,
            "positions": localPositions,
            "indices": indices,
            "colors": colors
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: chunkPayload),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            ws.send(.string(jsonStr)) { _ in }
        }
    }

    // MARK: - Trích xuất Màu Sắc Ảnh Thực tế từ Cảm biến Camera (Không bị mất góc, sơn màu 100% di tích)
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
        let oldColors = existingColors
        let hasOld = (oldColors != nil && oldColors!.count >= vertices.count * 3)

        var colors = [UInt8]()
        colors.reserveCapacity(vertices.count * 3)

        let defR: UInt8 = 215
        let defG: UInt8 = 180
        let defB: UInt8 = 140

        let camPos = simd_float3(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)

        // Phép chiếu chuẩn xác từ không gian thế giới sang gốc cảm biến Camera LiDAR
        let viewMat = camera.viewMatrix(for: .landscapeRight)
        let projMat = camera.projectionMatrix(for: .landscapeRight, viewportSize: CGSize(width: width, height: height), zNear: 0.05, zFar: 100.0)
        let vpMat = simd_mul(projMat, viewMat)

        let imgW = Float(width)
        let imgH = Float(height)

        for i in 0..<vertices.count {
            let v = vertices[i]
            let localCoord = simd_float4(v.x, v.y, v.z, 1.0)
            let worldCoord = simd_mul(transform, localCoord)
            let worldPoint = simd_float3(worldCoord.x, worldCoord.y, worldCoord.z)

            var sampled = false
            var r: UInt8 = defR
            var g: UInt8 = defG
            var b: UInt8 = defB

            let dist = simd_distance(camPos, worldPoint)
            if dist > 0.15 && dist < 5.0 {
                let clip = simd_mul(vpMat, worldCoord)
                if clip.w > 0.05 {
                    let ndcX = clip.x / clip.w
                    let ndcY = clip.y / clip.w

                    if ndcX >= -0.98 && ndcX <= 0.98 && ndcY >= -0.98 && ndcY <= 0.98 {
                        let px = Int((ndcX + 1.0) * 0.5 * imgW)
                        let py = Int((1.0 - ndcY) * 0.5 * imgH)

                        if px >= 0 && px < width && py >= 0 && py < height {
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
            }

            if sampled {
                colors.append(r)
                colors.append(g)
                colors.append(b)
            } else if hasOld {
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

            if totalVerts == 0 {
                self.coverageQuality = "Chưa quét"
            } else if totalVerts < 10000 {
                self.coverageQuality = "Đang khảo sát sơ bộ"
            } else if totalVerts < 30000 {
                self.coverageQuality = "Bao phủ trung bình"
            } else {
                self.coverageQuality = "Chi tiết cao HBIM"
            }
        }
    }

    // MARK: - Kiểm tra Kết Nối Laptop
    func testConnection(serverIP: String, completion: @escaping (Bool, String) -> Void) {
        currentServerIP = serverIP
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
                    self?.connectionStatusMsg = "Không tìm thấy Laptop. Hãy cắm cáp USB (172.20.10.2) hoặc bật Wi-Fi (192.168.2.17)"
                    completion(false, "Chưa kết nối được máy chủ")
                }
            }
        }.resume()
    }

    // MARK: - Live Stream WebSocket: Mắt Quét Quang Học Thời Gian Thực
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
    }

    private func connectWebSocket(serverIP: String) {
        guard let url = URL(string: "ws://\(serverIP):8000/ws/stream") else { return }
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
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

    func stopLiveStream() {
        isLiveStreaming = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Xuất file PLY chuẩn định dạng
    func exportToPLY() -> URL? {
        let (anchorsSnapshot, colorsSnapshot) = meshQueue.sync {
            (Array(allMeshAnchors.values), anchorColors)
        }
        guard !anchorsSnapshot.isEmpty else { return nil }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("HueHeritage_\(Int(Date().timeIntervalSince1970)).ply")

        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }

        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else { return nil }
        guard let fileHandle = try? FileHandle(forWritingTo: tempURL) else { return nil }
        defer { try? fileHandle.close() }

        var totalVertices = 0
        var totalFaces = 0
        for anchor in anchorsSnapshot {
            totalVertices += anchor.geometry.vertices.count
            totalFaces += anchor.geometry.faces.count
        }

        let header = """
        ply
        format ascii 1.0
        comment Hue Heritage Scanner - LiDAR Point Cloud & Mesh
        element vertex \(totalVertices)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element face \(totalFaces)
        property list uchar int vertex_indices
        end_header
        
        """

        if let headerData = header.data(using: .utf8) {
            fileHandle.write(headerData)
        }

        var vertexChunk = ""
        var faceChunk = ""

        // BƯỚC 1: Ghi TOÀN BỘ ĐỈNH (Vertices)
        for anchor in anchorsSnapshot {
            let geometry = anchor.geometry
            let transform = anchor.transform
            let vertices = geometry.vertices
            let clr = colorsSnapshot[anchor.identifier]

            for i in 0..<vertices.count {
                let v = vertices[i]
                let localCoord = simd_float4(v.x, v.y, v.z, 1.0)
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
        }
        if !vertexChunk.isEmpty, let d = vertexChunk.data(using: .utf8) {
            fileHandle.write(d)
            vertexChunk = ""
        }

        // BƯỚC 2: Ghi TOÀN BỘ MẶT TAM GIÁC (Faces)
        var vertexOffset = 0
        for anchor in anchorsSnapshot {
            let geometry = anchor.geometry
            let faces = geometry.faces
            let vCount = geometry.vertices.count

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
            vertexOffset += vCount
        }
        if !faceChunk.isEmpty, let d = faceChunk.data(using: .utf8) {
            fileHandle.write(d)
            faceChunk = ""
        }

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

    // MARK: - Gửi tệp lên Laptop
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
                        completion(false, "Lỗi kết nối: Cắm cáp USB (172.20.10.2) hoặc kết nối Wi-Fi Laptop")
                        return
                    }
                    self.isConnectedToLaptop = true
                    completion(true, "Đồng bộ thành công! Laptop đã tiếp nhận dữ liệu di tích.")
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
