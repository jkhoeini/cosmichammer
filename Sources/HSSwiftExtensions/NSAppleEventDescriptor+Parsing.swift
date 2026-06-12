//
//  NSAppleEventDescriptor+Parsing.swift
//  Cosmic Hammer
//
//  Created by Michael Bujol on 2/25/16.
//  Copyright (c) 2016 Cosmic Hammer. All rights reserved.
//
//  Adapted from https://developer.apple.com/library/mac/samplecode/sc2280/Listings/SimpleAssetManagerSample_ScriptingSupportCategories_m.html
//

import Foundation
import Carbon
import os.log

// MARK: - NSDictionary (UserDefinedRecord)

extension NSDictionary {
    /// AppleEvent record descriptor (typeAERecord) with arbitrary keys
    static func scriptingUserDefinedRecord(with desc: NSAppleEventDescriptor) -> NSDictionary {
        let dict = NSMutableDictionary(capacity: 0)

        // keyASUserRecordFields has a list of alternating keys and values
        guard let userFieldItems = desc.forKeyword(AEKeyword(keyASUserRecordFields)) else {
            return NSDictionary(dictionary: dict)
        }
        let numItems = userFieldItems.numberOfItems

        var itemIndex = 1
        while itemIndex <= numItems - 1 {
            let keyDesc = userFieldItems.atIndex(itemIndex)!
            let valueDesc = userFieldItems.atIndex(itemIndex + 1)!

            // convert key and value to Foundation object
            // note the value can be another record or list
            let keyString = keyDesc.stringValue
            let value = valueDesc.objectValue

            if let keyString = keyString, let value = value {
                dict.setObject(value, forKey: keyString as NSString)
            }

            itemIndex += 2
        }

        return NSDictionary(dictionary: dict)
    }
}

// MARK: - NSArray (UserList)

extension NSArray {
    /// AppleEvent list descriptor (typeAEList)
    static func scriptingUserList(with desc: NSAppleEventDescriptor) -> NSArray {
        let array = NSMutableArray(capacity: 0)
        let numItems = desc.numberOfItems

        // for each item in the list, convert to Foundation object and add to the array
        for itemIndex in 1...Swift.max(1, numItems) {
            guard itemIndex <= numItems else { break }
            let itemDesc = desc.atIndex(itemIndex)!
            if let objectValue = itemDesc.objectValue {
                array.add(objectValue)
            }
        }

        return NSArray(array: array)
    }
}

// MARK: - NSAppleEventDescriptor (GenericObject)

extension NSAppleEventDescriptor {
    /// AppleEvent descriptor that may be a record, a list, or other object
    /// This is necessary to handle a list or a record contained in another list or record
    var objectValue: Any? {
        let descType = self.descriptorType

        var object: Any? = nil

        switch descType {
        case typeUnicodeText, typeUTF8Text, typeFileURL:
            object = self.stringValue

        case typeTrue:
            object = NSNumber(value: self.booleanValue)

        case typeFalse:
            object = NSNumber(value: self.booleanValue)

        case typeAEList:
            object = NSArray.scriptingUserList(with: self)

        case typeAERecord:
            object = NSDictionary.scriptingUserDefinedRecord(with: self)

        case typeSInt16, typeUInt16, typeSInt32, typeUInt32, typeSInt64, typeUInt64:
            object = NSNumber(value: Int(self.int32Value))

        case typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint:
            object = NSNumber(value: self.doubleValue)

        case typeNull, typeType:
            object = NSNull()

        default:
            object = self.stringValue
        }

        if object == nil {
            // FIXME: Do better logging here
            os_log(.error, "ERROR: NSAppleEventDescriptor objectValue is nil. Given descriptorType is: %u", descType)
        }

        return object
    }
}
