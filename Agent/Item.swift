//
//  Item.swift
//  Agent
//
//  Created by Harminder Sandhu on 2026-07-31.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
