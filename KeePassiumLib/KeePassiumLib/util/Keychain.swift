//  KeePassium Password Manager
//  Copyright © 2018–2019 Andrei Popleteev <info@keepassium.com>
// 
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import Foundation

public enum KeychainError: LocalizedError {
    case generic(code: Int)
    case unexpectedFormat
    public var errorDescription: String? {
        switch self {
        case .generic(let code):
            return NSLocalizedString("Keychain error (code \(code)) ", comment: "Generic error message about system keychain, with an error code.")
        case .unexpectedFormat:
            return NSLocalizedString("Keychain error: unexpected data format", comment: "Error message about system keychain.")
        }
    }
}

public class Keychain {
    public static let shared = Keychain()
    
    private static let accessGroup: String? = nil
    private enum Service: String {
        static let allValues: [Service] = [.general, .databaseKeys]
        
        case general = "KeePassium"
        case databaseKeys = "KeePassium.dbKeys"
    }
    private let appPasscodeAccount = "appPasscode"
    
    private init() {
    }
    
    
    private func makeQuery(service: Service, account: String?) -> [String: AnyObject] {
        var result = [String: AnyObject]()
        result[kSecClass as String] = kSecClassGenericPassword
        result[kSecAttrService as String] = service.rawValue as AnyObject?
        if let account = account {
            result[kSecAttrAccount as String] = account as AnyObject?
        }
        if let accessGroup = Keychain.accessGroup {
            result[kSecAttrAccessGroup as String] = accessGroup as AnyObject?
        }
        return result
    }
    
    private func get(service: Service, account: String) throws -> Data? {
        var query = makeQuery(service: service, account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecReturnData as String] = kCFBooleanTrue
        
        var queryResult: AnyObject?
        let status = withUnsafeMutablePointer(to: &queryResult) { ptr in
            return SecItemCopyMatching(query as CFDictionary, ptr)
        }
        if status == errSecItemNotFound {
            return nil
        }
        guard status == noErr else {
            Diag.error("Keychain error [code: \(Int(status))]")
            throw KeychainError.generic(code: Int(status))
        }
        
        guard let item = queryResult as? [String: AnyObject],
              let data = item[kSecValueData as String] as? Data else
        {
            Diag.error("Keychain error: unexpected format")
            throw KeychainError.unexpectedFormat
        }
        return data
    }
    
    private func set(service: Service, account: String, data: Data) throws {
        if let _ = try get(service: service, account: account) { 
            let query = makeQuery(service: service, account: account)
            let attrsToUpdate = [kSecValueData as String : data as AnyObject?]
            let status = SecItemUpdate(query as CFDictionary, attrsToUpdate as CFDictionary)
            if status != noErr {
                Diag.error("Keychain error [code: \(Int(status))]")
                throw KeychainError.generic(code: Int(status))
            }
        } else {
            var newItem = makeQuery(service: service, account: account)
            newItem[kSecValueData as String] = data as AnyObject?
            let status = SecItemAdd(newItem as CFDictionary, nil)
            if status != noErr {
                Diag.error("Keychain error [code: \(Int(status))]")
                throw KeychainError.generic(code: Int(status))
            }
        }
    }
    
    private func remove(service: Service, account: String?) throws {
        let query = makeQuery(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        if status != noErr && status != errSecItemNotFound {
            Diag.error("Keychain error [code: \(Int(status))]")
            throw KeychainError.generic(code: Int(status))
        }
    }
    
    
    public func setAppPasscode(_ passcode: String) throws {
        let dataHash = ByteArray(utf8String: passcode).sha256.asData
        try set(service: .general, account: appPasscodeAccount, data: dataHash) 
    }

    public func isAppPasscodeSet() throws -> Bool {
        let storedHash = try get(service: .general, account: appPasscodeAccount) 
        return storedHash != nil
    }
    
    public func isAppPasscodeMatch(_ passcode: String) throws -> Bool {
        guard let storedHash =
            try get(service: .general, account: appPasscodeAccount) else
        {
            return false
        }
        let passcodeHash = ByteArray(utf8String: passcode).sha256.asData
        return passcodeHash == storedHash
    }

    public func removeAppPasscode() throws {
        try remove(service: .general, account: appPasscodeAccount) 
    }
    

    public func setDatabaseKey(databaseRef: URLReference, key: SecureByteArray) throws {
        guard !databaseRef.info.hasError else { return }
        
        let account = databaseRef.info.fileName
        try set(service: .databaseKeys, account: account, data: key.asData) 
    }

    public func getDatabaseKey(databaseRef: URLReference) throws -> SecureByteArray? {
        guard !databaseRef.info.hasError else { return nil }
        
        let account = databaseRef.info.fileName
        guard let data = try get(service: .databaseKeys, account: account) else {
            return nil
        }
        return SecureByteArray(data: data)
    }

    public func removeDatabaseKey(databaseRef: URLReference) throws {
        guard !databaseRef.info.hasError else { return }
        let account = databaseRef.info.fileName
        try remove(service: .databaseKeys, account: account)
    }
    
    public func removeAllDatabaseKeys() throws {
        try remove(service: .databaseKeys, account: nil)
    }
    
    public func removeAll() throws {
        for service in Service.allValues {
            try remove(service: service, account: nil) 
        }
    }
}
