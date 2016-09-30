//
//  Scheduler.swift
//  ReactiveSwift
//
//  Created by Justin Spahr-Summers on 2014-06-02.
//  Copyright (c) 2014 GitHub. All rights reserved.
//

import Dispatch
import Foundation

#if os(Linux)
	import CDispatch
#endif

/// Represents a serial queue of work items.
public protocol SchedulerProtocol {
	/// Enqueues an action on the scheduler.
	///
	/// When the work is executed depends on the scheduler in use.
	///
	/// - returns: Optional `Disposable` that can be used to cancel the work
	///            before it begins.
	@discardableResult
	func schedule(_ action: @escaping () -> Void) -> Disposable?
}

/// A particular kind of scheduler that supports enqueuing actions at future
/// dates.
public protocol TimedSchedulerProtocol: SchedulerProtocol {
	/// The current date, as determined by this scheduler.
	///
	/// This can be implemented to deterministically return a known date (e.g.,
	/// for testing purposes).
	var currentTime: DispatchWallTime { get }

	/// Schedules an action for execution at or after the given date.
	///
	/// - parameters:
	///   - date: Starting time.
	///   - action: Closure of the action to perform.
	///
	/// - returns: Optional `Disposable` that can be used to cancel the work
	///            before it begins.
	@discardableResult
	func schedule(after time: DispatchWallTime, action: @escaping () -> Void) -> Disposable?

	/// Schedules a recurring action at the given interval, beginning at the
	/// given date.
	///
	/// - parameters:
	///   - date: Starting time.
	///   - repeatingEvery: Repetition interval.
	///   - withLeeway: Some delta for repetition.
	///   - action: Closure of the action to perform.
	///
	/// - returns: Optional `Disposable` that can be used to cancel the work
	///            before it begins.
	@discardableResult
	func schedule(after time: DispatchWallTime, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, action: @escaping () -> Void) -> Disposable?
}

/// A scheduler that performs all work synchronously.
public final class ImmediateScheduler: SchedulerProtocol {
	public init() {}

	/// Immediately calls passed in `action`.
	///
	/// - parameters:
	///   - action: Closure of the action to perform.
	///
	/// - returns: `nil`.
	@discardableResult
	public func schedule(_ action: @escaping () -> Void) -> Disposable? {
		action()
		return nil
	}
}

/// A scheduler that performs all work on the main queue, as soon as possible.
///
/// If the caller is already running on the main queue when an action is
/// scheduled, it may be run synchronously. However, ordering between actions
/// will always be preserved.
public final class UIScheduler: SchedulerProtocol {
	private static let dispatchSpecificKey = DispatchSpecificKey<UInt8>()
	private static let dispatchSpecificValue = UInt8.max
	private static var __once: () = {
			DispatchQueue.main.setSpecific(key: UIScheduler.dispatchSpecificKey,
			                               value: dispatchSpecificValue)
	}()

	#if os(Linux)
	private var queueLength: Atomic<Int32> = Atomic(0)
	#else
	private var queueLength: Int32 = 0
	#endif

	/// Initializes `UIScheduler`
	public init() {
		/// This call is to ensure the main queue has been setup appropriately
		/// for `UIScheduler`. It is only called once during the application
		/// lifetime, since Swift has a `dispatch_once` like mechanism to
		/// lazily initialize global variables and static variables.
		_ = UIScheduler.__once
	}

	/// Queues an action to be performed on main queue. If the action is called
	/// on the main thread and no work is queued, no scheduling takes place and
	/// the action is called instantly.
	///
	/// - parameters:
	///   - action: Closure of the action to perform on the main thread.
	///
	/// - returns: `Disposable` that can be used to cancel the work before it
	///            begins.
	@discardableResult
	public func schedule(_ action: @escaping () -> Void) -> Disposable? {
		let disposable = SimpleDisposable()
		let actionAndDecrement = {
			if !disposable.isDisposed {
				action()
			}

			#if os(Linux)
				self.queueLength.modify { $0 -= 1 }
			#else
				OSAtomicDecrement32(&self.queueLength)
			#endif
		}

		#if os(Linux)
			let queued = self.queueLength.modify { value -> Int32 in
				value += 1
				return value
			}
		#else
			let queued = OSAtomicIncrement32(&queueLength)
		#endif

		// If we're already running on the main queue, and there isn't work
		// already enqueued, we can skip scheduling and just execute directly.
		if queued == 1 && DispatchQueue.getSpecific(key: UIScheduler.dispatchSpecificKey) == UIScheduler.dispatchSpecificValue {
			actionAndDecrement()
		} else {
			DispatchQueue.main.async(execute: actionAndDecrement)
		}

		return disposable
	}
}

/// A scheduler backed by a serial GCD queue.
public final class QueueScheduler: TimedSchedulerProtocol {
	/// A singleton `QueueScheduler` that always targets the main thread's GCD
	/// queue.
	///
	/// - note: Unlike `UIScheduler`, this scheduler supports scheduling for a
	///         future date, and will always schedule asynchronously (even if 
	///         already running on the main thread).
	public static let main = QueueScheduler(internalQueue: DispatchQueue.main)

	public var currentTime: DispatchWallTime {
		return .now()
	}

	public let queue: DispatchQueue
	
	internal init(internalQueue: DispatchQueue) {
		queue = internalQueue
	}
	
	/// Initializes a scheduler that will target the given queue with its
	/// work.
	///
	/// - note: Even if the queue is concurrent, all work items enqueued with
	///         the `QueueScheduler` will be serial with respect to each other.
	///
	/// - warning: Obsoleted in OS X 10.11
	@available(OSX, deprecated:10.10, obsoleted:10.11, message:"Use init(qos:name:targeting:) instead")
	@available(iOS, deprecated:8.0, obsoleted:9.0, message:"Use init(qos:name:targeting:) instead.")
	public convenience init(queue: DispatchQueue, name: String = "org.reactivecocoa.ReactiveSwift.QueueScheduler") {
		self.init(internalQueue: DispatchQueue(label: name, target: queue))
	}

	/// Initializes a scheduler that creates a new serial queue with the
	/// given quality of service class.
	///
	/// - parameters:
	///   - qos: Dispatch queue's QoS value.
	///   - name: Name for the queue in the form of reverse domain.
	///   - targeting: (Optional) The queue on which this scheduler's work is
	///     targeted
	@available(OSX 10.10, *)
	public convenience init(
		qos: DispatchQoS = .default,
		name: String = "org.reactivecocoa.ReactiveSwift.QueueScheduler",
		targeting targetQueue: DispatchQueue? = nil
	) {
		self.init(internalQueue: DispatchQueue(
			label: name,
			qos: qos,
			target: targetQueue
		))
	}

	/// Schedules action for dispatch on internal queue
	///
	/// - parameters:
	///   - action: Closure of the action to schedule.
	///
	/// - returns: `Disposable` that can be used to cancel the work before it
	///            begins.
	@discardableResult
	public func schedule(_ action: @escaping () -> Void) -> Disposable? {
		let d = SimpleDisposable()

		queue.async {
			if !d.isDisposed {
				action()
			}
		}

		return d
	}

	private func wallTime(with date: Date) -> DispatchWallTime {
		let (seconds, frac) = modf(date.timeIntervalSince1970)

		let nsec: Double = frac * Double(NSEC_PER_SEC)
		let walltime = timespec(tv_sec: Int(seconds), tv_nsec: Int(nsec))

		return DispatchWallTime(timespec: walltime)
	}

	/// Schedules an action for execution at or after the given date.
	///
	/// - parameters:
	///   - date: Starting time.
	///   - action: Closure of the action to perform.
	///
	/// - returns: Optional `Disposable` that can be used to cancel the work
	///            before it begins.
	@discardableResult
	public func schedule(after time: DispatchWallTime, action: @escaping () -> Void) -> Disposable? {
		let d = SimpleDisposable()

		queue.asyncAfter(wallDeadline: time) {
			if !d.isDisposed {
				action()
			}
		}

		return d
	}

	/// Schedules a recurring action at the given interval and beginning at the
	/// given start time. A reasonable default timer interval leeway is
	/// provided.
	///
	/// - parameters:
	///   - date: Date to schedule the first action for.
	///   - repeatingEvery: Repetition interval.
	///   - action: Closure of the action to repeat.
	///
	/// - returns: Optional disposable that can be used to cancel the work
	///            before it begins.
	@discardableResult
	public func schedule(after time: DispatchWallTime, interval: DispatchTimeInterval, action: @escaping () -> Void) -> Disposable? {
		// Apple's "Power Efficiency Guide for Mac Apps" recommends a leeway of
		// at least 10% of the timer interval.
		return schedule(after: time, interval: interval, leeway: /* TODO: Not sure what to do in this case! (interval * 0.1) */ .microseconds(100), action: action)
	}

	/// Schedules a recurring action at the given interval with provided leeway,
	/// beginning at the given start time.
	///
	/// - parameters:
	///   - date: Date to schedule the first action for.
	///   - repeatingEvery: Repetition interval.
	///   - leeway: Some delta for repetition interval.
	///   - action: Closure of the action to repeat.
	///
	/// - returns: Optional `Disposable` that can be used to cancel the work
	///            before it begins.
	@discardableResult
	public func schedule(after time: DispatchWallTime, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, action: @escaping () -> Void) -> Disposable? {
		precondition(.zero + interval >= .zero)
		precondition(.zero + leeway >= .zero)

		let timer = DispatchSource.makeTimerSource(
			flags: DispatchSource.TimerFlags(rawValue: UInt(0)),
			queue: queue
		)
		timer.scheduleRepeating(wallDeadline: time,
		                        interval: interval,
		                        leeway: leeway)
		timer.setEventHandler(handler: action)
		timer.resume()

		return ActionDisposable {
			timer.cancel()
		}
	}
}

/// A scheduler that implements virtualized time, for use in testing.
public final class TestScheduler: TimedSchedulerProtocol {
	private final class ScheduledAction {
		let time: DispatchWallTime
		let action: () -> Void

		init(time: DispatchWallTime, action: @escaping () -> Void) {
			self.time = time
			self.action = action
		}

		func less(_ rhs: ScheduledAction) -> Bool {
			return time < rhs.time
		}
	}

	private let lock = NSRecursiveLock()
	private var _currentTime: DispatchWallTime

	/// The virtual date that the scheduler is currently at.
	public var currentTime: DispatchWallTime {
		let t: DispatchWallTime

		lock.lock()
		t = _currentTime
		lock.unlock()

		return t
	}

	private var scheduledActions: [ScheduledAction] = []

	/// Initializes a TestScheduler with the given start date.
	///
	/// - parameters:
	///   - startDate: The start date of the scheduler.
	public init(startTime: DispatchWallTime = .zero) {
		lock.name = "org.reactivecocoa.ReactiveSwift.TestScheduler"
		_currentTime = startTime
	}

	private func schedule(_ action: ScheduledAction) -> Disposable {
		lock.lock()
		scheduledActions.append(action)
		scheduledActions.sort { $0.less($1) }
		lock.unlock()

		return ActionDisposable {
			self.lock.lock()
			self.scheduledActions = self.scheduledActions.filter { $0 !== action }
			self.lock.unlock()
		}
	}

	/// Enqueues an action on the scheduler.
	///
	/// - note: The work is executed at `currentTime` as it is understood by the
	///         scheduler.
	///
	/// - parameters:
	///   - action: An action that will be performed on scheduler's
	///             `currentTime`.
	///
	/// - returns: Optional `Disposable` that can be used to cancel the work
	///            before it begins.
	@discardableResult
	public func schedule(_ action: @escaping () -> Void) -> Disposable? {
		return schedule(ScheduledAction(time: currentTime, action: action))
	}

	/// Schedules an action for execution at or after the given date.
	///
	/// - parameters:
	///   - date: Starting date.
	///   - action: Closure of the action to perform.
	///
	/// - returns: Optional disposable that can be used to cancel the work
	///            before it begins.
	@discardableResult
	public func schedule(after delay: DispatchTimeInterval, action: @escaping () -> Void) -> Disposable? {
		return schedule(after: currentTime + delay, action: action)
	}

	@discardableResult
	public func schedule(after time: DispatchWallTime, action: @escaping () -> Void) -> Disposable? {
		return schedule(ScheduledAction(time: time, action: action))
	}

	/// Schedules a recurring action at the given interval, beginning at the
	/// given start time
	///
	/// - parameters:
	///   - date: Date to schedule the first action for.
	///   - repeatingEvery: Repetition interval.
	///   - action: Closure of the action to repeat.
	///
	/// - returns: Optional `Disposable` that can be used to cancel the work
	///            before it begins.
	private func schedule(after time: DispatchWallTime, interval: DispatchTimeInterval, disposable: SerialDisposable, action: @escaping () -> Void) {
		precondition(.zero + interval >= .zero)

		disposable.innerDisposable = schedule(after: time) { [unowned self] in
			action()
			self.schedule(after: time + interval, interval: interval, disposable: disposable, action: action)
		}
	}

	/// Schedules a recurring action at the given interval, beginning at the
	/// given interval (counted from `currentTime`).
	///
	/// - parameters:
	///   - interval: Interval to add to `currentTime`.
	///   - repeatingEvery: Repetition interval.
	///	  - leeway: Some delta for repetition interval.
	///   - action: Closure of the action to repeat.
	///
	/// - returns: Optional `Disposable` that can be used to cancel the work
	///            before it begins.
	@discardableResult
	public func schedule(after delay: DispatchTimeInterval, interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .nanoseconds(0), action: @escaping () -> Void) -> Disposable? {
		return schedule(after: currentTime + delay, interval: interval, leeway: leeway, action: action)
	}

	/// Schedules a recurring action at the given interval with
	/// provided leeway, beginning at the given start time.
	///
	/// - parameters:
	///   - date: Date to schedule the first action for.
	///   - repeatingEvery: Repetition interval.
	///	  - leeway: Some delta for repetition interval.
	///   - action: Closure of the action to repeat.
	///
	/// - returns: Optional `Disposable` that can be used to cancel the work
	///	           before it begins.
	public func schedule(after time: DispatchWallTime, interval: DispatchTimeInterval, leeway: DispatchTimeInterval = .nanoseconds(0), action: @escaping () -> Void) -> Disposable? {
		let disposable = SerialDisposable()
		schedule(after: time, interval: interval, disposable: disposable, action: action)
		return disposable
	}

	/// Advances the virtualized clock by an extremely tiny interval, dequeuing
	/// and executing any actions along the way.
	///
	/// This is intended to be used as a way to execute actions that have been
	/// scheduled to run as soon as possible.
	public func advance() {
		advance(by: .nanoseconds(1))
	}

	/// Advances the virtualized clock by the given interval, dequeuing and
	/// executing any actions along the way.
	///
	/// - parameters:
	///   - interval: Interval by which the current date will be advanced.
	public func advance(by interval: DispatchTimeInterval) {
		lock.lock()
		advance(to: currentTime + interval)
		lock.unlock()
	}

	/// Advances the virtualized clock to the given future date, dequeuing and
	/// executing any actions up until that point.
	///
	/// - parameters:
	///   - newDate: Future date to which the virtual clock will be advanced.
	public func advance(to newTime: DispatchWallTime) {
		lock.lock()

		assert(currentTime <= newTime)

		while scheduledActions.count > 0 {
			if newTime < scheduledActions[0].time {
				break
			}

			_currentTime = scheduledActions[0].time

			let scheduledAction = scheduledActions.remove(at: 0)
			scheduledAction.action()
		}

		_currentTime = newTime

		lock.unlock()
	}

	/// Dequeues and executes all scheduled actions, leaving the scheduler's
	/// time at `DispatchWallTime.distantFuture`.
	public func run() {
		advance(to: .distantFuture)
	}
	
	/// Rewinds the virtualized clock by the given interval.
	/// This simulates that user changes device date.
	///
	/// - parameters:
	///   - interval: Interval by which the current date will be retreated.
	public func rewind(by interval: DispatchTimeInterval) {
		lock.lock()
		
		let newTime = currentTime - interval
		assert(currentTime >= newTime)
		_currentTime = newTime
		
		lock.unlock()
		
	}
}
