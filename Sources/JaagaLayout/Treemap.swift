import CoreGraphics
import Foundation

/// A squarified treemap: rectangles whose areas are proportional to a weight, laid out to be as
/// close to square as possible so the eye can compare them.
///
/// Bruls, Huizing and van Wijk's algorithm, which is what makes the space map readable: strict
/// slice-and-dice would produce slivers that all look the same.
public enum Treemap {
    public struct Tile<Element>: Sendable where Element: Sendable {
        public var element: Element
        public var frame: CGRect

        public init(element: Element, frame: CGRect) {
            self.element = element
            self.frame = frame
        }
    }

    /// Lays `items` out inside `bounds`, largest first.
    ///
    /// Items with a non-positive weight are dropped: a zero-byte folder has no area to show, and
    /// including it would steal a sliver from everything else.
    public static func squarify<Element: Sendable>(
        _ items: [Element],
        weight: (Element) -> Double,
        in bounds: CGRect
    ) -> [Tile<Element>] {
        let weighted = items
            .map { (element: $0, weight: weight($0)) }
            .filter { $0.weight > 0 }
            .sorted { $0.weight > $1.weight }

        guard !weighted.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }

        var tiles: [Tile<Element>] = []
        tiles.reserveCapacity(weighted.count)

        var remaining = weighted[...]
        var frame = bounds

        while !remaining.isEmpty {
            let total = remaining.reduce(0.0) { $0 + $1.weight }
            guard total > 0, frame.width > 0, frame.height > 0 else { break }

            let scale = Double(frame.width * frame.height) / total
            let shortSide = Double(min(frame.width, frame.height))

            // Grow the row while doing so improves its worst aspect ratio.
            var rowLength = 1
            while rowLength < remaining.count {
                let current = worstAspectRatio(remaining.prefix(rowLength), scale: scale, shortSide: shortSide)
                let extended = worstAspectRatio(remaining.prefix(rowLength + 1), scale: scale, shortSide: shortSide)
                if extended > current { break }
                rowLength += 1
            }

            let row = remaining.prefix(rowLength)
            let rowArea = row.reduce(0.0) { $0 + $1.weight * scale }

            if frame.width >= frame.height {
                let columnWidth = CGFloat(rowArea) / frame.height
                var y = frame.minY
                for item in row {
                    let height = CGFloat(item.weight * scale) / columnWidth
                    tiles.append(
                        Tile(
                            element: item.element,
                            frame: CGRect(x: frame.minX, y: y, width: columnWidth, height: height)
                        )
                    )
                    y += height
                }
                frame = CGRect(
                    x: frame.minX + columnWidth,
                    y: frame.minY,
                    width: frame.width - columnWidth,
                    height: frame.height
                )
            } else {
                let rowHeight = CGFloat(rowArea) / frame.width
                var x = frame.minX
                for item in row {
                    let width = CGFloat(item.weight * scale) / rowHeight
                    tiles.append(
                        Tile(
                            element: item.element,
                            frame: CGRect(x: x, y: frame.minY, width: width, height: rowHeight)
                        )
                    )
                    x += width
                }
                frame = CGRect(
                    x: frame.minX,
                    y: frame.minY + rowHeight,
                    width: frame.width,
                    height: frame.height - rowHeight
                )
            }

            remaining = remaining.dropFirst(rowLength)
        }

        return tiles
    }

    private static func worstAspectRatio<Element>(
        _ row: some Sequence<(element: Element, weight: Double)>,
        scale: Double,
        shortSide: Double
    ) -> Double {
        var sum = 0.0
        var maximum = 0.0
        var minimum = Double.greatestFiniteMagnitude
        for item in row {
            let area = item.weight * scale
            sum += area
            maximum = max(maximum, area)
            minimum = min(minimum, area)
        }
        guard sum > 0, minimum > 0 else { return .greatestFiniteMagnitude }
        let squared = shortSide * shortSide
        return max(squared * maximum / (sum * sum), (sum * sum) / (squared * minimum))
    }
}
