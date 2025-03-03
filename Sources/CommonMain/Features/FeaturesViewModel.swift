import Foundation

/// Interface for Feature API Completion Events
protocol FeaturesFlowDelegate: AnyObject {
    func featuresFetchedSuccessfully(features: [String: Feature], isRemote: Bool)
    func featuresFetchFailed(error: SDKError, isRemote: Bool)
}

/// View Model for Features
class FeaturesViewModel {
    var delegate: FeaturesFlowDelegate?
    let dataSource: FeaturesDataSource
    var encryptionKey: String?
    var backgroundSync: Bool?
    
    /// Caching Manager
    let manager = CachingManager.shared

    init(delegate: FeaturesFlowDelegate, dataSource: FeaturesDataSource, backgroundSync: Bool?) {
        self.delegate = delegate
        self.dataSource = dataSource
        self.backgroundSync = backgroundSync
    }

    /// Fetch Features
    func fetchFeatures(apiUrl: String?, sseURL: String?) {
        // Check for cache data
        if let json = manager.getData(fileName: Constants.featureCache) {
            let decoder = JSONDecoder()
            if let features = try? decoder.decode(Features.self, from: json) {
                // Call Success Delegate with mention of data available but its not remote
                delegate?.featuresFetchedSuccessfully(features: features, isRemote: false)
            } else {
                delegate?.featuresFetchFailed(error: .failedParsedData, isRemote: false)
                logger.error("Failed parse local data")
            }
        } else {
            delegate?.featuresFetchFailed(error: .failedToLoadData, isRemote: false)
            logger.error("Failed load local data")
        }

        if let apiUrl = apiUrl {
            dataSource.fetchFeatures(apiUrl: apiUrl) { result in
                switch result {
                case .success(let data):
                    self.prepareFeaturesData(data: data)
                case .failure(let error):
                    self.delegate?.featuresFetchFailed(error: .failedToLoadData, isRemote: true)
                    logger.error("Failed get features: \(error.localizedDescription)")
                }
            }
        }
        
        if let urlString = sseURL, let url = URL(string: urlString) {
            if backgroundSync ?? false {
                let streamingUpdate = SSEHandler(url: url, headers: ["Authorization": "Bearer basic-auth-token"])
                streamingUpdate.addEventListener(event: "features") { [weak self] id, event, data in
                    guard let jsonData = data?.data(using: .utf8) else { return }
                    self?.prepareFeaturesData(data: jsonData)
                }
                streamingUpdate.connect()
            } else {
                SSEHandler(url: url).disconnect()
            }
        }
        
    }

    /// Cache API Response and push success event
    func prepareFeaturesData(data: Data) {
        // Call Success Delegate with mention of data available with remote
        let decoder = JSONDecoder()

        if let jsonPetitions = try? decoder.decode(FeaturesDataModel.self, from: data) {
            if let features = jsonPetitions.features, features != [:] {
                if let featureData = try? JSONEncoder().encode(features) {
                    manager.putData(fileName: Constants.featureCache, content: featureData)
                }
                delegate?.featuresFetchedSuccessfully(features: features, isRemote: true)
            } else {
                if let encryptedString = jsonPetitions.encryptedFeatures, !encryptedString.isEmpty  {
                    if let encryptionKey = encryptionKey, !encryptionKey.isEmpty {
                        let crypto: CryptoProtocol = Crypto()
                        guard let features = crypto.getFeaturesFromEncryptedFeatures(encryptedString: encryptedString, encryptionKey: encryptionKey) else { return }
                        if let featureData = try? JSONEncoder().encode(features) {
                            manager.putData(fileName: Constants.featureCache, content: featureData)
                        }
                        delegate?.featuresFetchedSuccessfully(features: features, isRemote: true)
                    } else {
                        delegate?.featuresFetchFailed(error: .failedMissingKey, isRemote: true)
                        return
                    }
                } else {
                    delegate?.featuresFetchFailed(error: .failedParsedData, isRemote: true)
                    return
                }
            }
        }
    }
}
