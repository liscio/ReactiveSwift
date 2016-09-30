//
//  DispatchExtensions.swift
//  ReactiveSwift
//
//  Created by Christopher Liscio on 2016-09-29.
//  Copyright © 2016 GitHub. All rights reserved.
//

import Foundation

extension DispatchWallTime {
	static var zero = DispatchWallTime(timespec: timespec(tv_sec: 0, tv_nsec: 0))
}
