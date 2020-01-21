//
//  PiHoleDataStore.swift
//  Pi-Helper
//
//  Created by Billy Brawner on 10/19/19.
//  Copyright © 2019 William Brawner. All rights reserved.
//

import Foundation
import Combine
import UIKit

class PiHoleDataStore: ObservableObject {
    private let IP_MIN = 0
    private let IP_MAX = 255
    private var currentRequest: AnyCancellable? = nil
    private var oldPiHole: PiHole? = nil
    @Published var pihole: Result<PiHole, PiHoleError>
    @Published var apiKey: String? = nil {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: PiHoleDataStore.API_KEY)
            apiService.apiKey = apiKey
        }
    }
    @Published var baseUrl: String? = nil {
        didSet {
            let safeHost = prependScheme(baseUrl)
            UserDefaults.standard.set(safeHost, forKey: PiHoleDataStore.HOST_KEY)
            apiService.baseUrl = safeHost
        }
    }
    private var shouldMonitorStatus = false
    
    private func prependScheme(_ ipAddress: String?) -> String? {
        guard let host = ipAddress else {
            return nil
        }
        
        if host.isEmpty {
            return nil
        }
        
        if !host.starts(with: "http://") && !host.starts(with: "https://") {
            return "http://" + host
        }
        
        return host
    }
    
    func monitorStatus() {
        self.shouldMonitorStatus = true
        doMonitorStatus()
    }
    
    private func doMonitorStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: {
            if !self.shouldMonitorStatus {
                return
            }
            self.loadSummary {
                self.doMonitorStatus()
            }
        })
    }
    
    func stopMonitoring() {
        self.shouldMonitorStatus = false
    }
    
    func beginScanning(_ ipAddress: String) {
        var addressParts = ipAddress.split(separator: ".")
        var chunks = 1
        var ipAddresses = [String]()
        while chunks <= IP_MAX {
            let chunkSize = (IP_MAX - IP_MIN + 1) / chunks
            if chunkSize == 1 {
                return
            }
            for chunk in 0..<chunks {
                let chunkStart = IP_MIN + (chunk * chunkSize)
                let chunkEnd = IP_MIN + ((chunk + 1) * chunkSize)
                addressParts[3] = Substring(String(((chunkEnd - chunkStart) / 2) + chunkStart))
                ipAddresses.append(addressParts.joined(separator: "."))
            }
            chunks *= 2
        }
        scan(ipAddresses)
    }
    
    func connect(_ rawIpAddress: String) {
        guard let formattedIpAddress = prependScheme(rawIpAddress) else {
            self.pihole = .failure(.connectionFailed)
            return
        }
        
        self.apiService.baseUrl = formattedIpAddress
        currentRequest = self.apiService.getVersion()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { (completion) in
                switch completion {
                case .finished:
                    return
                case .failure(_):
                    self.pihole = .failure(.connectionFailed)
                }
            }, receiveValue: { version in
                self.baseUrl = formattedIpAddress
                self.pihole = .failure(.missingApiKey)
            })
    }
    
    private func scan(_ ipAddresses: [String]) {
        if ipAddresses.isEmpty {
            self.pihole = .failure(.scanFailed)
            return
        }
        
        guard let ipAddress = prependScheme(ipAddresses[0]) else {
            return
        }
        self.apiService.baseUrl = ipAddress
        self.pihole = .failure(.scanning(ipAddresses[0]))
        currentRequest = self.apiService.getVersion()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { (completion) in
                switch completion {
                case .finished:
                    return
                case .failure(let error):
                    // ignore if timeout, otherwise handle
                    print(error)
                    self.scan(Array(ipAddresses.dropFirst()))
                }
            }, receiveValue: { version in
                // Stop scans, load summary
                self.baseUrl = ipAddress
                self.pihole = .failure(.missingApiKey)
            })
    }
    
    func connectWithPassword(_ password: String) {
        var request = URLRequest(url: URL(string: "\(self.apiService.baseUrl!)/admin/index.php?login")!)
        request.httpMethod = "POST"
        request.httpBody = "pw=\(password)".data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        currentRequest = URLSession.shared.dataTaskPublisher(for: request)
            .sink(receiveCompletion: { (completion) in
                switch completion {
                case .finished:
                    break
                case .failure(let error):
                    print(error)
                }
            }) { (data, response) in
                self.getApiToken()
        }
    }
    
    func connectWithApiKey(_ apiToken: String) {
        self.apiKey = apiToken
    }
    
    private func getApiToken() {
        var request = URLRequest(url: URL(string: "\(self.apiService.baseUrl!)/admin/scripts/pi-hole/php/api_token.php")!)
        request.httpMethod = "GET"
        currentRequest = URLSession.shared.dataTaskPublisher(for: request)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { (completion) in
                    switch completion {
                    case .finished:
                        break
                    case .failure(let error):
                        print(error)
                    }
            },
                receiveValue: { (data, response) in
                    print(String(data: data, encoding: .utf8)!)
                    guard let regex = try? NSRegularExpression(pattern: ".*Raw API Token: ([a-zA-Z0-9]+).*", options: []) else {
                        print("Invalid regex")
                        return
                    }
                    let apiTokenHtml = String(data: data, encoding: .utf8)!
                    let matches = regex.matches(in: apiTokenHtml, options: [], range: NSMakeRange(0, apiTokenHtml.utf16.count))
                    if let match = matches.first {
                        let range = match.range(at:1)
                        if let apiTokenRange = Range(range, in: apiTokenHtml) {
                            let apiToken = apiTokenHtml[apiTokenRange]
                            self.apiKey = String(apiToken)
                        }
                    }
            }
        )
    }
    
    func cancelRequest() {
        self.currentRequest?.cancel()
        self.pihole = .failure(.networkError(self.oldPiHole, error: .cancelled))
    }
    
    func loadSummary(completionBlock: (() -> Void)? = nil) {
        self.oldPiHole = try? self.pihole.get()
        self.pihole = .failure(.networkError(oldPiHole, error: .loading))
        
        currentRequest = apiService.loadSummary()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { (completion) in
                switch completion {
                case .finished:
                    if let completionBlock = completionBlock {
                        completionBlock()
                    }
                    return
                case .failure(let error):
                    self.pihole = .failure(.networkError(self.oldPiHole, error: error))
                }
            }, receiveValue: { pihole in
                UIApplication.shared.shortcutItems = [
                    UIApplicationShortcutItem(
                        type: ShortcutAction.enable.rawValue,
                        localizedTitle: Bundle.main.localizedString(forKey: "enable", value: "Enable", table: nil),
                        localizedSubtitle: nil,
                        icon: UIApplicationShortcutIcon(type: .play),
                        userInfo: nil
                    ),
                    UIApplicationShortcutItem(
                        type: ShortcutAction.disable.rawValue,
                        localizedTitle: Bundle.main.localizedString(forKey: "disable_10_sec", value: "Disable 10 Secs", table: nil),
                        localizedSubtitle: nil,
                        icon: UIApplicationShortcutIcon(type: .pause),
                        userInfo: ["forSeconds": 10 as NSSecureCoding]
                    ),
                    UIApplicationShortcutItem(
                        type: ShortcutAction.disable.rawValue,
                        localizedTitle: Bundle.main.localizedString(forKey: "disable_30_sec", value: "Disable 30 Secs", table: nil),
                        localizedSubtitle: nil,
                        icon: UIApplicationShortcutIcon(type: .pause),
                        userInfo: ["forSeconds": 30 as NSSecureCoding]
                    ),
                    UIApplicationShortcutItem(
                        type: ShortcutAction.disable.rawValue,
                        localizedTitle: Bundle.main.localizedString(forKey: "disable_5_min", value: "Disable 5 Min", table: nil),
                        localizedSubtitle: nil,
                        icon: UIApplicationShortcutIcon(type: .pause),
                        userInfo: ["forSeconds": 300 as NSSecureCoding]
                    )
                ]
                self.pihole = .success(pihole)
            })
    }
    
    func enable() {
        self.oldPiHole = try! pihole.get()
        self.pihole = .failure(.networkError(self.oldPiHole, error: .loading))
        currentRequest = self.apiService.enable()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { (completion) in
                switch completion {
                case .finished:
                    // no-op
                    return
                case .failure(let error):
                    self.pihole = .failure(.networkError(self.oldPiHole, error: error))
                }
            }, receiveValue: { newStatus in
                self.pihole = .success(self.oldPiHole!.copy(status: newStatus.status))
            })
    }
    
    func disable(_ forSeconds: Int? = nil) {
        self.oldPiHole = try! pihole.get()
        self.pihole = .failure(.networkError(self.oldPiHole, error: .loading))
        currentRequest = self.apiService.disable(forSeconds)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { (completion) in
                switch completion {
                case .finished:
                    // no-op
                    return
                case .failure(let error):
                    self.pihole = .failure(.networkError(self.oldPiHole, error: error))
                }
            }, receiveValue: { newStatus in
                self.pihole = .success(self.oldPiHole!.copy(status: newStatus.status))
            })
    }
    
    let apiService = PiHoleApiService()
    static let HOST_KEY = "host"
    static let API_KEY = "apiKey"
    
    init(baseUrl: String? = nil, apiKey: String? = nil) {
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        if baseUrl == nil {
            self.pihole = .failure(.missingIpAddress)
        } else if apiKey == nil {
            self.pihole = .failure(.missingApiKey)
        } else {
            self.pihole = .failure(.networkError(nil, error: .loading))
            self.loadSummary()
        }
    }
}

enum ShortcutAction: String {
    case enable = "EnableAction"
    case disable = "DisableAction"
}

enum PiHoleError : Error, Equatable {
    case networkError(_ pihole: PiHole?, error: NetworkError)
    case scanning(_ ipAddress: String)
    case missingIpAddress
    case missingApiKey
    case scanFailed
    case connectionFailed
    
    static func == (lhs: PiHoleError, rhs: PiHoleError) -> Bool {
        switch (lhs, rhs) {
        case (.networkError(let pi1, let error1), .networkError(let pi2, let error2)):
            return pi1 == pi2 && error1 == error2
        case (.scanning(_), .scanning(_)):
            return true
        case (.missingIpAddress, .missingIpAddress):
            return true
        case (.missingApiKey, .missingApiKey):
            return true
        case (.scanFailed, .scanFailed):
            return true
        case (.connectionFailed, .connectionFailed):
            return true
        default:
            return false
        }
    }
}