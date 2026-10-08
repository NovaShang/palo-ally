import ObjectiveC
import XCTest

/// Real touches at exact times. XCUI's own gestures first wait for the app
/// to go idle, and an app with a reply streaming in never does: a "press
/// within 0.3–1 s of the tap" landed 3 s or more late. This plays a whole
/// script of touches as one synthesized event record (XCTest's private
/// XCPointerEventPath / XCSynthesizedEventRecord, the same ones its gestures
/// are built from), so the offsets between touches are exact and nothing
/// waits for idle. Points are screen points (portrait), like `frame`.
enum TouchScript {
    struct Touch {
        /// Seconds from the start of the script.
        var down: Double
        var at: CGPoint
        /// Where the finger is at which time; it moves in a straight line between.
        var moves: [(time: Double, to: CGPoint)] = []
        var up: Double

        static func tap(at p: CGPoint, time: Double) -> Touch { Touch(down: time, at: p, up: time + 0.05) }
        static func hold(at p: CGPoint, from: Double, for seconds: Double) -> Touch { Touch(down: from, at: p, up: from + seconds) }
        /// Down, a slow drag by `dy` over `over` seconds, a hold, then up.
        static func drag(at p: CGPoint, from: Double, dy: CGFloat, over: Double = 0.3, hold: Double = 0.2) -> Touch {
            let steps = 6
            let moves = (1...steps).map { i in
                (time: from + 0.05 + over * Double(i) / Double(steps), to: CGPoint(x: p.x, y: p.y + dy * CGFloat(i) / CGFloat(steps)))
            }
            return Touch(down: from, at: p, moves: moves, up: from + 0.05 + over + hold)
        }
    }

    /// Plays the touches and returns once they are done.
    static func play(_ touches: [Touch], name: String = "touch script") throws {
        guard let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type,
              let recordClass = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type
        else { throw XCTSkip("XCTest's event synthesis classes are not available") }

        typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject
        typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias InitRecord = @convention(c) (AnyObject, Selector, NSString, Int) -> AnyObject
        typealias AddPath = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Synthesize = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool

        func imp<T>(_ cls: AnyClass, _ name: String, as: T.Type) -> (T, Selector) {
            let sel = NSSelectorFromString(name)
            return (unsafeBitCast(class_getMethodImplementation(cls, sel), to: T.self), sel)
        }
        let (initPath, initPathSel) = imp(pathClass, "initForTouchAtPoint:offset:", as: InitPath.self)
        let (move, moveSel) = imp(pathClass, "moveToPoint:atOffset:", as: Move.self)
        let (lift, liftSel) = imp(pathClass, "liftUpAtOffset:", as: Lift.self)
        let (initRecord, initRecordSel) = imp(recordClass, "initWithName:interfaceOrientation:", as: InitRecord.self)
        let (addPath, addPathSel) = imp(recordClass, "addPointerEventPath:", as: AddPath.self)
        let (synthesize, synthesizeSel) = imp(recordClass, "synthesizeWithError:", as: Synthesize.self)

        // The objects are left to leak: a test process, a handful of them.
        let record = initRecord(recordClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue(),
                                initRecordSel, name as NSString, 1 /* portrait */)
        for t in touches {
            let path = initPath(pathClass.perform(NSSelectorFromString("alloc")).takeUnretainedValue(), initPathSel, t.at, t.down)
            for m in t.moves { move(path, moveSel, m.to, m.time) }
            lift(path, liftSel, t.up)
            addPath(record, addPathSel, path)
        }
        var error: Unmanaged<NSError>?
        guard synthesize(record, synthesizeSel, &error) else {
            throw error?.takeUnretainedValue() ?? NSError(domain: "TouchScript", code: 1)
        }
    }
}
