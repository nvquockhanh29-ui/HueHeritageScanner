import Foundation
import ARKit
import Combine

class ARScannerManager: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isScanning = false
    @Published var vertexCount = 0
    @Published var faceCount = 0
    @Published var statusMessage = "Sẵn sàng quét LiDAR di tích"
    @Published var isUploading = false
    @Published var uploadProgress: Float = 0.0

    var arView: ARSCNView?
    private var anchors: [ARMeshAnchor] = []

    func startSession() {
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) else {
            statusMessage = "Thiết bị không có cảm biến LiDAR!"
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.sceneReconstruction = .meshWithClassification
        configuration.environmentTexturing = .automatic

        arView?.session.delegate = self
        arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isScanning = true
        statusMessage = "Đang quét không gian di tích..."
    }

    func stopSession() {
        arView?.session.pause()
        isScanning = false
        statusMessage = "Đã dừng phiên quét. Sẵn sàng xuất dữ liệu."
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let meshAnchors = anchors.compactMap { $0 as? ARMeshAnchor }
        self.anchors = meshAnchors

        var totalVerts = 0
        var totalFaces = 0
        for anchor in meshAnchors {
            totalVerts += anchor.geometry.vertices.count
            totalFaces += anchor.geometry.faces.count
        }

        DispatchQueue.main.async {
            self.vertexCount = totalVerts
            self.faceCount = totalFaces
        }
    }

    /// Xuất dữ liệu LiDAR ra tệp chuẩn PLY (Point Cloud & Mesh có tọa độ thực tế)
    func exportToPLY() -> URL? {
        guard !anchors.isEmpty else { return nil }

        let fileName = "HueHeritage_\(Int(Date().timeIntervalSince1970)).ply"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        let plyHeader = """
        ply
        format ascii 1.0
        comment Huế Heritage Scanner - R&D 04 Digital Twin
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

        for anchor in anchors {
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
            print("Lỗi ghi tệp PLY: \(error)")
            return nil
        }
    }

    /// Đồng bộ 1 chạm trực tiếp từ iPhone sang Laptop / Server Digital Twin
    func uploadToServer(serverIP: String, completion: @escaping (Bool, String) -> Void) {
        guard let fileURL = exportToPLY() else {
            completion(false, "Không có dữ liệu 3D để gửi")
            return
        }

        isUploading = true
        statusMessage = "Đang đồng bộ trực tiếp sang Laptop..."

        let uploadURL = URL(string: "http://\(serverIP):8000/api/upload")!
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"

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
                self.isUploading = false
                if let error = error {
                    self.statusMessage = "Lỗi kết nối Server: \(error.localizedDescription)"
                    completion(false, error.localizedDescription)
                    return
                }
                self.statusMessage = "✅ Đã đồng bộ sang Server thành công!"
                completion(true, "Thành công!")
            }
        }
        task.resume()
    }
}

private extension ARGeometrySource {
    subscript(index: Int) -> simd_float3 {
        let byteStride = self.stride
        let pointer = buffer.contents().advanced(by: offset + (byteStride * index))
        return pointer.assumingMemoryBound(to: simd_float3.self).pointee
    }
}

private extension ARGeometryElement {
    subscript(faceIndex: Int, vertexIndex: Int) -> Int32 {
        let byteStride = self.stride
        let pointer = buffer.contents().advanced(by: (faceIndex * byteStride) + (vertexIndex * MemoryLayout<Int32>.size))
        return pointer.assumingMemoryBound(to: Int32.self).pointee
    }
}
