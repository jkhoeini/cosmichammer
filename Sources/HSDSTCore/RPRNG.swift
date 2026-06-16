// xoshiro256** PRNG with SplitMix64 seeding — deterministic from a single Int64 seed.

public struct RPRNG {
    private var s: (UInt64, UInt64, UInt64, UInt64)

    public init(seed: Int64) {
        var sm = SplitMix64(state: UInt64(bitPattern: seed))
        s = (sm.next(), sm.next(), sm.next(), sm.next())
    }

    private init(raw s: (UInt64, UInt64, UInt64, UInt64)) {
        self.s = s
    }

    @discardableResult
    public mutating func next() -> UInt64 {
        let result = rotl(s.1 &* 5, 7) &* 9
        let t = s.1 << 17
        s.2 ^= s.0
        s.3 ^= s.1
        s.1 ^= s.2
        s.0 ^= s.3
        s.2 ^= t
        s.3 = rotl(s.3, 45)
        return result
    }

    public mutating func fork() -> RPRNG {
        RPRNG(raw: (next(), next(), next(), next()))
    }

    public mutating func boolean(probability: Double) -> Bool {
        guard probability > 0 else { return false }
        guard probability < 1 else { return true }
        let threshold = UInt64(probability * Double(UInt64.max))
        return next() < threshold
    }

    public mutating func uniform(below n: UInt64) -> UInt64 {
        precondition(n > 0)
        var x = next()
        var m = x.multipliedFullWidth(by: n)
        if m.low < n {
            let t = (0 &- n) % n
            while m.low < t {
                x = next()
                m = x.multipliedFullWidth(by: n)
            }
        }
        return m.high
    }

    public mutating func uniformInt(below n: Int) -> Int {
        Int(uniform(below: UInt64(n)))
    }

    public mutating func uniformDouble() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    public mutating func pick<C: RandomAccessCollection>(from collection: C) -> C.Element {
        precondition(!collection.isEmpty)
        let idx = uniformInt(below: collection.count)
        return collection[collection.index(collection.startIndex, offsetBy: idx)]
    }
}

private func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
    (x << k) | (x >> (64 - k))
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
