//
//  DispatchTimeMatchers.swift
//  ReactiveSwift
//
//  Created by Christopher Liscio on 2016-09-29.
//  Copyright © 2016 GitHub. All rights reserved.
//

import Foundation
import Nimble

private let DefaultDelta: DispatchTimeInterval = .microseconds(10)

public func beCloseTo(_ expectedValue: DispatchWallTime, within delta: DispatchTimeInterval = DefaultDelta) -> NonNilMatcherFunc<DispatchWallTime> {
	return NonNilMatcherFunc { actualExpression, failureMessage in
		let actualValue = try actualExpression.evaluate()

		failureMessage.postfixMessage = "be close to <\(stringify(expectedValue))> (within \(stringify(delta)))"
		failureMessage.actualValue = "<\(stringify(actualValue))>"
		return actualValue != nil &&
			actualValue! <= (expectedValue + delta) &&
			actualValue! >= (expectedValue - delta)
	}
}
