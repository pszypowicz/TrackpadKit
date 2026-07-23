import AppKit
import TrackpadKit

/// The lab surface and the package's reference host: set up the way a
/// real app's view would be (first responder, indirect touches, raw
/// touch overrides plus real scrollWheel/magnify overrides), and draws
/// the live debug overlay on top.
///
/// Event policy under test: the recognizer owns the raw NSTouch stream
/// and is the only source of gesture actions. scrollWheel is treated
/// purely as scroll (and its momentum copies identified via
/// momentumPhase); magnify/smartMagnify/swipe are only counted for the
/// A/B and premise checks.
final class TouchView: NSView {
    let recognizer = TrackpadGestureRecognizer()
    let recorder = TouchRecorder()
    let palmFilter = PalmFilter()
    private(set) var palmFilterEnabled = true
    /// Latest raw positions of suppressed touches, for the overlay -
    /// the recognizer never sees them, so they aren't in its snapshot.
    private var suppressedDots: [(id: Int, normalized: CGPoint)] = []

    private var identityMap: [NSObject: Int] = [:]
    private var nextTouchID = 1
    private var tickTimer: Timer?
    private var touchesEnabled = true

    // Palm research: AppKit's resting-touch classification per live
    // touch id, and how many resting-flagged touches were seen since
    // the last counter reset. wantsRestingTouches starts false (the
    // production default); [w] toggles it to see what AppKit hides.
    private var restingByID: [Int: Bool] = [:]
    private var restingSeenCount = 0

    // Coexistence instrumentation
    private var scrollLiveCount = 0
    private var scrollMomentumCount = 0
    private var scrollLegacyCount = 0
    private var coincidentScrollCount = 0
    private var scrollAccum = CGPoint.zero
    private var lastScrollInfo = "none yet"
    private var magnifyCount = 0
    private var osMagnifyScale = 1.0
    private var lastMagnifyInfo = "none yet"
    private var swipeAPICount = 0
    private var smartMagnifyCount = 0
    private var eventLog: [String] = []

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        recognizer.onGesture = { [weak self] event in self?.handleGesture(event) }
    }

    required init?(coder: NSCoder) { fatalError("programmatic only") }

    // MARK: Raw touches -> recognizer

    override func touchesBegan(with event: NSEvent) { ingest(event) }
    override func touchesMoved(with event: NSEvent) { ingest(event) }
    override func touchesEnded(with event: NSEvent) { ingest(event) }
    override func touchesCancelled(with event: NSEvent) { ingest(event) }

    private func ingest(_ event: NSEvent) {
        let touches = event.touches(matching: .any, in: self)
        guard !touches.isEmpty else { return }
        var deviceSize = CGSize(width: 1, height: 1)
        var samples: [TouchSample] = []
        for touch in touches {
            deviceSize = touch.deviceSize
            // identity is stable across the touch's lifetime and adopts
            // NSCopying; a copy is the sanctioned dictionary key.
            let key = touch.identity.copy(with: nil) as! NSObject
            let id: Int
            if let known = identityMap[key] {
                id = known
            } else {
                id = nextTouchID
                nextTouchID += 1
                identityMap[key] = id
            }
            let phase = Self.mapPhase(touch.phase)
            if phase == .ended || phase == .cancelled {
                identityMap.removeValue(forKey: key)
                restingByID.removeValue(forKey: id)
            } else {
                if touch.isResting && restingByID[id] != true { restingSeenCount += 1 }
                restingByID[id] = touch.isResting
            }
            let p = touch.normalizedPosition
            samples.append(TouchSample(id: id, x: p.x, y: p.y, phase: phase,
                                       resting: touch.isResting))
        }
        let frame = TouchFrame(t: event.timestamp,
                               w: deviceSize.width, h: deviceSize.height,
                               touches: samples)
        // Recordings stay raw: the filter is under test, its input is
        // the research artifact.
        if recorder.isRecording { recorder.append(frame) }
        if palmFilterEnabled {
            if let filtered = palmFilter.process(frame) {
                recognizer.process(filtered)
            }
            suppressedDots = samples.compactMap { s in
                guard s.phase != .ended, s.phase != .cancelled,
                      let state = palmFilter.state(of: s.id), state != .finger
                else { return nil }
                return (s.id, CGPoint(x: s.x, y: s.y))
            }
        } else {
            recognizer.process(frame)
            suppressedDots = []
        }
        syncTickTimer()
        needsDisplay = true
    }

    private static func mapPhase(_ phase: NSTouch.Phase) -> TouchPhase {
        if phase.contains(.began) { return .began }
        if phase.contains(.moved) { return .moved }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return .stationary
    }

    /// Stationary fingers aren't guaranteed to keep producing touch
    /// events, but the settle timer still needs to fire - drive the
    /// recognizer's clock while a sequence is active. NSEvent.timestamp and systemUptime share a
    /// clock.
    private func syncTickTimer() {
        let active = recognizer.state != .idle
        if active && tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.recognizer.tick(now: ProcessInfo.processInfo.systemUptime)
                self.syncTickTimer()
                self.needsDisplay = true
            }
        } else if !active, let timer = tickTimer {
            timer.invalidate()
            tickTimer = nil
            // After a stale-timeout reset, fingers can still be down with
            // no events arriving; clearing here re-keys them under fresh
            // ids at the next event. Downstream absorbs that (the filter
            // re-admits unknown ids by position), but recordings capture
            // the same mid-life id swap the leftover-patch fixture pins.
            identityMap.removeAll()
            restingByID.removeAll()
            // Suspects lift without the recognizer going active, so an
            // idle recognizer doesn't imply an empty filter; only clear
            // leftovers once the raw pad is empty too.
            if suppressedDots.isEmpty { palmFilter.reset() }
        }
    }

    private func handleGesture(_ e: GestureEvent) {
        switch e.phase {
        case .began: log("began  \(Self.describe(e))")
        case .ended: log("ACTION \(Self.describe(e))")
        case .cancelled: log("cancel \(Self.describe(e))")
        case .changed: break
        }
        needsDisplay = true
    }

    private static func describe(_ e: GestureEvent) -> String {
        switch e.kind {
        case .swipe:
            return String(format: "swipe %@ %df  mag %.1fpt  vel %.0fpt/s",
                          e.direction.rawValue, e.fingerCount, e.magnitude, e.velocity)
        case .pinch:
            return String(format: "pinch %df  scale %.3f  vel %.2f/s",
                          e.fingerCount, e.magnitude, e.velocity)
        }
    }

    // MARK: OS event instrumentation

    override func scrollWheel(with event: NSEvent) {
        let hasMomentum = !event.momentumPhase.isEmpty
        if hasMomentum {
            scrollMomentumCount += 1
        } else if !event.phase.isEmpty {
            scrollLiveCount += 1
        } else {
            scrollLegacyCount += 1
        }
        scrollAccum.x += event.scrollingDeltaX
        scrollAccum.y += event.scrollingDeltaY
        // Double-source proof: count live scroll frames that arrive while
        // our tracker has a committed swipe from the same fingers. They
        // are observed here but never turned into a gesture action.
        if case .committed(let kind, _) = recognizer.state, kind == .swipe, !hasMomentum {
            coincidentScrollCount += 1
        }
        lastScrollInfo = String(format: "dx %+7.1f  dy %+7.1f  phase %@  momentum %@",
                                event.scrollingDeltaX, event.scrollingDeltaY,
                                Self.phaseName(event.phase), Self.phaseName(event.momentumPhase))
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        magnifyCount += 1
        if event.phase == .began { osMagnifyScale = 1 }
        osMagnifyScale *= 1 + event.magnification
        lastMagnifyInfo = String(format: "delta %+.4f  phase %@  total x%.3f",
                                 event.magnification, Self.phaseName(event.phase), osMagnifyScale)
        needsDisplay = true
    }

    override func swipe(with event: NSEvent) {
        swipeAPICount += 1
        log(String(format: "OS swipe(with:) FIRED  dx %+.1f dy %+.1f", event.deltaX, event.deltaY))
        needsDisplay = true
    }

    override func smartMagnify(with event: NSEvent) {
        smartMagnifyCount += 1
        log("OS smartMagnify(with:) fired")
        needsDisplay = true
    }

    private static func phaseName(_ phase: NSEvent.Phase) -> String {
        switch phase {
        case .began: return "began"
        case .changed: return "changed"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        case .mayBegin: return "mayBegin"
        case .stationary: return "stationary"
        default: return phase.isEmpty ? "none" : "mixed"
        }
    }

    // MARK: Keyboard controls

    override func keyDown(with event: NSEvent) {
        guard let c = event.charactersIgnoringModifiers?.first else {
            return super.keyDown(with: event)
        }
        switch c {
        case "r": toggleRecording()
        case "c": resetInstrumentation()
        case "t": toggleTouchDelivery()
        case "w": toggleRestingTouches()
        case "f": togglePalmFilter()
        case "s": recognizer.config.swipeCommitThreshold = max(1, recognizer.config.swipeCommitThreshold - 1)
        case "S": recognizer.config.swipeCommitThreshold += 1
        case "p": recognizer.config.pinchCommitThreshold = max(1, recognizer.config.pinchCommitThreshold - 1)
        case "P": recognizer.config.pinchCommitThreshold += 1
        default: return super.keyDown(with: event)
        }
        needsDisplay = true
    }

    func toggleRecording() {
        if recorder.isRecording {
            let path = recorder.path ?? "?"
            let frames = recorder.frameCount
            recorder.stop()
            log("recording stopped: \(frames) frames -> \(path)")
        } else {
            do {
                let dir = FileManager.default.currentDirectoryPath + "/recordings"
                let path = try recorder.start(directory: dir)
                log("recording -> \(path)")
            } catch {
                log("recording failed: \(error.localizedDescription)")
            }
        }
        needsDisplay = true
    }

    private func toggleTouchDelivery() {
        touchesEnabled.toggle()
        allowedTouchTypes = touchesEnabled ? [.indirect] : []
        recognizer.reset()
        palmFilter.reset()
        suppressedDots = []
        log("allowedTouchTypes = \(touchesEnabled ? "[.indirect]" : "[] (touches off)")")
    }

    private func toggleRestingTouches() {
        wantsRestingTouches.toggle()
        recognizer.reset()
        palmFilter.reset()
        suppressedDots = []
        restingByID.removeAll()
        log("wantsRestingTouches = \(wantsRestingTouches)")
    }

    private func togglePalmFilter() {
        palmFilterEnabled.toggle()
        palmFilter.reset()
        recognizer.reset()
        suppressedDots = []
        log("palm filter = \(palmFilterEnabled ? "on" : "off")")
    }

    private func resetInstrumentation() {
        scrollLiveCount = 0
        scrollMomentumCount = 0
        scrollLegacyCount = 0
        coincidentScrollCount = 0
        scrollAccum = .zero
        lastScrollInfo = "none yet"
        magnifyCount = 0
        osMagnifyScale = 1
        lastMagnifyInfo = "none yet"
        swipeAPICount = 0
        smartMagnifyCount = 0
        restingSeenCount = 0
        log("counters reset")
    }

    private func log(_ line: String) {
        eventLog.append(line)
        if eventLog.count > 10 { eventLog.removeFirst(eventLog.count - 10) }
        print(line)
    }

    // MARK: Overlay drawing

    private static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let monoBold = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private static let banner = NSFont.monospacedSystemFont(ofSize: 24, weight: .bold)

    private static let dim = NSColor(calibratedWhite: 0.55, alpha: 1)
    private static let bright = NSColor(calibratedWhite: 0.92, alpha: 1)
    private static let accent = NSColor.systemTeal
    private static let good = NSColor.systemGreen
    private static let warn = NSColor.systemOrange
    private static let bad = NSColor.systemRed

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
        bounds.fill()
        let snap = recognizer.snapshot(now: ProcessInfo.processInfo.systemUptime)
        drawTouches(snap)
        drawRecognizerPanel(snap)
        drawOSEventPanel()
        drawBottom(snap)
    }

    private func viewPoint(normalized: CGPoint) -> CGPoint {
        CGPoint(x: normalized.x * bounds.width,
                y: (1 - normalized.y) * bounds.height)
    }

    private func drawTouches(_ snap: TrackpadGestureRecognizer.DebugSnapshot) {
        let dotColor: NSColor
        switch snap.state {
        case .committed(let kind, _): dotColor = kind == .swipe ? Self.good : Self.accent
        case .locked: dotColor = Self.warn
        case .settling: dotColor = Self.dim
        default: dotColor = Self.dim.withAlphaComponent(0.5)
        }
        for dot in snap.touches {
            let p = viewPoint(normalized: dot.normalized)
            let radius: CGFloat = 18
            let circle = NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius,
                                                     width: radius * 2, height: radius * 2))
            dotColor.withAlphaComponent(0.35).setFill()
            circle.fill()
            dotColor.setStroke()
            circle.lineWidth = 2
            circle.stroke()
            drawText("\(dot.id)", at: CGPoint(x: p.x - 4, y: p.y - 8),
                     font: Self.monoBold, color: Self.bright)
            drawText(String(format: "%.0f,%.0f", dot.device.x, dot.device.y),
                     at: CGPoint(x: p.x + radius + 4, y: p.y - 6),
                     font: Self.mono, color: Self.dim)
            if restingByID[dot.id] == true {
                drawText("R", at: CGPoint(x: p.x - 4, y: p.y - radius - 16),
                         font: Self.monoBold, color: Self.bad)
            }
        }
        for dot in suppressedDots {
            let p = viewPoint(normalized: dot.normalized)
            let radius: CGFloat = 18
            let circle = NSBezierPath(ovalIn: NSRect(x: p.x - radius, y: p.y - radius,
                                                     width: radius * 2, height: radius * 2))
            Self.bad.withAlphaComponent(0.6).setStroke()
            circle.lineWidth = 2
            circle.setLineDash([4, 4], count: 2, phase: 0)
            circle.stroke()
            let label = palmFilter.state(of: dot.id) == .palm ? "palm" : "pend"
            drawText(label, at: CGPoint(x: p.x - 14, y: p.y - 8),
                     font: Self.monoBold, color: Self.bad)
        }
        if let c = snap.centroidNormalized {
            let p = viewPoint(normalized: c)
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: p.x - 6, y: p.y))
            cross.line(to: CGPoint(x: p.x + 6, y: p.y))
            cross.move(to: CGPoint(x: p.x, y: p.y - 6))
            cross.line(to: CGPoint(x: p.x, y: p.y + 6))
            Self.bright.setStroke()
            cross.lineWidth = 1.5
            cross.stroke()
            // Velocity arrow, flipped y, capped so flings stay on screen.
            let scale = 0.12
            var dx = snap.velocity.dx * scale
            var dy = -snap.velocity.dy * scale
            let len = (dx * dx + dy * dy).squareRoot()
            if len > 1 {
                let maxLen: CGFloat = 180
                if len > maxLen { dx *= maxLen / len; dy *= maxLen / len }
                let arrow = NSBezierPath()
                arrow.move(to: p)
                let tip = CGPoint(x: p.x + dx, y: p.y + dy)
                arrow.line(to: tip)
                Self.accent.setStroke()
                arrow.lineWidth = 3
                arrow.stroke()
                let head = NSBezierPath(ovalIn: NSRect(x: tip.x - 4, y: tip.y - 4, width: 8, height: 8))
                Self.accent.setFill()
                head.fill()
            }
        }
    }

    private func drawRecognizerPanel(_ snap: TrackpadGestureRecognizer.DebugSnapshot) {
        var lines: [(String, NSColor)] = []
        lines.append(("RECOGNIZER (raw NSTouch)", Self.dim))
        let stateColor: NSColor
        switch snap.state {
        case .committed: stateColor = Self.good
        case .locked: stateColor = Self.warn
        default: stateColor = Self.bright
        }
        lines.append(("state       \(snap.state.label)", stateColor))
        let locked = snap.lockedCount.map(String.init) ?? "-"
        lines.append(("touches     \(snap.touches.count)   locked \(locked)", Self.bright))
        lines.append((String(format: "translation dx %+7.1f  dy %+7.1f  |max| %5.1fpt",
                             snap.translation.dx, snap.translation.dy, snap.swipeSignal), Self.bright))
        lines.append((String(format: "spread      delta %+6.1fpt   scale x%.3f",
                             snap.spreadDelta, snap.scale), Self.bright))
        lines.append((String(format: "velocity    %+7.0f, %+7.0f pt/s",
                             snap.velocity.dx, snap.velocity.dy), Self.bright))
        lines.append((String(format: "device      %.0f x %.0f pt",
                             snap.deviceSize.width, snap.deviceSize.height), Self.dim))
        let cfg = recognizer.config
        lines.append((String(format: "thresholds  swipe %.0fpt [s/S]  pinch %.0fpt [p/P]  dom x%.2f",
                             cfg.swipeCommitThreshold, cfg.pinchCommitThreshold,
                             cfg.dominanceMargin), Self.dim))
        let recLine = recorder.isRecording
            ? "recording   ON (\(recorder.frameCount) frames) [r]"
            : "recording   off [r]"
        lines.append((recLine, recorder.isRecording ? Self.bad : Self.dim))
        lines.append(("touch input \(touchesEnabled ? "[.indirect]" : "OFF") [t]",
                      touchesEnabled ? Self.dim : Self.bad))
        let restingNow = restingByID.values.filter { $0 }.count
        lines.append(("resting     wants \(wantsRestingTouches ? "ON" : "off") [w]   now \(restingNow)   seen \(restingSeenCount)",
                      restingNow > 0 ? Self.warn : Self.dim))
        let bandPct = Int(palmFilter.config.bottomBand * 100)
        let filterLine = palmFilterEnabled
            ? "palm-filter ON [f]   band \(bandPct)%   suppressed \(suppressedDots.count)"
            : "palm-filter off [f]"
        lines.append((filterLine,
                      suppressedDots.isEmpty ? Self.dim : Self.warn))
        drawLines(lines, at: CGPoint(x: 16, y: 14))
    }

    private func drawOSEventPanel() {
        var lines: [(String, NSColor)] = []
        lines.append(("OS EVENTS (coexistence)", Self.dim))
        lines.append(("scroll      live \(scrollLiveCount)   momentum \(scrollMomentumCount)   legacy \(scrollLegacyCount)", Self.bright))
        lines.append(("  last      \(lastScrollInfo)", Self.dim))
        lines.append((String(format: "  accum     x %+8.1f   y %+8.1f", scrollAccum.x, scrollAccum.y), Self.dim))
        lines.append(("  during committed swipe: \(coincidentScrollCount) (observed, not acted on)",
                      coincidentScrollCount > 0 ? Self.warn : Self.dim))
        lines.append((String(format: "magnify     %d events   OS x%.3f  <-> ours above", magnifyCount, osMagnifyScale), Self.bright))
        lines.append(("  last      \(lastMagnifyInfo)", Self.dim))
        let swipeLine = "swipe(with:) \(swipeAPICount)  (premise: expected 0)"
        lines.append((swipeLine, swipeAPICount > 0 ? Self.bad : Self.dim))
        lines.append(("smartMagnify \(smartMagnifyCount)", Self.dim))
        drawLines(lines, at: CGPoint(x: max(16, bounds.width - 480), y: 14))
    }

    private func drawBottom(_ snap: TrackpadGestureRecognizer.DebugSnapshot) {
        if case .committed(let kind, let fingers) = snap.state {
            let text: String
            switch kind {
            case .swipe:
                text = "SWIPE \(snap.committedDirection.rawValue.uppercased()) \(fingers)F"
            case .pinch:
                text = String(format: "PINCH x%.2f %dF", snap.scale, fingers)
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.banner, .foregroundColor: Self.good]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: 20),
                                    withAttributes: attrs)
        }

        var lines: [(String, NSColor)] = []
        if let last = snap.lastEvent {
            lines.append(("last: \(Self.describe(last)) (\(last.phase.rawValue))", Self.accent))
        }
        for entry in eventLog.suffix(10) {
            lines.append((entry, entry.hasPrefix("ACTION") ? Self.good : Self.dim))
        }
        lines.append(("keys: [r]ecord  [c]lear counters  [t]ouch delivery  [w]ants resting  [f]ilter palms  [s/S] [p/P] thresholds", Self.dim))
        let lineHeight = Self.mono.pointSize + 4
        let y = bounds.height - CGFloat(lines.count) * lineHeight - 12
        drawLines(lines, at: CGPoint(x: 16, y: y))
    }

    private func drawLines(_ lines: [(String, NSColor)], at origin: CGPoint) {
        var y = origin.y
        for (text, color) in lines {
            drawText(text, at: CGPoint(x: origin.x, y: y), font: Self.mono, color: color)
            y += Self.mono.pointSize + 4
        }
    }

    private func drawText(_ text: String, at point: CGPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}
