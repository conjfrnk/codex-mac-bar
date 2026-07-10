import Foundation

public struct UsageChartSample: Equatable, Sendable {
    public let position: Double
    public let value: Double

    public init(position: Double, value: Double) {
        self.position = position
        self.value = value
    }
}

public enum UsageChartDateLabelStyle: Equatable, Sendable {
    case singleLetterWeekday
    case abbreviatedWeekday
    case numericMonthDay
    case abbreviatedMonthDay
    case abbreviatedMonthYear
}

public struct UsageChartAxisPolicy: Equatable, Sendable {
    public let maximumTickCount: Int
    public let dateLabelStyle: UsageChartDateLabelStyle

    public init(maximumTickCount: Int, dateLabelStyle: UsageChartDateLabelStyle) {
        self.maximumTickCount = maximumTickCount
        self.dateLabelStyle = dateLabelStyle
    }

    public static func policy(for timeframe: UsageTimeframe, spanDays: Int? = nil) -> Self {
        switch timeframe {
        case .seven:
            return Self(maximumTickCount: 7, dateLabelStyle: .singleLetterWeekday)
        case .thirty:
            return Self(maximumTickCount: 4, dateLabelStyle: .numericMonthDay)
        case .ninety:
            return Self(maximumTickCount: 3, dateLabelStyle: .abbreviatedMonthDay)
        case .all:
            let style: UsageChartDateLabelStyle = (spanDays ?? 0) >= 365
                ? .abbreviatedMonthYear
                : .abbreviatedMonthDay
            return Self(maximumTickCount: 3, dateLabelStyle: style)
        }
    }
}

public enum UsageChartMath {
    /// Produces a shape-preserving cubic Hermite curve through every source value.
    /// Each evaluated segment is also clamped to its two endpoint values, making
    /// overshoot impossible even in the presence of floating-point roundoff.
    /// Empty, one-point, and two-point series deliberately remain unsmoothed.
    public static func smoothedSamples(
        values: [Int64],
        samplesPerSegment: Int = 12
    ) -> [UsageChartSample] {
        smoothedSamples(
            values: values,
            positions: evenlySpacedPositions(count: values.count),
            samplesPerSegment: samplesPerSegment
        )
    }

    public static func smoothedSamples(
        values: [Int64],
        positions: [Double],
        samplesPerSegment: Int = 12
    ) -> [UsageChartSample] {
        guard !values.isEmpty else { return [] }
        let sourcePositions = validPositions(positions, count: values.count)
            ? positions
            : evenlySpacedPositions(count: values.count)
        guard values.count > 1 else {
            return [UsageChartSample(position: sourcePositions[0], value: Double(values[0]))]
        }

        guard values.count >= 3, samplesPerSegment > 1 else {
            return values.enumerated().map { index, value in
                UsageChartSample(position: sourcePositions[index], value: Double(value))
            }
        }

        let source = values.map(Double.init)
        let intervals = zip(sourcePositions, sourcePositions.dropFirst()).map { $1 - $0 }
        let deltas = source.indices.dropLast().map { index in
            (source[index + 1] - source[index]) / intervals[index]
        }
        var tangents = Array(repeating: 0.0, count: source.count)
        tangents[0] = deltas[0]
        tangents[source.count - 1] = deltas[deltas.count - 1]

        for index in 1..<(source.count - 1) {
            let before = deltas[index - 1]
            let after = deltas[index]
            if sameDirection(before, after) {
                let beforeInterval = intervals[index - 1]
                let afterInterval = intervals[index]
                let beforeWeight = (2 * afterInterval) + beforeInterval
                let afterWeight = afterInterval + (2 * beforeInterval)
                tangents[index] = (beforeWeight + afterWeight)
                    / ((beforeWeight / before) + (afterWeight / after))
            }
        }

        var result: [UsageChartSample] = []
        result.reserveCapacity((source.count - 1) * samplesPerSegment + 1)

        for segment in 0..<(source.count - 1) {
            let start = source[segment]
            let end = source[segment + 1]
            let startPosition = sourcePositions[segment]
            let interval = intervals[segment]
            let lower = min(start, end)
            let upper = max(start, end)

            for sampleIndex in 0..<samplesPerSegment {
                let t = Double(sampleIndex) / Double(samplesPerSegment)
                let t2 = t * t
                let t3 = t2 * t
                let h00 = (2 * t3) - (3 * t2) + 1
                let h10 = t3 - (2 * t2) + t
                let h01 = (-2 * t3) + (3 * t2)
                let h11 = t3 - t2
                let interpolated = (h00 * start)
                    + (h10 * interval * tangents[segment])
                    + (h01 * end)
                    + (h11 * interval * tangents[segment + 1])
                let bounded = min(max(interpolated, lower), upper)
                let position = startPosition + (t * interval)
                result.append(UsageChartSample(position: position, value: bounded))
            }
        }

        result.append(UsageChartSample(position: sourcePositions[sourcePositions.count - 1], value: source[source.count - 1]))
        return result
    }

    public static func tickIndices(pointCount: Int, maximumTickCount: Int) -> [Int] {
        tickIndices(
            positions: evenlySpacedPositions(count: pointCount),
            maximumTickCount: maximumTickCount
        )
    }

    public static func tickIndices(positions: [Double], maximumTickCount: Int) -> [Int] {
        let pointCount = positions.count
        guard pointCount > 0, maximumTickCount > 0 else { return [] }
        guard pointCount > 1, maximumTickCount > 1 else { return [0] }
        guard pointCount > maximumTickCount else { return Array(0..<pointCount) }
        let sourcePositions = validPositions(positions, count: pointCount)
            ? positions
            : evenlySpacedPositions(count: pointCount)

        return (0..<maximumTickCount).reduce(into: [Int]()) { result, tick in
            let fraction = Double(tick) / Double(maximumTickCount - 1)
            let position = sourcePositions[0]
                + (fraction * (sourcePositions[pointCount - 1] - sourcePositions[0]))
            guard let index = nearestIndex(to: position, positions: sourcePositions) else { return }
            if result.last != index {
                result.append(index)
            }
        }
    }

    public static func nearestIndex(to position: Double, pointCount: Int) -> Int? {
        nearestIndex(to: position, positions: evenlySpacedPositions(count: pointCount))
    }

    public static func nearestIndex(to position: Double, positions: [Double]) -> Int? {
        guard position.isFinite, !positions.isEmpty else { return nil }
        let sourcePositions = validPositions(positions, count: positions.count)
            ? positions
            : evenlySpacedPositions(count: positions.count)
        guard sourcePositions.count > 1 else { return 0 }
        if position <= sourcePositions[0] { return 0 }
        if position >= sourcePositions[sourcePositions.count - 1] {
            return sourcePositions.count - 1
        }

        var lowerIndex = 0
        var upperIndex = sourcePositions.count - 1
        while upperIndex - lowerIndex > 1 {
            let middleIndex = (lowerIndex + upperIndex) / 2
            if sourcePositions[middleIndex] < position {
                lowerIndex = middleIndex
            } else {
                upperIndex = middleIndex
            }
        }

        let lowerDistance = position - sourcePositions[lowerIndex]
        let upperDistance = sourcePositions[upperIndex] - position
        return lowerDistance < upperDistance ? lowerIndex : upperIndex
    }

    public static func clampedCenter(
        proposed: Double,
        itemLength: Double,
        lowerBound: Double,
        upperBound: Double
    ) -> Double {
        guard lowerBound.isFinite,
              upperBound.isFinite,
              upperBound >= lowerBound
        else { return proposed.isFinite ? proposed : 0 }

        let availableLength = upperBound - lowerBound
        guard availableLength.isFinite else {
            return proposed.isFinite ? min(max(proposed, lowerBound), upperBound) : 0
        }
        let midpoint = lowerBound + (availableLength / 2)
        guard proposed.isFinite, itemLength.isFinite else { return midpoint }
        guard itemLength > 0, itemLength < availableLength else {
            return midpoint
        }
        let halfLength = itemLength / 2
        return min(max(proposed, lowerBound + halfLength), upperBound - halfLength)
    }

    /// Rounds a positive value up to a "nice" axis bound (1/2/5/10 times a power of
    /// ten) so chart gridlines read as round numbers instead of the raw peak value.
    public static func niceAxisMaximum(_ value: Int64) -> Int64 {
        guard value > 0 else { return 0 }
        let magnitude = pow(10, floor(log10(Double(value))))
        guard magnitude.isFinite, magnitude > 0 else { return value }
        let normalized = Double(value) / magnitude
        let niceNormalized: Double
        switch normalized {
        case ...1: niceNormalized = 1
        case ...2: niceNormalized = 2
        case ...5: niceNormalized = 5
        default: niceNormalized = 10
        }
        let result = (niceNormalized * magnitude).rounded()
        guard result.isFinite, result <= Double(Int64.max) else { return value }
        return Int64(result)
    }

    private static func sameDirection(_ lhs: Double, _ rhs: Double) -> Bool {
        (lhs > 0 && rhs > 0) || (lhs < 0 && rhs < 0)
    }

    private static func evenlySpacedPositions(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [0.5] }
        let denominator = Double(count - 1)
        return (0..<count).map { Double($0) / denominator }
    }

    private static func validPositions(_ positions: [Double], count: Int) -> Bool {
        guard positions.count == count,
              positions.allSatisfy(\.isFinite),
              let first = positions.first,
              let last = positions.last,
              first >= 0,
              last <= 1
        else { return false }

        // Positions are normalized chart coordinates. Reject intervals too small
        // for stable slope arithmetic and fall back to uniform presentation.
        let minimumInterval = 1e-12
        return zip(positions, positions.dropFirst()).allSatisfy {
            let interval = $1 - $0
            return interval.isFinite && interval >= minimumInterval
        }
    }
}
