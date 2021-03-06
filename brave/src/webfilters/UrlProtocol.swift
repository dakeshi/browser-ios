/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import CoreData

var requestCount = 0
let markerRequestHandled = "request-already-handled"

class URLProtocol: NSURLProtocol {

    var connection: NSURLConnection?
    var disableJavascript = false
    static var testShieldState: BraveShieldState?

    override class func canInitWithRequest(request: NSURLRequest) -> Bool {
        //print("Request #\(requestCount++): URL = \(request.mainDocumentURL?.absoluteString)")
        if let scheme = request.URL?.scheme where !scheme.startsWith("http") {
            return false
        }

        if NSURLProtocol.propertyForKey(markerRequestHandled, inRequest: request) != nil {
            return false
        }

        guard let url = request.URL else { return false }

        let shieldState = testShieldState != nil ? testShieldState! : getShields(request)
        if shieldState.isAllOff() {
            return false
        }
        
        let useCustomUrlProtocol =
            shieldState.isOnScriptBlocking() ?? false ||
            (shieldState.isOnAdBlockAndTp() ?? false && TrackingProtection.singleton.shouldBlock(request)) ||
                (shieldState.isOnAdBlockAndTp() ?? false && AdBlocker.singleton.shouldBlock(request)) ||
                (shieldState.isOnSafeBrowsing() ?? false && SafeBrowsing.singleton.shouldBlock(request)) ||
                (shieldState.isOnHTTPSE() ?? false && HttpsEverywhere.singleton.tryRedirectingUrl(url) != nil)

        return useCustomUrlProtocol
    }

    // Tries to use the UA to match to requesting webview.
    // If it fails use current selected webview
    /*
     - request arrives in protocol
     - protocol maps request to brave web view
     - brave web view has shield state, grab that state, apply it to request
     */
    static func getShields(request: NSURLRequest) -> BraveShieldState {
        let ua = request.allHTTPHeaderFields?["User-Agent"]
        var webViewShield:BraveShieldState? = nil
        let shieldResult = BraveShieldState()

        if let webView = WebViewToUAMapper.userAgentToWebview(ua) {
            webViewShield = webView.braveShieldState
        } else {
            webViewShield = getApp().tabManager.selectedTab?.webView?.braveShieldState
        }

        if let webViewShield = webViewShield where webViewShield.isAllOff() {
            shieldResult.setState(BraveShieldState.kAllOff, on: true)
            return shieldResult
        }

        shieldResult.setStateFromPerPageShield(webViewShield)
        return shieldResult
    }

    override class func canonicalRequestForRequest(request: NSURLRequest) -> NSURLRequest {
        return request
    }

    private class func cloneRequest(request: NSURLRequest) -> NSMutableURLRequest {
        // Reportedly not safe to use built-in cloning methods: http://openradar.appspot.com/11596316
        let newRequest = NSMutableURLRequest(URL: request.URL!, cachePolicy: request.cachePolicy, timeoutInterval: request.timeoutInterval)
        newRequest.allHTTPHeaderFields = request.allHTTPHeaderFields
        if let m = request.HTTPMethod {
            newRequest.HTTPMethod = m
        }
        if let b = request.HTTPBodyStream {
            newRequest.HTTPBodyStream = b
        }
        if let b = request.HTTPBody {
            newRequest.HTTPBody = b
        }
        newRequest.HTTPShouldUsePipelining = request.HTTPShouldUsePipelining
        newRequest.mainDocumentURL = request.mainDocumentURL
        newRequest.networkServiceType = request.networkServiceType
        return newRequest
    }

    func returnEmptyResponse() {
        // To block the load nicely, return an empty result to the client.
        // Nice => UIWebView's isLoading property gets set to false
        // Not nice => isLoading stays true while page waits for blocked items that never arrive

        // IIRC expectedContentLength of 0 is buggy (can't find the reference now).
        guard let url = request.URL else { return }
        let response = NSURLResponse(URL: url, MIMEType: "text/html", expectedContentLength: 1, textEncodingName: "utf-8")
        client?.URLProtocol(self, didReceiveResponse: response, cacheStoragePolicy: .NotAllowed)
        client?.URLProtocol(self, didLoadData: NSData())
        client?.URLProtocolDidFinishLoading(self)
    }

    //a special artificial response that includes content that explains why the page was
    //blocked by phishing detection
    func returnBlockedPageResponse() {
        let path = NSBundle.mainBundle().pathForResource("SafeBrowsingError", ofType: "html")!
        let src = try! NSString(contentsOfFile: path, encoding: NSUTF8StringEncoding) as String
        guard let url = request.URL else { return }
        
        let blockedResponse = NSHTTPURLResponse(URL: url, statusCode: 200, HTTPVersion: "1.1", headerFields: nil)
        client?.URLProtocol(self, didReceiveResponse: blockedResponse!, cacheStoragePolicy: .NotAllowed)
        client?.URLProtocol(self, didLoadData: src.dataUsingEncoding(NSUTF8StringEncoding)!)
        client?.URLProtocolDidFinishLoading(self)
    }
    

    static var blankPixel: NSData? = {
        let rect = CGRectMake(0, 0, 1, 1)
        UIGraphicsBeginImageContext(rect.size)
        let c = UIGraphicsGetCurrentContext()
        CGContextSetFillColorWithColor(c, UIColor.clearColor().CGColor)
        CGContextFillRect(c, rect)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return UIImageJPEGRepresentation(image, 0.4)
    }()

    func returnBlankPixel() {
        guard let url = request.URL, pixel = URLProtocol.blankPixel else { return }
        let response = NSURLResponse(URL: url, MIMEType: "image/jpeg", expectedContentLength: pixel.length, textEncodingName: nil)
        client?.URLProtocol(self, didReceiveResponse: response, cacheStoragePolicy: .NotAllowed)
        client?.URLProtocol(self, didLoadData: pixel)
        client?.URLProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        let newRequest = URLProtocol.cloneRequest(request)
        NSURLProtocol.setProperty(true, forKey: markerRequestHandled, inRequest: newRequest)

        let shieldState = URLProtocol.getShields(request)
        let ua = request.allHTTPHeaderFields?["User-Agent"]

        // HttpsEverywhere re-checking is O(1) due to internal cache,
        if let url = request.URL, redirectedUrl = shieldState.isOnHTTPSE() ?? false ? HttpsEverywhere.singleton.tryRedirectingUrl(url) : nil {
            // TODO handle https redirect loop
            newRequest.URL = redirectedUrl
            #if DEBUG
                //print(url.absoluteString + " [HTTPE to] " + redirectedUrl.absoluteString)
            #endif

            if url == request.mainDocumentURL {
                returnEmptyResponse()
                postAsyncToMain(0) {
                    WebViewToUAMapper.userAgentToWebview(ua)?.loadRequest(newRequest)
                }
            } else {
                connection = NSURLConnection(request: newRequest, delegate: self)
                postAsyncToMain(0.1) {
                    WebViewToUAMapper.userAgentToWebview(ua)?.shieldStatUpdate(.httpseIncrement)
                }
            }
            return
        } else if shieldState.isOnSafeBrowsing() ?? false && SafeBrowsing.singleton.shouldBlock(request) {
            
            returnBlockedPageResponse()

            return
        } else if shieldState.isOnAdBlockAndTp() ?? false && (TrackingProtection.singleton.shouldBlock(request) || AdBlocker.singleton.shouldBlock(request)) {
            if request.URL?.host?.contains("pcworldcommunication.d2.sc.omtrdc.net") ?? false || request.URL?.host?.contains("b.scorecardresearch.com") ?? false {
                // sites such as macworld.com need this, or links are not clickable
                returnBlankPixel()
            } else {
                returnEmptyResponse()
            }
            postAsyncToMain(0.1) {
                WebViewToUAMapper.userAgentToWebview(ua)?.shieldStatUpdate(.abAndTpIncrement)
            }
            return
        }

        disableJavascript = shieldState.isOnScriptBlocking() ?? false

        if let url = request.URL?.absoluteString where disableJavascript && (url.contains(".js?") || url.contains(".js#") || url.endsWith(".js")) {
            returnEmptyResponse()
            return
        }

        self.connection = NSURLConnection(request: newRequest, delegate: self)
    }

    override func stopLoading() {
        connection?.cancel()
        self.connection = nil
    }

    // MARK: NSURLConnection
    func connection(connection: NSURLConnection!, didReceiveResponse response: NSURLResponse!) {
        var returnedResponse: NSURLResponse = response
        if let response = response as? NSHTTPURLResponse,
            url = response.URL
            where disableJavascript && !AboutUtils.isAboutURL(url)
        {
            var fields = response.allHeaderFields as? [String : String] ?? [String : String]()
            fields["X-WebKit-CSP"] = "script-src none"
            returnedResponse = NSHTTPURLResponse(URL: url, statusCode: response.statusCode, HTTPVersion: "HTTP/1.1" /*not used*/, headerFields: fields)!
        }
        self.client!.URLProtocol(self, didReceiveResponse: returnedResponse, cacheStoragePolicy: .Allowed)
    }

    func connection(connection: NSURLConnection, willSendRequest request: NSURLRequest, redirectResponse response: NSURLResponse?) -> NSURLRequest?
    {
        if let response = response {
            client?.URLProtocol(self, wasRedirectedToRequest: request, redirectResponse: response)
        }
        return request
    }

    func connection(connection: NSURLConnection!, didReceiveData data: NSData!) {
        self.client!.URLProtocol(self, didLoadData: data)
        //self.mutableData.appendData(data)
    }

    func connectionDidFinishLoading(connection: NSURLConnection!) {
        self.client!.URLProtocolDidFinishLoading(self)
    }

    func connection(connection: NSURLConnection!, didFailWithError error: NSError!) {
        self.client!.URLProtocol(self, didFailWithError: error)
        print("* Error url: \(self.request.URLString)\n* Details: \(error)")
    }
}
