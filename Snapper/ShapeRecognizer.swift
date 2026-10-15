import CoreGraphics

/// Turns a clean pen stroke into a line, arrow, rectangle or ellipse. Thresholds are deliberately strict:
/// a scribble that is not clearly one of these stays exactly as drawn.
enum ShapeRecognizer {
    enum Shape {
        case line(CGPoint, CGPoint)
        case arrow(CGPoint, CGPoint)       // tail, tip
        case rectangle(CGRect)
        case ellipse(CGRect)
    }

    static func recognize(_ raw: [CGPoint]) -> Shape? {
        guard raw.count >= 8, let first = raw.first, let last = raw.last else { return nil }
        let box = bounds(raw)
        let diag = hypot(box.width, box.height)
        guard diag >= 48 else { return nil }
        let pathLength = length(raw)
        guard pathLength > 0 else { return nil }
        let gap = hypot(first.x - last.x, first.y - last.y)

        if gap < pathLength * 0.3 {
            // Closed stroke: rectangle first (corners are unmistakable), then ellipse.
            if let r = rectangle(raw, box: box, diag: diag) ?? rectangleFit(raw, box: box) { return .rectangle(r) }
            if let e = ellipse(raw, box: box) { return .ellipse(e) }
            return nil
        }

        // Open stroke: a straight line, or a line ending in a hook (an arrow head).
        if gap >= 40 {
            var deviation: CGFloat = 0
            for p in raw { deviation = max(deviation, AnnotationObject.distance(from: p, toSegment: first, last)) }
            if deviation <= gap * 0.08 { return .line(first, last) }
        }
        if let a = arrow(raw, diag: diag) { return .arrow(a.0, a.1) }
        return nil
    }

    // MARK: Pieces

    private static func arrow(_ raw: [CGPoint], diag: CGFloat) -> (CGPoint, CGPoint)? {
        let v = AnnotationObject.simplify(raw, epsilon: diag * 0.04)
        guard v.count >= 4, v.count <= 6 else { return nil }
        // The shaft is the first segment and must dominate the stroke.
        let shaft = dist(v[0], v[1])
        guard shaft >= 40 else { return nil }
        var rest: CGFloat = 0
        for i in 1..<(v.count - 1) { rest += dist(v[i], v[i + 1]) }
        guard shaft >= rest * 0.9 else { return nil }
        let tip = v[1]
        var barb = false
        for j in 2..<v.count {
            guard dist(v[j], tip) <= shaft * 0.5 else { return nil }
            if AnnotationObject.distance(from: v[j], toSegment: v[0], tip) > shaft * 0.1 { barb = true }
        }
        guard barb else { return nil }
        // The first stroke after the tip has to head back toward the tail.
        let back = CGPoint(x: v[0].x - tip.x, y: v[0].y - tip.y)
        let out = CGPoint(x: v[2].x - tip.x, y: v[2].y - tip.y)
        guard back.x * out.x + back.y * out.y > 0 else { return nil }
        return (v[0], tip)
    }

    private static func rectangle(_ raw: [CGPoint], box: CGRect, diag: CGFloat) -> CGRect? {
        var v = AnnotationObject.simplify(raw, epsilon: diag * 0.07)
        if v.count > 1, dist(v[0], v[v.count - 1]) < diag * 0.2 { v.removeLast() }
        guard v.count == 4 else { return nil }
        for i in 0..<4 {
            let a = v[i], b = v[(i + 1) % 4], c = v[(i + 2) % 4]
            let u = CGPoint(x: a.x - b.x, y: a.y - b.y), w = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let lu = hypot(u.x, u.y), lw = hypot(w.x, w.y)
            guard lu > 12, lw > 12 else { return nil }
            let cosine = (u.x * w.x + u.y * w.y) / (lu * lw)
            guard abs(cosine) < 0.45 else { return nil }                        // roughly 63 to 117 degrees
            // Sides must be close to horizontal or vertical.
            let tilt = abs(atan2(abs(u.y), abs(u.x)))                           // 0 horizontal, pi/2 vertical
            guard tilt < 0.38 || tilt > (.pi / 2 - 0.38) else { return nil }
        }
        let r = bounds(v)
        guard r.width > 20, r.height > 20 else { return nil }
        return r
    }

    /// A rectangle drawn from the middle of a side has extra vertices, so also accept a stroke that simply hugs the
    /// edges of its bounding box and reaches all four corners.
    private static func rectangleFit(_ raw: [CGPoint], box: CGRect) -> CGRect? {
        let m = min(box.width, box.height)
        guard m > 20 else { return nil }
        func edgeDistance(_ p: CGPoint) -> CGFloat {
            min(abs(p.x - box.minX), abs(p.x - box.maxX), abs(p.y - box.minY), abs(p.y - box.maxY))
        }
        let sorted = raw.map(edgeDistance).sorted()
        guard sorted[Int(Double(sorted.count - 1) * 0.9)] <= 0.09 * m else { return nil }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        for c in corners {
            guard let nearest = raw.map({ dist($0, c) }).min(), nearest <= 0.22 * m else { return nil }
        }
        return box
    }

    private static func ellipse(_ raw: [CGPoint], box: CGRect) -> CGRect? {
        guard box.width > 24, box.height > 24 else { return nil }
        let aspect = box.width / box.height
        guard aspect > 0.2, aspect < 5 else { return nil }
        let a = box.width / 2, b = box.height / 2
        let cx = box.midX, cy = box.midY
        var sum: CGFloat = 0, sumSq: CGFloat = 0
        var quadrants = Set<Int>()
        for p in raw {
            let nx = (p.x - cx) / a, ny = (p.y - cy) / b
            let e = hypot(nx, ny)
            sum += e
            sumSq += e * e
            quadrants.insert((nx >= 0 ? 1 : 0) + (ny >= 0 ? 2 : 0))
        }
        let n = CGFloat(raw.count)
        let mean = sum / n
        let variance = max(sumSq / n - mean * mean, 0)
        guard quadrants.count == 4, abs(mean - 1) < 0.25, sqrt(variance) < 0.22 else { return nil }
        return box
    }

    /// A short stroke drawn at the end of a straight line (one barb of an arrow head, or a V) turns that line into an
    /// arrow. Returns the end of the line that should become the tip, or nil when the stroke is not a head.
    static func arrowHeadEnd(stroke: [CGPoint], lineStart: CGPoint, lineEnd: CGPoint) -> CGPoint? {
        guard stroke.count >= 3 else { return nil }
        let shaft = dist(lineStart, lineEnd)
        guard shaft >= 40 else { return nil }
        let len = length(stroke)
        let box = bounds(stroke)
        guard len > 8, len < shaft * 0.7, hypot(box.width, box.height) < shaft * 0.6 else { return nil }
        let nearEnd = stroke.map { dist($0, lineEnd) }.min() ?? .infinity
        let nearStart = stroke.map { dist($0, lineStart) }.min() ?? .infinity
        let limit = shaft * 0.22
        if nearEnd <= limit, nearEnd <= nearStart { return lineEnd }
        if nearStart <= limit { return lineStart }
        return nil
    }

    // MARK: Helpers

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func length(_ pts: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        for i in 1..<pts.count { total += dist(pts[i - 1], pts[i]) }
        return total
    }

    private static func bounds(_ pts: [CGPoint]) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
