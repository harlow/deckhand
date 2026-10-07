import Foundation

/// Gradient-boosted regression trees exported from scikit-learn's HistGradientBoosting models.
///
/// Binary layout (little-endian): i32 tree count, f64 baseline, then per tree: i32 node count and
/// nodes of <f32 threshold-or-leaf-value, i32 feature (-1 = leaf), i32 left, i32 right>.
/// A sample goes left when `x[feature] <= threshold`.
struct TreeEnsemble: Sendable {
    private struct Node: Sendable {
        let value: Float
        let feature: Int32
        let left: Int32
        let right: Int32
    }

    private let baseline: Double
    private let trees: [[Node]]

    init?(base64: String) {
        guard let data = Data(base64Encoded: base64) else { return nil }
        var offset = 0
        func read<T>(_: T.Type) -> T? {
            guard offset + MemoryLayout<T>.size <= data.count else { return nil }
            defer { offset += MemoryLayout<T>.size }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        }
        guard let count = read(Int32.self), let base = read(Double.self) else { return nil }
        var trees: [[Node]] = []
        for _ in 0..<count {
            guard let n = read(Int32.self) else { return nil }
            var nodes: [Node] = []
            nodes.reserveCapacity(Int(n))
            for _ in 0..<n {
                guard let v = read(Float.self), let f = read(Int32.self), let l = read(Int32.self), let r = read(Int32.self) else { return nil }
                nodes.append(Node(value: v, feature: f, left: l, right: r))
            }
            trees.append(nodes)
        }
        baseline = base
        self.trees = trees
    }

    /// Sum of leaf values plus baseline (log-odds for classifiers, the prediction for regressors).
    func raw(_ x: [Double]) -> Double {
        var sum = baseline
        for nodes in trees {
            var i = 0
            while nodes[i].feature >= 0 {
                let n = nodes[i]
                i = Int(x[Int(n.feature)] <= Double(n.value) ? n.left : n.right)
            }
            sum += Double(nodes[i].value)
        }
        return sum
    }

    func probability(_ x: [Double]) -> Double {
        1 / (1 + exp(-raw(x)))
    }
}
