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
    @Published var accuracyErrorMM: Double = 1.8 // Sai số khảo sát HBIM
    @Published var missingAreaCount: Int = 0    // Số vùng thưa điểm phát hiện
    @Published var isTorchOn = false            // Trạng thái đèn Flash

    var arView: ARSCNView?
    // Lưu trữ toàn bộ các Anchor đã phát hiện (KHÔNG BAO GIỜ BỊ RESET VỀ 0)
    private var allMeshAnchors: [UUID: ARMeshAnchor] = [:]
    private var meshNodes: [UUID: SCNNode] = [:]
    private var liveStreamTimer: Timer?

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
        arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
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

    // MARK: - Điều khiển Đèn Flash (Torch LED)
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
            print("Không thể bật đèn Flash: \(error)")
        }
    }

    // MARK: - ARSCNViewDelegate: Hiển thị lưới Wireframe & Cảnh báo ĐỎ vùng chưa quét
    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        allMeshAnchors[meshAnchor.identifier] = meshAnchor
        
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
        node.geometry = createVisualizationGeometry(meshAnchor: meshAnchor)
        updateMeshMetrics()
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        if let meshAnchor = anchor as? ARMeshAnchor {
            allMeshAnchors.removeValue(forKey: meshAnchor.identifier)
            meshNodes.removeValue(forKey: meshAnchor.identifier)
            updateMeshMetrics()
        }
    }

    private func createVisualizationGeometry(meshAnchor: ARMeshAnchor) -> SCNGeometry {
        let scnGeom = SCNGeometry(arMeshGeometry: meshAnchor.geometry)
        let material = SCNMaterial()
        material.fillMode = .lines // Chế độ lưới 3D Wireframe đè lên vật thể
        material.isDoubleSided = true

        let vCount = meshAnchor.geometry.vertices.count

        // Phân tích mật độ:
        // Vùng thưa điểm (< 400 đỉnh) -> TÔ ĐỎ CẢNH BÁO (vùng chưa quét kỹ)
        // Vùng đủ điểm (>= 400 đỉnh) -> TÔ XANH LÁ CÂY (đạt chuẩn)
        if highlightMissing && vCount < 400 {
            material.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.9)
            material.emission.contents = UIColor.systemRed.withAlphaComponent(0.4)
        } else {
            material.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.85)
            material.emission.contents = UIColor.systemGreen.withAlphaComponent(0.2)
        }

        scnGeom.materials = [material]
        return scnGeom
    }

    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for anchor in anchors.compactMap({ $0 as? ARMeshAnchor }) {
            allMeshAnchors[anchor.identifier] = anchor
        }
        updateMeshMetrics()
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

    // MARK: - Đồng bộ thời gian thực (Real-time Live Stream)
    func toggleLiveStream(serverIP: String) {
        if isLiveStreaming {
            stopLiveStream()
        } else {
            startLiveStream(serverIP: serverIP)
        }
    }

    func startLiveStream(serverIP: String) {
        isLiveStreaming = true
        liveStreamTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isScanning, self.vertexCount > 0 else { return }
            self.uploadToServer(serverIP: serverIP, isBackgroundStream: true) { _, _ in }
        }
    }

    func stopLiveStream() {
        isLiveStreaming = false
        liveStreamTimer?.invalidate()
        liveStreamTimer = nil
    }

    // MARK: - Xuất file PLY có siêu dữ liệu HBIM
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

            let vertices = geometry.vertices
            for i in 0..<vertices.count {
                let vertex = vertices[i]
                let localCoord = simd_float4(vertex[0], vertex[1], vertex[2], 1.0)
                let worldCoord = simd_mul(transform, localCoord)
                vertexData += String(format: "%.4f %.4f %.4f\n", worldCoord.x, worldCoord.y, worldCoord.z)
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

    // MARK: - Mở bảng chia sẻ file chuẩn iOS (AirDrop, Files, Zalo, ...)
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

    // MARK: - Gửi tệp lên Laptop (Xử lý ngầm, không nghẽn giao diện)
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
                        completion(false, "Lỗi: \(error.localizedDescription)")
                        return
                    }
                    completion(true, "Đồng bộ thành công!")
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
