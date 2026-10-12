import Foundation

// MARK: - Finding many strings at once
//
// Aho–Corasick over UTF-16 code units (the units NSString ranges count in). The shield collects every sensitive
// value in a request and then has to find each of them wherever else it appears — thousands of them when a CSV of
// contacts is attached — so the search is one pass over the text whatever the number of values: building the
// matcher is linear in the values' total length, and a search is linear in the text (plus the matches).

struct LiteralMatcher: Sendable {
    /// One occurrence: where it is (UTF-16) and which string.
    struct Occurrence: Equatable {
        var location: Int
        var length: Int
        var pattern: Int
    }

    /// The strings looked for, by index.
    let patterns: [String]
    private let lengths: [Int]
    // The trie. The root's transitions are a direct table (most of a search is spent there); the others live in an
    // open-addressing hash keyed by node << 16 | unit.
    private let rootNext: [Int32]
    private let keys: [Int]
    private let targets: [Int32]
    private let slotMask: Int
    /// Where to continue when a node has no transition for the next unit: the longest proper suffix in the trie.
    private let fail: [Int32]
    /// The string that ends at a node (-1 when none).
    private let output: [Int32]
    /// The nearest node down the fail chain where a string ends (0 when none).
    private let nextOutput: [Int32]

    init(_ patterns: [String]) {
        self.patterns = patterns
        let units = patterns.map { Array($0.utf16) }
        lengths = units.map(\.count)
        let total = units.reduce(0) { $0 + $1.count }

        var rootNext = [Int32](repeating: 0, count: 65_536)
        let capacity = Swift.max(16, Int(1) << (Int.bitWidth - (Swift.max(total, 1) * 2).leadingZeroBitCount))
        var keys = [Int](repeating: -1, count: capacity)
        var targets = [Int32](repeating: 0, count: capacity)
        let slotMask = capacity - 1
        var parent: [Int32] = [0], unitIn: [UInt16] = [0], depth: [Int32] = [0], output: [Int32] = [-1]
        parent.reserveCapacity(total + 1); unitIn.reserveCapacity(total + 1)
        depth.reserveCapacity(total + 1); output.reserveCapacity(total + 1)

        for (index, pattern) in units.enumerated() where !pattern.isEmpty {
            var node: Int32 = 0
            for unit in pattern {
                if node == 0 {
                    if rootNext[Int(unit)] == 0 {
                        rootNext[Int(unit)] = Int32(parent.count)
                        parent.append(0); unitIn.append(unit); depth.append(1); output.append(-1)
                    }
                    node = rootNext[Int(unit)]
                    continue
                }
                let key = Int(node) << 16 | Int(unit)
                var slot = Self.hash(key) & slotMask
                while keys[slot] != -1 && keys[slot] != key { slot = (slot + 1) & slotMask }
                if keys[slot] == -1 {
                    keys[slot] = key
                    targets[slot] = Int32(parent.count)
                    parent.append(node); unitIn.append(unit); depth.append(depth[Int(node)] + 1); output.append(-1)
                }
                node = targets[slot]
            }
            if output[Int(node)] == -1 { output[Int(node)] = Int32(index) }
        }

        // Fail links, shallowest nodes first.
        let count = parent.count
        let deepest = Int(depth.max() ?? 0)
        var byDepth = [[Int32]](repeating: [], count: deepest + 1)
        for node in 1..<Swift.max(count, 1) { byDepth[Int(depth[node])].append(Int32(node)) }
        var fail = [Int32](repeating: 0, count: count)
        var nextOutput = [Int32](repeating: 0, count: count)
        func step(_ node: Int32, _ unit: UInt16) -> Int32? {
            if node == 0 { let next = rootNext[Int(unit)]; return next == 0 ? nil : next }
            let key = Int(node) << 16 | Int(unit)
            var slot = Self.hash(key) & slotMask
            while keys[slot] != -1 {
                if keys[slot] == key { return targets[slot] }
                slot = (slot + 1) & slotMask
            }
            return nil
        }
        for level in byDepth.dropFirst() {
            for node in level {
                let p = parent[Int(node)], unit = unitIn[Int(node)]
                var link: Int32 = 0
                if p != 0 {
                    var f = fail[Int(p)]
                    while true {
                        if let next = step(f, unit) { link = next; break }
                        if f == 0 { break }
                        f = fail[Int(f)]
                    }
                }
                fail[Int(node)] = link
                nextOutput[Int(node)] = output[Int(link)] >= 0 ? link : nextOutput[Int(link)]
            }
        }

        self.rootNext = rootNext
        self.keys = keys
        self.targets = targets
        self.slotMask = slotMask
        self.fail = fail
        self.output = output
        self.nextOutput = nextOutput
    }

    private static func hash(_ key: Int) -> Int {
        Int(truncatingIfNeeded: (UInt64(bitPattern: Int64(key)) &* 0x9E37_79B9_7F4A_7C15) >> 29)
    }

    /// Every occurrence of every string in `text`, overlapping ones included, in order of where they end.
    func occurrences(in text: NSString) -> [Occurrence] {
        let length = text.length
        guard length > 0, !patterns.isEmpty else { return [] }
        var found: [Occurrence] = []
        var buffer = [UInt16](repeating: 0, count: length)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: length))
        buffer.withUnsafeBufferPointer { units in
        rootNext.withUnsafeBufferPointer { rootNext in
        keys.withUnsafeBufferPointer { keys in
        targets.withUnsafeBufferPointer { targets in
        fail.withUnsafeBufferPointer { fail in
        output.withUnsafeBufferPointer { output in
        nextOutput.withUnsafeBufferPointer { nextOutput in
            var state: Int32 = 0
            for i in 0..<length {
                let unit = units[i]
                while true {
                    if state == 0 { state = rootNext[Int(unit)]; break }
                    let key = Int(state) << 16 | Int(unit)
                    var slot = Self.hash(key) & slotMask
                    var next: Int32 = -1
                    while keys[slot] != -1 {
                        if keys[slot] == key { next = targets[slot]; break }
                        slot = (slot + 1) & slotMask
                    }
                    if next >= 0 { state = next; break }
                    state = fail[Int(state)]
                }
                var node = output[Int(state)] >= 0 ? state : nextOutput[Int(state)]
                while node != 0 {
                    let pattern = Int(output[Int(node)])
                    let size = lengths[pattern]
                    found.append(Occurrence(location: i - size + 1, length: size, pattern: pattern))
                    node = nextOutput[Int(node)]
                }
            }
        }}}}}}}
        return found
    }
}
