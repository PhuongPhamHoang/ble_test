//
//  Data+Ext.swift
//  testBLE
//
//  Created by mobile on 23/4/25.
//

import Foundation

extension Data {
    var hex: String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
    
    var string: String? {
            return String(data: self, encoding: .utf8)
        }
}
