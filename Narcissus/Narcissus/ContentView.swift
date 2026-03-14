//
//  ContentView.swift
//  Narcissus
//
//  Created by Jukka Erätuli on 17.2.2026.
//

import SwiftUI
import WebKit
import StoreKit

struct ContentView: View {
    var body: some View {
        WebView()
            .ignoresSafeArea()
    }
}

// MARK: - Device ID (persistent per install)
enum DeviceID {
    private static let key = "narcissus_device_id"
    static var value: String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}

// MARK: - SSE Stream Delegate
class StreamDelegate: NSObject, URLSessionDataDelegate {
    weak var webView: WKWebView?
    var callbackId: String = ""
    var buffer = Data()
    var httpStatusCode: Int = 0
    var errorData = Data()

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            httpStatusCode = http.statusCode
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if httpStatusCode != 200 {
            errorData.append(data)
            return
        }
        buffer.append(data)
        processBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !buffer.isEmpty {
            buffer.append("\n".data(using: .utf8)!)
            processBuffer()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let error = error {
                let e = error.localizedDescription.replacingOccurrences(of: "'", with: "\\'")
                self.webView?.evaluateJavaScript("window._apiStreamError('\(self.callbackId)','\(e)')")
            } else if self.httpStatusCode != 200 {
                var msg = "HTTP \(self.httpStatusCode)"
                if let errStr = String(data: self.errorData, encoding: .utf8) {
                    if let errData = errStr.data(using: .utf8),
                       let errJson = try? JSONSerialization.jsonObject(with: errData) as? [String: Any] {
                        if let errMsg = errJson["message"] as? String {
                            msg = errMsg
                        } else if let errObj = errJson["error"] as? [String: Any],
                                  let errMsg = errObj["message"] as? String {
                            msg = errMsg
                        } else if let errCode = errJson["error"] as? String {
                            msg = errCode
                        }
                    }
                }
                let escaped = msg.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: " ")
                self.webView?.evaluateJavaScript("window._apiStreamError('\(self.callbackId)','\(self.httpStatusCode) \(escaped)')")
            } else {
                self.webView?.evaluateJavaScript("window._apiStreamDone('\(self.callbackId)')")
            }
        }
    }

    private func processBuffer() {
        guard let text = String(data: buffer, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        if !text.hasSuffix("\n") {
            buffer = lines.last?.data(using: .utf8) ?? Data()
        } else {
            buffer = Data()
        }
        let completeLines = text.hasSuffix("\n") ? lines : Array(lines.dropLast())
        for line in completeLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("data: ") {
                let jsonStr = String(trimmed.dropFirst(6))
                if jsonStr == "[DONE]" { continue }
                if let jsonData = jsonStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let candidates = json["candidates"] as? [[String: Any]],
                   let contentObj = candidates.first?["content"] as? [String: Any],
                   let parts = contentObj["parts"] as? [[String: Any]] {
                    let visibleParts = parts.filter { ($0["thought"] as? Bool) != true }
                    guard let content = visibleParts.first?["text"] as? String, !content.isEmpty else { continue }
                    if let jsonData = try? JSONEncoder().encode(content),
                       let jsonStr = String(data: jsonData, encoding: .utf8) {
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self else { return }
                            self.webView?.evaluateJavaScript("window._apiStreamChunk('\(self.callbackId)',\(jsonStr))")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - API Stream Handler
class APIHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private static let apiKey = "AIzaSyB2lXHswz4dsk__uA7gOHIUxhInx0UiUHg"

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let urlStr = dict["url"] as? String,
              let headers = dict["headers"] as? [String: String],
              let body = dict["body"] as? String,
              let callbackId = dict["callbackId"] as? String else { return }

        // Inject API key into URL server-side
        var finalUrlStr = urlStr
        if var components = URLComponents(string: urlStr) {
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "key" }
            items.append(URLQueryItem(name: "key", value: APIHandler.apiKey))
            components.queryItems = items
            finalUrlStr = components.string ?? urlStr
        }
        guard let url = URL(string: finalUrlStr) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body.data(using: .utf8)

        let delegate = StreamDelegate()
        delegate.webView = webView
        delegate.callbackId = callbackId
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: request).resume()
    }
}

// MARK: - StoreKit Purchase Handler
class PurchaseHandler: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let action = dict["action"] as? String else { return }

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            switch action {
            case "subscribe":
                let productId = dict["productId"] as? String
                await self.handlePurchase(productId: productId)
            case "restore":
                await self.handleRestore()
            case "checkStatus":
                await self.syncTier()
            default:
                break
            }
        }
    }

    private func handlePurchase(productId: String?) async {
        let manager = SubscriptionManager.shared
        do {
            let success = try await manager.purchase(productId)
            if success {
                await syncTier()
                webView?.evaluateJavaScript("window._purchaseResult&&window._purchaseResult('success')", completionHandler: nil)
            } else {
                webView?.evaluateJavaScript("window._purchaseResult&&window._purchaseResult('cancelled')", completionHandler: nil)
            }
        } catch {
            let msg = error.localizedDescription
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: " ")
            webView?.evaluateJavaScript("window._purchaseResult&&window._purchaseResult('error','\(msg)')", completionHandler: nil)
        }
    }

    private func handleRestore() async {
        let manager = SubscriptionManager.shared
        await manager.restorePurchases()
        await syncTier()
        let isPremium = manager.isPremium
        webView?.evaluateJavaScript("window._restoreResult&&window._restoreResult(\(isPremium))", completionHandler: nil)
    }

    func syncTier() async {
        let manager = SubscriptionManager.shared
        await manager.checkEntitlements()
        let tier = manager.isPremium ? "premium" : "free"
        webView?.evaluateJavaScript("localStorage.setItem('ns_tier','\(tier)');window._tierUpdated&&window._tierUpdated('\(tier)')", completionHandler: nil)
    }
}

// MARK: - WebView
struct WebView: UIViewRepresentable {
    class Coordinator: NSObject, WKNavigationDelegate {
        let apiHandler = APIHandler()
        let purchaseHandler = PurchaseHandler()

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Sync subscription status after page loads
            Task { @MainActor [weak self] in
                await self?.purchaseHandler.syncTier()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.dataDetectorTypes = []

        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let coordinator = context.coordinator
        config.userContentController.add(coordinator.apiHandler, name: "apiProxy")
        config.userContentController.add(coordinator.purchaseHandler, name: "purchase")

        // Inject safe area + device ID at document load
        let safeTop: CGFloat = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first?.safeAreaInsets.top ?? 59
        let safeBottom: CGFloat = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first?.safeAreaInsets.bottom ?? 34

        let deviceId = DeviceID.value
        let injectScript = WKUserScript(
            source: """
            document.documentElement.style.setProperty('--st','\(safeTop)px');
            document.documentElement.style.setProperty('--sb','\(safeBottom)px');
            window._deviceId = '\(deviceId)';
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true)
        config.userContentController.addUserScript(injectScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        coordinator.apiHandler.webView = webView
        coordinator.purchaseHandler.webView = webView
        webView.navigationDelegate = coordinator
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.027, green: 0.043, blue: 0.078, alpha: 1.0)
        webView.scrollView.backgroundColor = UIColor(red: 0.027, green: 0.043, blue: 0.078, alpha: 1.0)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#Preview {
    ContentView()
}
