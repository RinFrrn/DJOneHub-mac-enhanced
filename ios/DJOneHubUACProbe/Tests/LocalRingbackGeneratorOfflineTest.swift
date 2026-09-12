import Foundation

@main
struct LocalRingbackGeneratorOfflineTest {
    static func main() {
        var generator = LocalRingbackGenerator()
        let silence = Data(repeating: 0, count: 256)
        let firstTone = generator.process(silence)
        precondition(peak(firstTone) > 3_000)

        let inBandSamples = [Int16](repeating: 1_000, count: 128)
        let inBand = inBandSamples.withUnsafeBytes { Data($0) }
        precondition(generator.process(inBand) == inBand)
        precondition(generator.process(silence) == silence)

        generator.reset()
        for _ in 0 ..< ((LocalRingbackGenerator.toneSamples + 127) / 128) {
            _ = generator.process(silence)
        }
        precondition(generator.process(silence) == silence)
        print("LocalRingbackGeneratorOfflineTest: PASS")
    }

    private static func peak(_ pcm: Data) -> Int32 {
        pcm.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Int16.self).reduce(into: Int32(0)) { result, sample in
                result = max(result, abs(Int32(Int16(littleEndian: sample))))
            }
        }
    }
}
