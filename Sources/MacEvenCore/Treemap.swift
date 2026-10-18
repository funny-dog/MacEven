import Foundation
import CoreGraphics

public struct TreemapWeight: Sendable, Equatable {
    public let id: Int64
    public let allocatedSize: Int64

    public init(id: Int64, allocatedSize: Int64) {
        self.id = id
        self.allocatedSize = allocatedSize
    }
}

public struct TreemapRect: Sendable, Equatable {
    public let id: Int64
    public let rect: CGRect

    public init(id: Int64, rect: CGRect) {
        self.id = id
        self.rect = rect
    }
}

public struct TreemapSnapshot: Sendable {
    public let entries: [DiskEntry]
    public let totalCount: Int64
    public let totalAllocatedSize: Int64
    public let totalLogicalSize: Int64
    public let otherCount: Int64
    public let otherAllocatedSize: Int64
    public let otherLogicalSize: Int64
    public let invalidSizeCount: Int64
    public let zeroAllocatedCount: Int64
    public var weights: [TreemapWeight] {
        var values = entries.filter { $0.allocatedSize > 0 && $0.logicalSize >= 0 }
            .map { TreemapWeight(id: $0.id, allocatedSize: $0.allocatedSize) }
        if otherAllocatedSize > 0 { values.append(TreemapWeight(id: 0, allocatedSize: otherAllocatedSize)) }
        return values
    }
}

public enum TreemapLayout {
    public static func rectangles(weights: [TreemapWeight], width: Double, height: Double) -> [TreemapRect] {
        guard !width.isNaN, !height.isNaN,
              !width.isInfinite, !height.isInfinite,
              width > 0, height > 0 else {
            return []
        }

        var validWeights: [TreemapWeight] = []
        var seenIDs = Set<Int64>()

        for w in weights {
            guard w.allocatedSize > 0 else { continue }
            guard !seenIDs.contains(w.id) else { continue }
            seenIDs.insert(w.id)
            validWeights.append(w)
        }

        guard !validWeights.isEmpty else {
            return []
        }

        var results: [TreemapRect] = []
        results.reserveCapacity(validWeights.count)

        let initialRect = CGRect(x: 0, y: 0, width: width, height: height)
        partition(
            items: validWeights[...],
            rect: initialRect,
            results: &results
        )

        return results
    }

    private static func partition(
        items: ArraySlice<TreemapWeight>,
        rect: CGRect,
        results: inout [TreemapRect]
    ) {
        guard !items.isEmpty else { return }
        if items.count == 1 {
            let item = items.first!
            results.append(TreemapRect(id: item.id, rect: rect))
            return
        }

        var totalSliceWeight: Double = 0
        for item in items {
            totalSliceWeight += Double(item.allocatedSize)
        }

        guard totalSliceWeight > 0 else {
            for item in items {
                results.append(TreemapRect(id: item.id, rect: .zero))
            }
            return
        }

        let halfWeight = totalSliceWeight * 0.5
        var currentSum: Double = 0
        var bestIndex = items.startIndex + 1
        var minDiff = Double.greatestFiniteMagnitude
        var bestLeftWeight = Double(items.first!.allocatedSize)

        for idx in items.startIndex ..< items.endIndex - 1 {
            currentSum += Double(items[idx].allocatedSize)
            let diff = abs(currentSum - halfWeight)
            if diff < minDiff {
                minDiff = diff
                bestIndex = idx + 1
                bestLeftWeight = currentSum
            }
        }

        let leftSlice = items[items.startIndex ..< bestIndex]
        let rightSlice = items[bestIndex ..< items.endIndex]

        let rawRatio = bestLeftWeight / totalSliceWeight
        let ratio = max(0, min(1, rawRatio))

        let leftRect: CGRect
        let rightRect: CGRect

        if rect.width >= rect.height {
            let leftW = rect.width * ratio
            let rightW = rect.width - leftW
            leftRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: leftW, height: rect.height)
            rightRect = CGRect(x: rect.origin.x + leftW, y: rect.origin.y, width: rightW, height: rect.height)
        } else {
            let topH = rect.height * ratio
            let bottomH = rect.height - topH
            leftRect = CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: topH)
            rightRect = CGRect(x: rect.origin.x, y: rect.origin.y + topH, width: rect.width, height: bottomH)
        }

        partition(items: leftSlice, rect: leftRect, results: &results)
        partition(items: rightSlice, rect: rightRect, results: &results)
    }
}
