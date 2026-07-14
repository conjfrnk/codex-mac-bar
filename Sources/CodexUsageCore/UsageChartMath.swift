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
    public static let maximumSamplesPerSegment = 64
    public static let maximumSmoothedSampleCount = 100_000
    public static let maximumTickCount = 4_096

    /// Produces one canonical X-coordinate array for all chart consumers. Civil
    /// Gregorian ordinals avoid elapsed-second skew across daylight-saving days.
    /// Invalid, duplicate, or non-monotonic dates fall back as a whole to uniform
    /// coordinates, so lines, ticks, markers, and hit testing cannot disagree.
    public static func normalizedCalendarDayPositions(
        for buckets: [DailyUsageBucket]
    ) -> [Double] {
        guard !buckets.isEmpty else { return [] }
        guard buckets.count > 1 else { return [0.5] }
        let ordinals = buckets.compactMap { UsageCivilDate.parse($0.startDate)?.ordinal }
        guard ordinals.count == buckets.count,
              let first = ordinals.first,
              let last = ordinals.last,
              last > first,
              zip(ordinals, ordinals.dropFirst()).allSatisfy({ $1 > $0 })
        else { return evenlySpacedPositions(count: buckets.count) }
        let span = Double(last - first)
        return ordinals.map { Double($0 - first) / span }
    }

    public static func calendarDaySpan(for buckets: [DailyUsageBucket]) -> Int? {
        guard let first = buckets.first.flatMap({ UsageCivilDate.parse($0.startDate)?.ordinal }),
              let last = buckets.last.flatMap({ UsageCivilDate.parse($0.startDate)?.ordinal }),
              last >= first
        else { return nil }
        return Int(exactly: last - first)
    }

    /// Produces a shape-preserving cubic Hermite curve through every source value.
    /// Each evaluated segment is also clamped to its two endpoint values, making
    /// overshoot impossible even in the presence of floating-point roundoff.
    /// Empty, one-point, and two-point series deliberately remain unsmoothed.
    public static func smoothedSamples(
        values: [Int64],
        samplesPerSegment: Int = 12
    ) -> [UsageChartSample] {
        if values.count > maximumSmoothedSampleCount {
            return boundedSourceSamples(values: values, positions: nil, limit: maximumSmoothedSampleCount)
        }
        return smoothedSamples(
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
        if values.count > maximumSmoothedSampleCount {
            let trustedPositions = validPositions(positions, count: values.count) ? positions : nil
            return boundedSourceSamples(
                values: values,
                positions: trustedPositions,
                limit: maximumSmoothedSampleCount
            )
        }
        let sourcePositions = validPositions(positions, count: values.count)
            ? positions
            : evenlySpacedPositions(count: values.count)
        guard values.count > 1 else {
            return [UsageChartSample(position: sourcePositions[0], value: Double(values[0]))]
        }

        let requestedSamples = min(max(samplesPerSegment, 0), maximumSamplesPerSegment)
        guard values.count >= 3, requestedSamples > 1 else {
            return values.enumerated().map { index, value in
                UsageChartSample(position: sourcePositions[index], value: Double(value))
            }
        }

        let segmentCount = values.count - 1
        let affordableSamples = (maximumSmoothedSampleCount - 1) / segmentCount
        let boundedSamplesPerSegment = min(requestedSamples, affordableSamples)
        guard boundedSamplesPerSegment > 1 else {
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
        let outputCount = (source.count - 1) * boundedSamplesPerSegment + 1
        result.reserveCapacity(outputCount)

        for segment in 0..<(source.count - 1) {
            let start = source[segment]
            let end = source[segment + 1]
            let startPosition = sourcePositions[segment]
            let interval = intervals[segment]
            let lower = min(start, end)
            let upper = max(start, end)

            for sampleIndex in 0..<boundedSamplesPerSegment {
                let t = Double(sampleIndex) / Double(boundedSamplesPerSegment)
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

    /// Produces a pixel-budgeted render series. Large source sets are reduced by
    /// retaining the chronological minimum and maximum in each partition, so
    /// spikes survive without drawing tens of thousands of subpixel segments.
    public static func renderSamples(
        values: [Int64],
        positions: [Double],
        maximumSampleCount: Int
    ) -> [UsageChartSample] {
        guard !values.isEmpty else { return [] }
        let limit = min(max(maximumSampleCount, 2), maximumSmoothedSampleCount)
        let trustedPositions = validPositions(positions, count: values.count) ? positions : nil
        if values.count > limit {
            return boundedSourceSamples(
                values: values,
                positions: trustedPositions,
                limit: limit
            )
        }
        guard values.count > 1 else {
            return [UsageChartSample(
                position: trustedPositions?.first ?? 0.5,
                value: Double(values[0])
            )]
        }
        let affordableSamplesPerSegment = max(1, (limit - 1) / (values.count - 1))
        return smoothedSamples(
            values: values,
            positions: trustedPositions ?? evenlySpacedPositions(count: values.count),
            samplesPerSegment: min(12, affordableSamplesPerSegment)
        )
    }

    public static func tickIndices(pointCount: Int, maximumTickCount: Int) -> [Int] {
        guard pointCount > 0, maximumTickCount > 0 else { return [] }
        guard pointCount > 1, maximumTickCount > 1 else { return [0] }
        let outputCount = min(pointCount, maximumTickCount, Self.maximumTickCount)
        guard outputCount > 1 else { return [0] }
        if pointCount <= outputCount {
            return Array(0..<pointCount)
        }
        let maximumIndex = pointCount - 1
        return (0..<outputCount).reduce(into: [Int]()) { result, tick in
            if tick == 0 {
                result.append(0)
            } else if tick == outputCount - 1 {
                result.append(maximumIndex)
            } else {
                let fraction = Double(tick) / Double(outputCount - 1)
                let index = Int((fraction * Double(maximumIndex)).rounded())
                if result.last != index {
                    result.append(index)
                }
            }
        }
    }

    public static func tickIndices(positions: [Double], maximumTickCount: Int) -> [Int] {
        let pointCount = positions.count
        guard pointCount > 0, maximumTickCount > 0 else { return [] }
        guard pointCount > 1, maximumTickCount > 1 else { return [0] }
        let outputCount = min(maximumTickCount, Self.maximumTickCount)
        guard pointCount > outputCount else { return Array(0..<pointCount) }
        guard validPositions(positions, count: pointCount) else {
            // Invalid public input falls back to uniform index spacing without
            // allocating a second attacker-sized positions array.
            return tickIndices(pointCount: pointCount, maximumTickCount: maximumTickCount)
        }
        let sourcePositions = positions

        return (0..<outputCount).reduce(into: [Int]()) { result, tick in
            let fraction = Double(tick) / Double(outputCount - 1)
            let position = sourcePositions[0]
                + (fraction * (sourcePositions[pointCount - 1] - sourcePositions[0]))
            let index = nearestIndex(to: position, validatedPositions: sourcePositions)
            if result.last != index {
                result.append(index)
            }
        }
    }

    public static func nearestIndex(to position: Double, pointCount: Int) -> Int? {
        guard position.isFinite, pointCount > 0 else { return nil }
        guard pointCount > 1 else { return 0 }
        if position <= 0 { return 0 }
        if position >= 1 { return pointCount - 1 }
        let scaled = (position * Double(pointCount - 1)).rounded()
        guard scaled.isFinite else { return nil }
        return min(max(Int(scaled), 0), pointCount - 1)
    }

    public static func nearestIndex(to position: Double, positions: [Double]) -> Int? {
        guard position.isFinite, !positions.isEmpty else { return nil }
        guard validPositions(positions, count: positions.count) else {
            // As above, use arithmetic fallback rather than duplicating a huge
            // invalid array solely to manufacture uniform coordinates.
            return nearestIndex(to: position, pointCount: positions.count)
        }
        return nearestIndex(to: position, validatedPositions: positions)
    }

    private static func nearestIndex(
        to position: Double,
        validatedPositions sourcePositions: [Double]
    ) -> Int {
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
        var magnitude: Int64 = 1
        while value / magnitude >= 10, magnitude <= Int64.max / 10 {
            magnitude *= 10
        }
        for multiplier: Int64 in [1, 2, 5, 10] {
            let (candidate, overflow) = magnitude.multipliedReportingOverflow(by: multiplier)
            if !overflow, candidate >= value {
                return candidate
            }
        }
        // There is no representable 1/2/5/10 bound above very large inputs.
        return .max
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

    private static func boundedSourceSamples(
        values: [Int64],
        positions: [Double]?,
        limit: Int
    ) -> [UsageChartSample] {
        guard limit > 1, values.count > limit else {
            return values.enumerated().map { index, value in
                UsageChartSample(
                    position: positions?[index] ?? evenlySpacedPosition(index: index, count: values.count),
                    value: Double(value)
                )
            }
        }
        let lastIndex = values.count - 1
        let interiorCount = lastIndex - 1
        if limit == 2 {
            return [0, lastIndex].map { index in
                UsageChartSample(
                    position: positions?[index]
                        ?? evenlySpacedPosition(index: index, count: values.count),
                    value: Double(values[index])
                )
            }
        }
        if limit == 3 {
            let firstValue = Double(values[0])
            let lastValue = Double(values[lastIndex])
            let firstPosition = positions?.first ?? 0
            let lastPosition = positions?.last ?? 1
            let positionSpan = lastPosition - firstPosition
            var mostSalientIndex = 1
            var greatestDeviation = -Double.infinity
            for index in 1..<lastIndex {
                let position = positions?[index]
                    ?? evenlySpacedPosition(index: index, count: values.count)
                let fraction = (position - firstPosition) / positionSpan
                let expected = firstValue + ((lastValue - firstValue) * fraction)
                let deviation = abs(Double(values[index]) - expected)
                if deviation > greatestDeviation {
                    greatestDeviation = deviation
                    mostSalientIndex = index
                }
            }
            return [0, mostSalientIndex, lastIndex].map { index in
                UsageChartSample(
                    position: positions?[index]
                        ?? evenlySpacedPosition(index: index, count: values.count),
                    value: Double(values[index])
                )
            }
        }
        let binCount = max(1, (limit - 2) / 2)
        var result: [UsageChartSample] = []
        result.reserveCapacity(limit)

        func append(_ index: Int) {
            let position = positions?[index] ?? evenlySpacedPosition(index: index, count: values.count)
            if result.last?.position != position {
                result.append(UsageChartSample(position: position, value: Double(values[index])))
            }
        }

        append(0)
        for bin in 0..<binCount {
            let start = 1 + partitionBoundary(
                part: bin,
                totalParts: binCount,
                itemCount: interiorCount
            )
            let end = 1 + partitionBoundary(
                part: bin + 1,
                totalParts: binCount,
                itemCount: interiorCount
            )
            guard start < end else { continue }
            var minimumIndex = start
            var maximumIndex = start
            for index in (start + 1)..<end {
                if values[index] < values[minimumIndex] { minimumIndex = index }
                if values[index] > values[maximumIndex] { maximumIndex = index }
            }
            for index in [minimumIndex, maximumIndex].sorted() { append(index) }
        }
        append(lastIndex)
        return result
    }

    private static func evenlySpacedPosition(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0.5 }
        return Double(index) / Double(count - 1)
    }

    private static func partitionBoundary(part: Int, totalParts: Int, itemCount: Int) -> Int {
        guard totalParts > 0, part > 0, itemCount > 0 else { return 0 }
        if part >= totalParts { return itemCount }
        let quotient = itemCount / totalParts
        let remainder = itemCount % totalParts
        return (quotient * part) + ((remainder * part) / totalParts)
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
