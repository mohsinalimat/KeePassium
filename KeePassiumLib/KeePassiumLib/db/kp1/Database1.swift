//  KeePassium Password Manager
//  Copyright © 2018–2019 Andrei Popleteev <info@keepassium.com>
// 
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import Foundation

public class Database1: Database {
    public enum FormatError: LocalizedError {
        case prematureDataEnd
        case corruptedField(fieldName: String?)
        case orphanedEntry
        public var errorDescription: String? {
            switch self {
            case .prematureDataEnd:
                return NSLocalizedString("Unexpected end of file. Corrupted DB file?", comment: "Error message")
            case .corruptedField(let fieldName):
                if fieldName != nil {
                    return NSLocalizedString("Error parsing field \(fieldName!). Corrupted DB file?", comment: "Error message, with the name of problematic field")
                } else {
                    return NSLocalizedString("Database file is corrupted.", comment: "Error message")
                }
            case .orphanedEntry:
                return NSLocalizedString("Found an entry outside any group. Corrupted DB file?", comment: "Error message")
            }
        }
    }
    
    private enum ProgressSteps {
        static let all: Int64 = 100
        static let keyDerivation: Int64 = 60
        
        static let decryption: Int64 = 30
        static let parsing: Int64 = 10

        static let encryption: Int64 = 30
        static let packing: Int64 = 10
    }
    
    override public var keyHelper: KeyHelper { return _keyHelper }
    private let _keyHelper = KeyHelper1()
    
    private(set) var header: Header1!
    private(set) var masterKey = SecureByteArray()
    private(set) var backupGroup: Group1?
    private var metaStreamEntries = ContiguousArray<Entry1>()

    override public init() {
        super.init()
        header = Header1(database: self)
    }
    deinit {
        erase()
    }
    override public func erase() {
        header.erase()
        compositeKey.erase()
        masterKey.erase()
        backupGroup?.erase()
        backupGroup = nil
        for metaEntry in metaStreamEntries {
            metaEntry.erase()
        }
        metaStreamEntries.removeAll()
        Diag.debug("Database erased")
    }

    func createNewGroupID() -> Group1ID {
        var groups = Array<Group>()
        var entries = Array<Entry>()
        if let root = root {
            root.collectAllChildren(groups: &groups, entries: &entries)
        } else {
            Diag.warning("Creating a new Group1ID for an empty database")
            assertionFailure("Creating new Group1ID for an empty database")
        }
        
        var takenIDs = ContiguousArray<Int32>()
        takenIDs.reserveCapacity(groups.count)
        var maxID: Int32 = 0
        for group in groups {
            let id = (group as! Group1).id
            if id > maxID { maxID = id}
            takenIDs.append(id)
        }
        groups.removeAll()
        entries.removeAll()
        
        var newID = maxID + 1
        while takenIDs.contains(newID) {
            newID = newID &+ 1 
        }
        return newID
    }
    
    override public func getBackupGroup(createIfMissing: Bool) -> Group? {
        guard let root = root else {
            Diag.warning("Tried to get Backup group without the root one")
            assertionFailure()
            return nil
        }
        
        if backupGroup == nil && createIfMissing {
            let newBackupGroup = root.createGroup() as! Group1
            newBackupGroup.name = Group1.backupGroupName
            newBackupGroup.iconID = Group1.backupGroupIconID
            newBackupGroup.isDeleted = true
            backupGroup = newBackupGroup
        }
        return backupGroup
    }

    override public class func isSignatureMatches(data: ByteArray) -> Bool {
        return Header1.isSignatureMatches(data: data)
    }

    override public func changeCompositeKey(to newKey: SecureByteArray) {
        compositeKey = newKey
    }
    
    override public func load(
        dbFileData: ByteArray,
        compositeKey: SecureByteArray,
        warnings: DatabaseLoadingWarnings
    ) throws {
        Diag.info("Loading KP1 database")
        progress.completedUnitCount = 0
        progress.totalUnitCount = ProgressSteps.all
        do {
            try header.read(data: dbFileData) 
            Diag.debug("Header read OK")
            
            try deriveMasterKey(compositeKey: compositeKey)
            Diag.debug("Key derivation OK")
            
            let dbWithoutHeader = dbFileData.suffix(from: header.count)
            let decryptedData = try decrypt(data: dbWithoutHeader)
            Diag.debug("Decryption OK")
            guard decryptedData.sha256 == header.contentHash else {
                Diag.error("Header hash mismatch - invalid master key?")
                throw DatabaseError.invalidKey
            }
            
            try loadContent(data: decryptedData) 
            Diag.debug("Content loaded OK")

            self.compositeKey = compositeKey
        } catch let error as Header1.Error {
            Diag.error("Header error [reason: \(error.localizedDescription)]")
            throw DatabaseError.loadError(reason: error.localizedDescription)
        } catch let error as CryptoError {
            Diag.error("Crypto error [reason: \(error.localizedDescription)]")
            throw DatabaseError.loadError(reason: error.localizedDescription)
        } catch let error as FormatError {
            Diag.error("Format error [reason: \(error.localizedDescription)]")
            throw DatabaseError.loadError(reason: error.localizedDescription)
        } 
    }
    
    func deriveMasterKey(compositeKey: SecureByteArray) throws {
        Diag.debug("Start key derivation")
        let kdf = AESKDF()
        progress.addChild(kdf.initProgress(), withPendingUnitCount: ProgressSteps.keyDerivation)
        let kdfParams = kdf.defaultParams
        kdfParams.setValue(
            key: AESKDF.transformSeedParam,
            value: VarDict.TypedValue(value: header.transformSeed))
        kdfParams.setValue(
            key: AESKDF.transformRoundsParam,
            value: VarDict.TypedValue(value: UInt64(header.transformRounds)))
        
        let transformedKey = try kdf.transform(key: compositeKey, params: kdfParams)
        masterKey = SecureByteArray(ByteArray.concat(header.masterSeed, transformedKey).sha256)
    }
    
    private func loadContent(data: ByteArray) throws {
        let stream = data.asInputStream()
        stream.open()
        defer { stream.close() }
        
        let loadProgress = ProgressEx()
        loadProgress.totalUnitCount = Int64(header.groupCount + header.entryCount)
        loadProgress.localizedDescription = NSLocalizedString("Parsing content", comment: "Status message: processing the content of a database")
        self.progress.addChild(loadProgress, withPendingUnitCount: ProgressSteps.parsing)
        
        Diag.debug("Loading groups")
        var groups = ContiguousArray<Group1>()
        var groupByID = [Group1ID : Group1]() 
        var maxLevel = 0                      
        for _ in 0..<header.groupCount {
            loadProgress.completedUnitCount += 1
            let group = Group1(database: self)
            try group.load(from: stream) 
            if group.isDeleted {
                backupGroup = group
            }
            if group.level > maxLevel {
                maxLevel = Int(group.level)
            }
            groupByID[group.id] = group
            groups.append(group)
        }

        Diag.debug("Loading entries")
        var entries = ContiguousArray<Entry1>()
        for _ in 0..<header.entryCount {
            let entry = Entry1(database: self)
            try entry.load(from: stream) 
            entries.append(entry)
            loadProgress.completedUnitCount += 1
            if loadProgress.isCancelled {
                throw ProgressInterruption.cancelled(reason: loadProgress.cancellationReason)
            }
        }
        Diag.info("Loaded \(groups.count) groups and \(entries.count) entries")
        
        let _root = Group1(database: self)
        _root.level = -1 
        _root.iconID = Group.defaultIconID 
        _root.name = "/" // TODO: give the "virtual" root group a more meaningful name
        self.root = _root
        
        var parentGroup = _root
        for level in 0...maxLevel {
            let prevLevel = level - 1
            for group in groups {
                if group.level == level {
                    parentGroup.add(group: group)
                } else if group.level == prevLevel {
                    parentGroup = group
                }
            }
        }
        
        Diag.debug("Moving entries to their groups")
        for entry in entries {
            if entry.isMetaStream {
                metaStreamEntries.append(entry);
            } else {
                guard let group = groupByID[entry.groupID] else { throw FormatError.orphanedEntry }
                entry.isDeleted = group.isDeleted
                group.add(entry: entry)
            }
        }
    }
    
    func decrypt(data: ByteArray) throws -> ByteArray {
        switch header.algorithm {
        case .aes:
            Diag.debug("Decrypting AES cipher")
            let cipher = AESDataCipher()
            progress.addChild(cipher.initProgress(), withPendingUnitCount: ProgressSteps.decryption)
            let decrypted = try cipher.decrypt(cipherText: data, key: masterKey, iv: header.initialVector)
            return decrypted
        case .twofish:
            Diag.debug("Decrypting Twofish cipher")
            let cipher = TwofishDataCipher(isPaddingLikelyMessedUp: false)
            progress.addChild(cipher.initProgress(), withPendingUnitCount: ProgressSteps.decryption)
            let decrypted = try cipher.decrypt(cipherText: data, key: masterKey, iv: header.initialVector)
            return decrypted
        }
    }
    
    override public func save() throws -> ByteArray {
        Diag.info("Saving KP1 database")
        let contentStream = ByteArray.makeOutputStream()
        contentStream.open()
        guard let root = root else { fatalError("Tried to save without root group") }
        
        progress.completedUnitCount = 0
        progress.totalUnitCount = ProgressSteps.all
        do {
            var groups = Array<Group>()
            var entries = Array<Entry>()
            root.collectAllChildren(groups: &groups, entries: &entries)
            Diag.info("Saving \(groups.count) groups and \(entries.count)+\(metaStreamEntries.count) entries")
            
            let packingProgress = ProgressEx()
            packingProgress.totalUnitCount = Int64(groups.count + entries.count + metaStreamEntries.count)
            packingProgress.localizedDescription = NSLocalizedString("Packing the content", comment: "Status message: collecting database items into a single package")
            progress.addChild(packingProgress, withPendingUnitCount: ProgressSteps.packing)
            Diag.debug("Packing the content")
            for group in groups {
                (group as! Group1).write(to: contentStream)
                packingProgress.completedUnitCount += 1
            }
            for entry in entries {
                (entry as! Entry1).write(to: contentStream)
                packingProgress.completedUnitCount += 1
                if packingProgress.isCancelled {
                    throw ProgressInterruption.cancelled(reason: packingProgress.cancellationReason)
                }
            }
            Diag.debug("Writing meta-stream entries")
            for metaEntry in metaStreamEntries {
                metaEntry.write(to: contentStream)
                print("Wrote a meta-stream entry: \(metaEntry.notes)")
                packingProgress.completedUnitCount += 1
                if packingProgress.isCancelled {
                    throw ProgressInterruption.cancelled(reason: packingProgress.cancellationReason)
                }
            }
            contentStream.close()
            guard let contentData = contentStream.data else { fatalError() }
        
            Diag.debug("Updating the header")
            header.groupCount = groups.count
            header.entryCount = entries.count + metaStreamEntries.count
            header.contentHash = contentData.sha256
        
            try header.randomizeSeeds() 
            try deriveMasterKey(compositeKey: self.compositeKey)
            Diag.debug("Key derivation OK")
            
            let encryptedContent = try encrypt(data: contentData)
            Diag.debug("Content encryption OK")
            
            let outStream = ByteArray.makeOutputStream()
            outStream.open()
            defer { outStream.close() }
            header.write(to: outStream)
            outStream.write(data: encryptedContent)
            return outStream.data!
        } catch let error as CryptoError {
            throw DatabaseError.saveError(reason: error.localizedDescription)
        } 
    }
    
    func encrypt(data: ByteArray) throws -> ByteArray {
        switch header.algorithm {
        case .aes:
            Diag.debug("Encrypting AES")
            let cipher = AESDataCipher()
            progress.addChild(cipher.initProgress(), withPendingUnitCount: ProgressSteps.encryption)
            return try cipher.encrypt(
                plainText: data,
                key: masterKey,
                iv: header.initialVector) 
        case .twofish:
            Diag.debug("Encrypting Twofish")
            let cipher = TwofishDataCipher(isPaddingLikelyMessedUp: false)
            progress.addChild(cipher.initProgress(), withPendingUnitCount: ProgressSteps.encryption)
            return try cipher.encrypt(
                plainText: data,
                key: masterKey,
                iv: header.initialVector) 
        }
    }
    
    
    override public func delete(group: Group) {
        guard let group = group as? Group1 else { fatalError() }
        guard let parentGroup = group.parent else {
            Diag.warning("Cannot delete group: no parent group")
            return
        }
        
        guard let backupGroup = getBackupGroup(createIfMissing: true) else {
            Diag.warning("Cannot delete group: no backup group")
            return
        }
        
        parentGroup.remove(group: group)
        
        var subEntries = [Entry]()
        group.collectAllEntries(to: &subEntries)
        
        subEntries.forEach { (entry) in
            backupGroup.moveEntry(entry: entry)
            entry.accessed()
        }
        Diag.debug("Delete group OK")
    }
    
    override public func delete(entry: Entry) {
        if entry.isDeleted {
            entry.parent?.remove(entry: entry)
            return
        }
        
        guard let backupGroup = getBackupGroup(createIfMissing: true) else {
            Diag.warning("Failed to get or create backup group")
            return
        }
        
        entry.accessed()
        backupGroup.moveEntry(entry: entry)
        Diag.info("Delete entry OK")
    }
    
    override public func makeAttachment(name: String, data: ByteArray) -> Attachment {
        return Attachment(name: name, isCompressed: false, data: data)
    }
}
