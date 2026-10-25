// Ported from rmscene's crdt_sequence.py
// (https://github.com/ricklupton/rmscene, v0.8.0).
// rmscene is Copyright (c) 2023 Rick Lupton and is MIT licensed;
// see LICENSE-rmscene in this directory.

public struct CrdtSequenceItem<T> {
    public var itemId: CrdtId
    public var leftId: CrdtId
    public var rightId: CrdtId
    public var deletedLength: UInt32
    public var value: T

    public init(_ itemId: CrdtId, _ leftId: CrdtId, _ rightId: CrdtId, _ deletedLength: UInt32, _ value: T) {
        self.itemId = itemId
        self.leftId = leftId
        self.rightId = rightId
        self.deletedLength = deletedLength
        self.value = value
    }
}

/// Ordered CRDT sequence container.
///
/// The sequence contains `CrdtSequenceItem`s, each of which has an ID and
/// left and right IDs establishing a partial order.
/// Storage keeps insertion order, like the Python `dict` it ports.
public struct CrdtSequence<T> {
    private var order: [CrdtId] = []
    private var storage: [CrdtId: CrdtSequenceItem<T>] = [:]

    public init() {}

    /// Later items with the same ID replace earlier ones, as in rmscene.
    public init<S: Sequence>(_ items: S) where S.Element == CrdtSequenceItem<T> {
        for item in items {
            if storage.updateValue(item, forKey: item.itemId) == nil {
                order.append(item.itemId)
            }
        }
    }

    /// IDs in order.
    public func keys() throws -> [CrdtId] {
        try toposortItems(order.map { storage[$0]! })
    }

    /// Values in order.
    public func values() throws -> [T] {
        try keys().map { storage[$0]!.value }
    }

    /// Key and value pairs in order.
    public func items() throws -> [(CrdtId, T)] {
        try keys().map { ($0, storage[$0]!.value) }
    }

    public subscript(key: CrdtId) -> T? { storage[key]?.value }

    /// The stored items, in insertion order.
    public func sequenceItems() -> [CrdtSequenceItem<T>] {
        order.map { storage[$0]! }
    }

    public mutating func add(_ item: CrdtSequenceItem<T>) throws {
        if storage[item.itemId] != nil {
            throw RMSceneError.value("Already have item \(item.itemId)")
        }
        storage[item.itemId] = item
        order.append(item.itemId)
    }
}

public let endMarker = CrdtId(0, 0)

private enum Node: Hashable {
    case start
    case item(CrdtId)
    case end

    /// The reMarkable places higher author IDs first
    /// among concurrent inserts at the same position.
    var sortKey: (UInt64, Int64, UInt64) {
        switch self {
        case .start: (0, 0, 0)
        case .end: (2, 0, 0)
        case .item(let id): (1, -Int64(id.part1), id.part2)
        }
    }
}

/// Sort sequence items based on left and right IDs, and return the IDs in order.
///
/// This uses Kahn's algorithm with a heap,
/// so that items that become ready together come out in a fixed order.
func toposortItems<T>(_ items: [CrdtSequenceItem<T>]) throws -> [CrdtId] {
    var itemDict: [CrdtId: CrdtSequenceItem<T>] = [:]
    for item in items { itemDict[item.itemId] = item }
    if itemDict.isEmpty { return [] }

    func sideNode(_ id: CrdtId, left: Bool) -> Node {
        if id == endMarker || itemDict[id] == nil {
            return left ? .start : .end
        }
        return .item(id)
    }

    var inDegree: [Node: Int] = [.start: 0, .end: 0]
    var dependents: [Node: [Node]] = [:]
    for item in itemDict.values {
        let node = Node.item(item.itemId)
        let leftNode = sideNode(item.leftId, left: true)
        let rightNode = sideNode(item.rightId, left: false)
        inDegree[node, default: 0] += 1
        dependents[leftNode, default: []].append(node)
        inDegree[rightNode, default: 0] += 1
        dependents[node, default: []].append(rightNode)
        inDegree[leftNode, default: 0] += 0
    }

    var ready = Heap<Node> { $0.sortKey < $1.sortKey }
    for (node, degree) in inDegree where degree == 0 {
        ready.push(node)
    }

    var result: [CrdtId] = []
    while let node = ready.pop() {
        if case .item(let id) = node { result.append(id) }
        if node == .end { break }
        for dependent in dependents[node] ?? [] {
            inDegree[dependent]! -= 1
            if inDegree[dependent] == 0 { ready.push(dependent) }
        }
    }

    if inDegree.contains(where: { $0.value > 0 && $0.key != .end }) {
        throw RMSceneError.value("cyclic dependency")
    }
    return result
}

/// A binary min-heap, standing in for Python's `heapq`.
struct Heap<Element> {
    private var elements: [Element] = []
    private let less: (Element, Element) -> Bool

    init(less: @escaping (Element, Element) -> Bool) { self.less = less }

    mutating func push(_ element: Element) {
        elements.append(element)
        var i = elements.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard less(elements[i], elements[parent]) else { break }
            elements.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> Element? {
        guard !elements.isEmpty else { return nil }
        elements.swapAt(0, elements.count - 1)
        let top = elements.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < elements.count, less(elements[l], elements[m]) { m = l }
            if r < elements.count, less(elements[r], elements[m]) { m = r }
            if m == i { break }
            elements.swapAt(i, m)
            i = m
        }
        return top
    }
}
