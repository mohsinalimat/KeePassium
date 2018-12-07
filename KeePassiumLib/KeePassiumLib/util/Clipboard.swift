//
//  Clipboard.swift
//  KeePassium
//
//  Created by Andrei Popleteev on 2018-05-27.
//  Copyright © 2018 Andrei Popleteev. All rights reserved.
//

import UIKit
import MobileCoreServices

public class Clipboard {

    public static let general = Clipboard()
    
    private var insertedText: String?
    private var insertedURL: URL?
    
    private init() {
        // left empty
    }
    
    /// Puts given URL to the pasteboard, and removes it after `timeout` seconds.
    public func insert(url: URL, timeout: Double) {
        Diag.debug("Inserted a URL to clipboard")
        insert(items: [[(kUTTypeURL as String) : url]], timeout: timeout)
        insertedURL = url
    }
    
    /// Puts given text to the pasteboard, and removes it after `timeout` seconds.
    public func insert(text: String, timeout: Double) {
        Diag.debug("Inserted a string to clipboard")
        insert(items: [[(kUTTypeUTF8PlainText as String) : text]], timeout: timeout)
        insertedText = text
    }
    
    private func insert(items: [[String: Any]], timeout: Double) {
        if timeout < 0 {
            // no timeout
            UIPasteboard.general.setItems(items, options: [.localOnly: true])
        } else {
            UIPasteboard.general.setItems(
                items,
                options: [
                    .localOnly: true,
                    .expirationDate: Date(timeIntervalSinceNow: timeout)
                ]
            )
        }
    }
    
    /// Removes previously inserted object from the pastebord.
    public func clear() {
        let pasteboard = UIPasteboard.general

        // Before cleanup, make sure it is *our* stuff in Pasteboard
        var containsOurStuff = false
        if let insertedText = insertedText {
            containsOurStuff = containsOurStuff || (pasteboard.string == insertedText)
        }
        if let insertedURL = insertedURL {
            containsOurStuff = containsOurStuff || (pasteboard.url == insertedURL)
        }
        
        if containsOurStuff {
            pasteboard.setItems([[:]], options: [.localOnly: true])
            self.insertedText = nil
            self.insertedURL = nil
            Diag.info("Clipboard content cleared")
        }
    }
}
