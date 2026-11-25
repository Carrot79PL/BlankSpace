import Foundation
import Metal

private let mslSource = """
#include <metal_stdlib>
using namespace metal;
inline ulong mix64(ulong z) {
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ul;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBul;
    return z ^ (z >> 31);
}
// Każdy wątek generuje 16 bajtów: deterministyczny strumień zależny od (seed, chunk, gid).
kernel void fillRandom(device ulong2 *out [[buffer(0)]],
                       constant ulong2 &p [[buffer(1)]],
                       uint gid [[thread_position_in_grid]],
                       uint count [[threads_per_grid]]) {
    ulong i = p.y * (ulong)count + (ulong)gid;
    ulong a = mix64(p.x + (2ul * i) * 0x9E3779B97F4A7C15ul);
    ulong b = mix64(p.x + (2ul * i + 1ul) * 0x9E3779B97F4A7C15ul);
    out[gid] = ulong2(a, b);
}
"""

@inline(__always) private func mix64(_ x: UInt64) -> UInt64 {
    var z = x
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
}

/// Generator bloków danych (16 MB): GPU (Metal) z awaryjnym fallbackiem na CPU.
final class ChunkGen {
    static let size = 16 << 20
    private let queue: MTLCommandQueue?
    private let pso: MTLComputePipelineState?
    private var mtlBufs: [MTLBuffer] = []
    private var cpuBufs: [UnsafeMutableRawPointer] = []
    let usesGPU: Bool

    init() {
        var q: MTLCommandQueue?, p: MTLComputePipelineState?
        var bufs: [MTLBuffer] = []
        if let dev = MTLCreateSystemDefaultDevice(),
           let lib = try? dev.makeLibrary(source: mslSource, options: nil),
           let fn = lib.makeFunction(name: "fillRandom"),
           let st = try? dev.makeComputePipelineState(function: fn),
           let cq = dev.makeCommandQueue() {
            let b0 = dev.makeBuffer(length: Self.size, options: .storageModeShared)
            let b1 = dev.makeBuffer(length: Self.size, options: .storageModeShared)
            if let b0, let b1 { bufs = [b0, b1]; q = cq; p = st }
        }
        queue = q; pso = p; mtlBufs = bufs
        usesGPU = !bufs.isEmpty
        if !usesGPU {
            for _ in 0..<2 {
                var m: UnsafeMutableRawPointer?
                posix_memalign(&m, 16384, Self.size)
                cpuBufs.append(m!)
            }
        }
    }

    deinit { cpuBufs.forEach { free($0) } }

    func ptr(_ slot: Int) -> UnsafeMutableRawPointer {
        usesGPU ? mtlBufs[slot].contents() : cpuBufs[slot]
    }

    func fillPattern(_ b: UInt8) { memset(ptr(0), Int32(b), Self.size) }

    /// Przygotowuje bufor dla przebiegu; zwraca true, gdy dane są losowe (generowane per blok).
    func prepare(_ kind: PassKind) -> Bool {
        switch kind {
        case .random: return true
        case .byte(let b): fillPattern(b); return false
        case .pattern(let a):
            let base = ptr(0).bindMemory(to: UInt8.self, capacity: Self.size)
            for i in 0..<Self.size { base[i] = a[i % a.count] }   // wzorzec zaczyna się od początku każdego bloku 16 MB
            return false
        }
    }

    /// Zleca generowanie bloku `chunk` do bufora `slot`. Zwraca command buffer do poczekania (nil = gotowe).
    func produce(seed: UInt64, chunk: UInt64, slot: Int) -> MTLCommandBuffer? {
        let n = Self.size / 16
        if usesGPU, let queue, let pso,
           let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pso)
            enc.setBuffer(mtlBufs[slot], offset: 0, index: 0)
            var params = SIMD2<UInt64>(seed, chunk)
            enc.setBytes(&params, length: MemoryLayout<SIMD2<UInt64>>.size, index: 1)
            let tg = min(pso.maxTotalThreadsPerThreadgroup, 256)
            enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tg, height: 1, depth: 1))
            enc.endEncoding()
            cb.commit()
            return cb
        }
        let p = ptr(slot).bindMemory(to: UInt64.self, capacity: Self.size / 8)
        let G: UInt64 = 0x9E3779B97F4A7C15
        let base = chunk &* UInt64(n)
        for g in 0..<n {
            let i = base &+ UInt64(g)
            p[2 * g] = mix64(seed &+ (2 &* i) &* G)
            p[2 * g + 1] = mix64(seed &+ (2 &* i &+ 1) &* G)
        }
        return nil
    }
}
