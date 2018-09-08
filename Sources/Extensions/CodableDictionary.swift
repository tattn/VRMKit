//
//  CodableDictionary.swift
//  VRMKit
//
//  Created by Tatsuya Tanaka on 20180908.
//  Copyright © 2018年 tattn. All rights reserved.
//

import Foundation

public struct CodableDictionary<Key: Hashable, Value: Codable>: Codable where Key: CodingKey {
    public let decoded: [Key: Value]
}

extension CodableDictionary {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)

        decoded = Dictionary(uniqueKeysWithValues:
            try container.allKeys.map {
                (key: $0, value: try container.decode(Value.self, forKey: $0))
            }
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)

        for (key, value) in decoded {
            try container.encode(value, forKey: key)
        }
    }
}
