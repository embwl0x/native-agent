import Accelerate
import HashTreeCollections

// Blueprint: | `VectorMatrix.swift` | `VectorMatrix`: snapshot vectors, batched cosines and eligible population pull |

package struct VectorReading: Sendable, Equatable {
    let unit: [Float]

    package init?(_ values: [Float]) {
        guard !values.isEmpty else { return nil }
        var wide = vDSP.floatToDouble(values)
        let norm = vDSP.sumOfSquares(wide).squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        cblas_dscal(Int32(values.count), 1 / norm, &wide, 1)
        unit = vDSP.doubleToFloat(wide)
    }

    package var width: Int { unit.count }
}

// The immutable aligned buffer retains its native pointer until the last reader releases it.
@safe private final class AlignedRows: @unchecked Sendable, Equatable {
    let values: UnsafeBufferPointer<Float>

    init(count: Int, fill: (UnsafeMutableBufferPointer<Float>) -> Void) {
        let storage = unsafe UnsafeMutableRawPointer.allocate(byteCount: max(1, count) * MemoryLayout<Float>.stride, alignment: 64)
        let base = unsafe storage.bindMemory(to: Float.self, capacity: max(1, count))
        let buffer = unsafe UnsafeMutableBufferPointer(start: base, count: count)
        unsafe buffer.initialize(repeating: 0)
        unsafe fill(buffer)
        values = unsafe UnsafeBufferPointer(buffer)
    }

    deinit { unsafe UnsafeMutableRawPointer(mutating: values.baseAddress!).deallocate() }

    static func == (lhs: AlignedRows, rhs: AlignedRows) -> Bool {
        unsafe lhs === rhs || lhs.values.elementsEqual(rhs.values)
    }
}

package struct VectorMatrix<ID: Hashable & Sendable>: Sendable, Equatable {
    private struct Page: Equatable, Sendable {
        let ids: [ID]
        let units: AlignedRows

        func setting(_ id: ID, at i: Int, unit: UnsafeBufferPointer<Float>) -> Page {
            var ids = self.ids
            if i == ids.count { ids.append(id) } else { ids[i] = id }
            let width = unit.count
            let updated = unsafe AlignedRows(count: ids.count * width) { output in
                let base = unsafe output.baseAddress!
                unsafe base.update(from: units.values.baseAddress!, count: self.ids.count * width)
                unsafe base.advanced(by: i * width).update(from: unit.baseAddress!, count: width)
            }
            return Page(ids: ids, units: updated)
        }

        func addUnit(at i: Int, width: Int, scale: Float, to sum: inout [Float]) {
            if !sum.isEmpty {
                unsafe cblas_saxpy(Int32(width), scale, units.values.baseAddress! + i * width, 1, &sum, 1)
            }
        }

        func droppingLast(width: Int) -> Page? {
            guard ids.count > 1 else { return nil }
            let kept = unsafe AlignedRows(count: (ids.count - 1) * width) { output in
                unsafe output.baseAddress!.update(from: units.values.baseAddress!, count: output.count)
            }
            return Page(ids: Array(ids.dropLast()), units: kept)
        }

        init(_ rows: ArraySlice<(ID, VectorReading)>, width: Int) {
            ids = rows.map { $0.0 }
            units = unsafe AlignedRows(count: rows.count * width) { output in
                for (i, row) in rows.enumerated() {
                    row.1.unit.withUnsafeBufferPointer {
                        precondition($0.count == width)
                        unsafe (output.baseAddress! + i * width).update(from: $0.baseAddress!, count: width)
                    }
                }
            }
        }

        private init(ids: [ID], units: AlignedRows) {
            self.ids = ids
            self.units = units
        }
    }

    package private(set) var index: TreeDictionary<ID, Int>
    private var pages: TreeDictionary<Int, Page>
    private let width: Int
    private var fullSum: [Float]
    private let capacity: Int
    package var count: Int { index.count }

    package func id(at row: Int) -> ID {
        pages[row / capacity]!.ids[row % capacity]
    }

    package static func grouped(_ rows: [(ID, VectorReading)], centering: Bool) -> [Int: Self] {
        Dictionary(grouping: rows, by: { $0.1.width }).mapValues {
            Self($0, width: $0[0].1.width, centering: centering)
        }
    }

    package init(_ rows: [(ID, VectorReading)], width: Int, centering: Bool) {
        self.width = width
        fullSum = centering ? [Float](repeating: 0, count: width) : []
        capacity = centering ? 32 : max(1, rows.count)
        index = TreeDictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.0, $0) })
        pages = [:]
        for start in stride(from: 0, to: rows.count, by: capacity) {
            let stored = Page(rows[start..<min(rows.count, start + capacity)], width: width)
            pages[start / capacity] = stored
            if centering {
                for i in stored.ids.indices { stored.addUnit(at: i, width: width, scale: 1, to: &fullSum) }
            }
        }
    }

    package mutating func set(_ reading: VectorReading, for id: ID) {
        precondition(reading.width == width)
        let position = index[id] ?? count
        let page = position / capacity
        let i = position % capacity
        if let old = pages[page] {
            if i < old.ids.count {
                let previous = unsafe UnsafeBufferPointer(rebasing: old.units.values[(i * width)..<((i + 1) * width)])
                if unsafe previous.elementsEqual(reading.unit) { return }
                old.addUnit(at: i, width: width, scale: -1, to: &fullSum)
            }
            pages[page] = reading.unit.withUnsafeBufferPointer { unsafe old.setting(id, at: i, unit: $0) }
        } else {
            pages[page] = Page([(id, reading)], width: width)
        }
        pages[page]!.addUnit(at: i, width: width, scale: 1, to: &fullSum)
        index[id] = position
    }

    package mutating func remove(_ id: ID) {
        guard let position = index.removeValue(forKey: id) else { return }
        let last = count
        let page = position / capacity, i = position % capacity
        pages[page]!.addUnit(at: i, width: width, scale: -1, to: &fullSum)
        let tail = pages[last / capacity]!
        if position != last {
            let moved = tail.ids[last % capacity]
            let unit = unsafe UnsafeBufferPointer(start: tail.units.values.baseAddress! + last % capacity * width, count: width)
            pages[page] = unsafe pages[page]!.setting(moved, at: i, unit: unit)
            index[moved] = position
        }
        pages[last / capacity] = pages[last / capacity]!.droppingLast(width: width)
    }

    package struct Scores {
        package let cosines: [[Double]]
        package let pull: [Double]
    }

    package func score(_ readings: [VectorReading], population: [Int] = []) -> Scores {
        precondition(readings.allSatisfy { $0.width == width })
        let relative = population.count >= 3 && !readings.isEmpty
        precondition(!relative || (!fullSum.isEmpty && population.count <= count && population.allSatisfy((0..<count).contains)))
        guard !readings.isEmpty, count > 0 else {
            return Scores(cosines: readings.map { _ in [] }, pull: [])
        }
        var queries = readings.flatMap(\.unit)
        if relative {
            var sum = fullSum
            if population.count < count {
                let included = Set(population)
                var excludedSum = [Float](repeating: 0, count: width)
                for pageIndex in 0..<pages.count {
                    let page = pages[pageIndex]!
                    for i in page.ids.indices where !included.contains(pageIndex * capacity + i) {
                        page.addUnit(at: i, width: width, scale: 1, to: &excludedSum)
                    }
                }
                vDSP.subtract(fullSum, excludedSum, result: &sum)
            }
            queries.append(contentsOf: sum)
        }
        let queryCount = readings.count + (relative ? 1 : 0)
        var products = [Float](repeating: 0, count: queryCount * count)
        products.withUnsafeMutableBufferPointer { output in
            for (pageIndex, page) in pages {
                unsafe cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(queryCount), Int32(page.ids.count), Int32(width),
                            1, queries, Int32(width), page.units.values.baseAddress!, Int32(width),
                            0, output.baseAddress! + pageIndex * capacity, Int32(count))
            }
        }
        let cosines = readings.indices.map { products[($0 * count)..<(($0 + 1) * count)].map(Double.init) }
        let pull = relative ? population.map { (Double(products[readings.count * count + $0]) - 1) / Double(population.count - 1) } : []
        return Scores(cosines: cosines, pull: pull)
    }
}
