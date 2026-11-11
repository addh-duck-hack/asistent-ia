import Foundation

/// Arregla la cabecera de un WAV que no se cerró (la app se cerró a mitad de la
/// grabación): AVAudioFile solo escribe los tamaños al cerrar, y sin ellos los
/// lectores ven 0 segundos aunque el audio esté en el archivo.
enum WAVRepair {
    /// Devuelve true si tuvo que corregir algo.
    @discardableResult
    static func repair(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize > 44 else { return false }
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 65_536) ?? Data()
        guard header.count >= 12, header.prefix(4) == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8) else { return false }

        // Busca el chunk "data" recorriendo los anteriores (fmt, fact, FLLR…).
        var offset = 12
        while offset + 8 <= header.count {
            let id = header[offset..<offset + 4]
            let size = Int(header.uint32(at: offset + 4))
            if id == Data("data".utf8) {
                let dataStart = UInt64(offset + 8)
                let riffSize = UInt32(clamping: fileSize - 8)
                let dataSize = UInt32(clamping: fileSize - dataStart)
                guard header.uint32(at: 4) != riffSize || UInt32(size) != dataSize else { return false }
                try handle.seek(toOffset: 4)
                try handle.write(contentsOf: riffSize.littleEndianData)
                try handle.seek(toOffset: UInt64(offset + 4))
                try handle.write(contentsOf: dataSize.littleEndianData)
                return true
            }
            offset += 8 + size + (size % 2)
        }
        return false
    }
}

private extension Data {
    func uint32(at i: Int) -> UInt32 {
        let b = self[(startIndex + i)..<(startIndex + i + 4)].map(UInt32.init)
        return b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24
    }
}

private extension UInt32 {
    var littleEndianData: Data { withUnsafeBytes(of: littleEndian) { Data($0) } }
}
