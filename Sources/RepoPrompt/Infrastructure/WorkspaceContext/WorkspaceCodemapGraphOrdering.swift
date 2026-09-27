import Darwin
import Foundation

/// Canonical orderings shared by the root-local graph ledger and the selection graph.
///
/// Both orderings are byte-for-byte equivalent to the historical definitions
/// (`String.utf8.lexicographicallyPrecedes` and `UUID.uuidString` comparison) but avoid generic
/// UTF-8 view iteration and the `uuidString` allocation, which dominated graph-index profiles.
enum WorkspaceCodemapGraphOrdering {
    /// Unsigned byte-wise lexicographic order of the UTF-8 encodings. Shorter prefixes precede.
    @inline(__always)
    static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        let fastResult: Bool?? = lhs.utf8.withContiguousStorageIfAvailable { left in
            rhs.utf8.withContiguousStorageIfAvailable { right in
                bytesPrecede(UnsafeRawBufferPointer(left), UnsafeRawBufferPointer(right))
            }
        }
        if let outer = fastResult, let result = outer { return result }
        return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    /// Equivalent to `lhs.uuidString < rhs.uuidString`: the canonical string is fixed-width
    /// uppercase hexadecimal with dashes at fixed offsets, so its order is the raw byte order.
    @inline(__always)
    static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        withUnsafeBytes(of: lhs.uuid) { left in
            withUnsafeBytes(of: rhs.uuid) { right in
                memcmp(left.baseAddress!, right.baseAddress!, 16) < 0
            }
        }
    }

    @inline(__always)
    private static func bytesPrecede(_ lhs: UnsafeRawBufferPointer, _ rhs: UnsafeRawBufferPointer) -> Bool {
        let common = Swift.min(lhs.count, rhs.count)
        if common > 0, let left = lhs.baseAddress, let right = rhs.baseAddress {
            let comparison = memcmp(left, right, common)
            if comparison != 0 { return comparison < 0 }
        }
        return lhs.count < rhs.count
    }

    /// Removes `items` from the strictly sorted `sorted` array, preserving the order.
    ///
    /// `precedes` must be the order `sorted` was built with. Small removals binary-search each
    /// item (`O(m log n)` comparisons); large ones use a single filtering pass. Returns the
    /// comparisons performed and the elements scanned linearly.
    @discardableResult
    static func removeSorted<Element: Hashable>(
        from sorted: inout [Element],
        removing items: some Collection<Element>,
        by precedes: (Element, Element) -> Bool
    ) -> (comparisons: Int, scanned: Int) {
        guard !items.isEmpty, !sorted.isEmpty else { return (0, 0) }
        if items.count >= Swift.max(8, sorted.count / 8) {
            let removed = Set(items)
            let scanned = sorted.count
            sorted.removeAll { removed.contains($0) }
            return (0, scanned)
        }
        var comparisons = 0
        var scanned = 0
        for item in items {
            var low = sorted.startIndex
            var high = sorted.endIndex
            while low < high {
                let middle = low + (high - low) / 2
                comparisons += 1
                if precedes(sorted[middle], item) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low < sorted.endIndex, sorted[low] == item {
                sorted.remove(at: low)
                continue
            }
            // Defensive: tolerate a list that is not ordered by `precedes`.
            scanned += sorted.count
            if let index = sorted.firstIndex(of: item) {
                sorted.remove(at: index)
            }
        }
        return (comparisons, scanned)
    }

    /// Inserts `items` into the already strictly sorted `sorted` array, preserving the order.
    ///
    /// Requires `precedes` to be a strict total order over all elements and `items` to contain no
    /// element equal to an existing one. Performs `O(m log m + m log n)` comparisons and a single
    /// linear copy, instead of re-sorting the whole array. Returns the number of comparisons.
    @discardableResult
    static func mergeSortedInsertion<Element>(
        into sorted: inout [Element],
        inserting items: [Element],
        by precedes: (Element, Element) -> Bool
    ) -> Int {
        guard !items.isEmpty else { return 0 }
        var comparisons = 0
        let orderedItems = items.count == 1 ? items : items.sorted { lhs, rhs in
            comparisons += 1
            return precedes(lhs, rhs)
        }
        if sorted.isEmpty {
            sorted = orderedItems
            return comparisons
        }
        var merged: [Element] = []
        merged.reserveCapacity(sorted.count + orderedItems.count)
        var lowerBound = sorted.startIndex
        for item in orderedItems {
            // First index in `lowerBound...` whose element must follow `item`.
            var low = lowerBound
            var high = sorted.endIndex
            while low < high {
                let middle = low + (high - low) / 2
                comparisons += 1
                if precedes(item, sorted[middle]) {
                    high = middle
                } else {
                    low = middle + 1
                }
            }
            merged.append(contentsOf: sorted[lowerBound ..< low])
            merged.append(item)
            lowerBound = low
        }
        merged.append(contentsOf: sorted[lowerBound...])
        sorted = merged
        return comparisons
    }
}
