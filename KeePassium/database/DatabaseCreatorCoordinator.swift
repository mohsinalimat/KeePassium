//  KeePassium Password Manager
//  Copyright © 2018–2019 Andrei Popleteev <info@keepassium.com>
// 
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import UIKit
import KeePassiumLib

protocol DatabaseCreatorCoordinatorDelegate: class {
    func didCreateDatabase(
        in databaseCreatorCoordinator: DatabaseCreatorCoordinator,
        database urlRef: URLReference)
    func didPressCancel(in databaseCreatorCoordinator: DatabaseCreatorCoordinator)
}

class DatabaseCreatorCoordinator: NSObject {
    weak var delegate: DatabaseCreatorCoordinatorDelegate?
    
    private let navigationController: UINavigationController
    private weak var initialTopController: UIViewController?
    private let databaseCreatorVC: DatabaseCreatorVC
    
    init(navigationController: UINavigationController) {
        self.navigationController = navigationController
        self.initialTopController = navigationController.topViewController
        
        databaseCreatorVC = DatabaseCreatorVC.create()
        super.init()

        databaseCreatorVC.delegate = self
    }
    
    func start() {
        navigationController.pushViewController(databaseCreatorVC, animated: true)
    }
    

    private func createEmptyLocalFile(fileName: String) throws -> URL {
        let fileManager = FileManager()
        let docDir = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let tmpDir = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: docDir,
            create: true
        )
        let tmpFileURL = tmpDir
            .appendingPathComponent(fileName, isDirectory: false)
            .appendingPathExtension(FileType.DatabaseExtensions.kdbx)
        
        do {
            try? fileManager.removeItem(at: tmpFileURL)
            try Data().write(to: tmpFileURL, options: []) 
        } catch {
            Diag.error("Failed to create temporary file [message: \(error.localizedDescription)]")
            throw error
        }
        return tmpFileURL
    }
    
    
    private func instantiateDatabase(fileName: String) {
        let tmpFileURL: URL
        do {
            tmpFileURL = try createEmptyLocalFile(fileName: fileName)
        } catch {
            databaseCreatorVC.setError(message: error.localizedDescription, animated: true)
            return
        }
        
        DatabaseManager.shared.createDatabase(
            databaseURL: tmpFileURL,
            password: databaseCreatorVC.password,
            keyFile: databaseCreatorVC.keyFile,
            template: { [weak self] (rootGroup2) in
                rootGroup2.name = fileName // override default "/" with a meaningful name
                self?.addTemplateItems(to: rootGroup2)
            },
            success: { [weak self] in
                self?.startSavingDatabase()
            },
            error: { [weak self] (message) in
                self?.databaseCreatorVC.setError(message: message, animated: true)
            }
        )
    }
    
    private func addTemplateItems(to rootGroup: Group2) {
        let groupGeneral = rootGroup.createGroup()
        groupGeneral.iconID = .folder
        groupGeneral.name = "General".localized(comment: "Predefined group in a new database")
        
        let groupInternet = rootGroup.createGroup()
        groupInternet.iconID = .globe
        groupInternet.name = "Internet".localized(comment: "Predefined group in a new database")

        let groupEmail = rootGroup.createGroup()
        groupEmail.iconID = .envelopeOpen
        groupEmail.name = "Email".localized(comment: "Predefined group in a new database")

        let groupHomebanking = rootGroup.createGroup()
        groupHomebanking.iconID = .currency
        groupHomebanking.name = "Finance".localized(comment: "Predefined group in a new database")
        
        let groupNetwork = rootGroup.createGroup()
        groupNetwork.iconID = .server
        groupNetwork.name = "Network".localized(comment: "Predefined group in a new database")

        let groupLinux = rootGroup.createGroup()
        groupLinux.iconID = .apple
        groupLinux.name = "OS".localized(comment: "Predefined `Operating system` group in a new database")
        
        let sampleEntry = rootGroup.createEntry()
        sampleEntry.iconID = .key
        sampleEntry.title = "Sample Entry".localized(comment: "Title for a sample entry")
        sampleEntry.userName = "john.smith".localized(comment: "User name for a sample entry. Set to a typical person name for your language.")
        sampleEntry.password = "pa$$word".localized(comment: "Password for a sample entry. Translation is optional.")
        sampleEntry.url = "https://keepassium.com" 
        sampleEntry.notes = "You can also store some notes, if you like.".localized(comment: "Note for a sample entry")
    }
    
    private func startSavingDatabase() {
        DatabaseManager.shared.addObserver(self)
        DatabaseManager.shared.startSavingDatabase()
    }
    
    private func pickTargetLocation(for tmpDatabaseRef: URLReference) {
        do{
            let tmpUrl = try tmpDatabaseRef.resolve() 
            let picker = UIDocumentPickerViewController(url: tmpUrl, in: .exportToService)
            picker.modalPresentationStyle = navigationController.modalPresentationStyle
            picker.delegate = self
            databaseCreatorVC.present(picker, animated: true, completion: nil)
        } catch {
            Diag.error("Failed to resolve temporary DB reference [message: \(error.localizedDescription)]")
            databaseCreatorVC.setError(message: error.localizedDescription, animated: true)
        }
    }
    
    private func addCreatedDatabase(at finalURL: URL) {
        let fileKeeper = FileKeeper.shared
        fileKeeper.addFile(
            url: finalURL,
            mode: .openInPlace,
            success: { [weak self] (addedRef) in
                guard let _self = self else { return }
                if let initialTopController = _self.initialTopController {
                    _self.navigationController.popToViewController(initialTopController, animated: true)
                }
                _self.delegate?.didCreateDatabase(in: _self, database: addedRef)
            },
            error: { [weak self] (fileKeeperError) in
                Diag.error("Failed to add created file [mesasge: \(fileKeeperError.localizedDescription)]")
                self?.databaseCreatorVC.setError(
                    message: fileKeeperError.localizedDescription,
                    animated: true
                )
            }
        )
    }
}

extension DatabaseCreatorCoordinator: DatabaseCreatorDelegate {
    func didPressCancel(in databaseCreatorVC: DatabaseCreatorVC) {
        if let initialTopController = self.initialTopController {
            navigationController.popToViewController(initialTopController, animated: true)
        }
        delegate?.didPressCancel(in: self)
    }
    
    func didPressContinue(in databaseCreatorVC: DatabaseCreatorVC) {
        instantiateDatabase(fileName: databaseCreatorVC.databaseFileName)
    }
    
    func didPressPickKeyFile(in databaseCreatorVC: DatabaseCreatorVC, popoverSource: UIView) {
        let keyFileChooser = ChooseKeyFileVC.make(popoverSourceView: popoverSource, delegate: self)
        navigationController.present(keyFileChooser, animated: true, completion: nil)
    }
}

extension DatabaseCreatorCoordinator: KeyFileChooserDelegate {
    func onKeyFileSelected(urlRef: URLReference?) {
        databaseCreatorVC.keyFile = urlRef
        databaseCreatorVC.becomeFirstResponder()
    }
}

extension DatabaseCreatorCoordinator: DatabaseManagerObserver {
    func databaseManager(willSaveDatabase urlRef: URLReference) {
        databaseCreatorVC.showProgressView(
            title: LString.databaseStatusSaving,
            allowCancelling: true)
    }
    
    func databaseManager(progressDidChange progress: ProgressEx) {
        databaseCreatorVC.updateProgressView(with: progress)
    }
    
    func databaseManager(didSaveDatabase urlRef: URLReference) {
        DatabaseManager.shared.removeObserver(self)
        databaseCreatorVC.hideProgressView()
        DatabaseManager.shared.closeDatabase(
            completion: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.pickTargetLocation(for: urlRef)
                }
            },
            clearStoredKey: true
        )
    }
    
    func databaseManager(database urlRef: URLReference, isCancelled: Bool) {
        DatabaseManager.shared.removeObserver(self)
        DatabaseManager.shared.abortDatabaseCreation()
        self.databaseCreatorVC.hideProgressView()
    }
    
    func databaseManager(database urlRef: URLReference, savingError message: String, reason: String?) {
        DatabaseManager.shared.removeObserver(self)
        DatabaseManager.shared.abortDatabaseCreation()
        databaseCreatorVC.hideProgressView()
        if let reason = reason {
            databaseCreatorVC.setError(message: "\(message)\n\(reason)", animated: true)
        } else {
            databaseCreatorVC.setError(message: message, animated: true)
        }
    }
}

extension DatabaseCreatorCoordinator: UIDocumentPickerDelegate {
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let initialTopController = self.initialTopController {
            self.navigationController.popToViewController(initialTopController, animated: false)
        }
        self.delegate?.didPressCancel(in: self)
    }
    
    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL])
    {
        guard let url = urls.first else { return }
        addCreatedDatabase(at: url)
    }
}
