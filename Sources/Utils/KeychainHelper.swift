//
//  KeychainHelper.swift
//  Grok for Mac
//
//  Created by Brandon Charleson on 2025.
//  Copyright © 2025 Brandon Charleson. All rights reserved.
//
//  https://github.com/bcharleson/xai-grok
//
//  Secure storage for sensitive data using macOS Keychain
//

import Foundation
import Security

/// A helper class for securely storing and retrieving sensitive data from the macOS Keychain
final class KeychainHelper {
    
    /// Shared singleton instance
    static let shared = KeychainHelper()
    
    /// Service identifier for the app's keychain items
    private let service = "com.grok.chat"
    
    private init() {}
    
    // MARK: - Public API
    
    /// Saves a string value to the Keychain
    /// - Parameters:
    ///   - value: The string to store
    ///   - key: The key to associate with the value
    /// - Returns: True if successful, false otherwise
    @discardableResult
    func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        return save(data, forKey: key)
    }
    
    /// Retrieves a string value from the Keychain
    /// - Parameter key: The key associated with the value
    /// - Returns: The stored string, or nil if not found
    func getString(forKey key: String) -> String? {
        guard let data = getData(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    /// Deletes a value from the Keychain
    /// - Parameter key: The key to delete
    /// - Returns: True if successful or item didn't exist, false on error
    @discardableResult
    func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    // MARK: - Private Helpers
    
    private func save(_ data: Data, forKey key: String) -> Bool {
        // First, try to delete any existing item
        delete(forKey: key)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        #if DEBUG
        if status != errSecSuccess {
            print("[Keychain] Save failed with status: \(status)")
        }
        #endif
        
        return status == errSecSuccess
    }
    
    private func getData(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            #if DEBUG
            if status != errSecItemNotFound {
                print("[Keychain] Read failed with status: \(status)")
            }
            #endif
            return nil
        }
        
        return result as? Data
    }
}

// MARK: - API Key Specific Extension

extension KeychainHelper {
    /// Key used for storing the xAI API key
    private static let apiKeyIdentifier = "xai_api_key"
    
    /// Saves the API key to Keychain
    @discardableResult
    func saveAPIKey(_ key: String) -> Bool {
        return save(key, forKey: Self.apiKeyIdentifier)
    }
    
    /// Retrieves the API key from Keychain
    func getAPIKey() -> String? {
        return getString(forKey: Self.apiKeyIdentifier)
    }
    
    /// Deletes the API key from Keychain
    @discardableResult
    func deleteAPIKey() -> Bool {
        return delete(forKey: Self.apiKeyIdentifier)
    }
    
    /// Migrates API key from UserDefaults to Keychain (one-time migration)
    func migrateAPIKeyFromUserDefaults() {
        let userDefaultsKey = "xai_api_key"
        
        // Check if there's a key in UserDefaults that needs migration
        if let oldKey = UserDefaults.standard.string(forKey: userDefaultsKey), !oldKey.isEmpty {
            // Only migrate if Keychain doesn't already have a key
            if getAPIKey() == nil {
                if saveAPIKey(oldKey) {
                    // Successfully migrated - remove from UserDefaults
                    UserDefaults.standard.removeObject(forKey: userDefaultsKey)
                    #if DEBUG
                    print("[Keychain] Successfully migrated API key from UserDefaults")
                    #endif
                }
            } else {
                // Keychain already has a key, just clean up UserDefaults
                UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            }
        }
    }
}

