/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVWKInAppBrowser.h"

#if __has_include(<Cordova/CDVWebViewProcessPoolFactory.h>) // Cordova-iOS >=6
  #import <Cordova/CDVWebViewProcessPoolFactory.h>
#elif __has_include("CDVWKProcessPoolFactory.h") // Cordova-iOS <6 with WKWebView plugin
  #import "CDVWKProcessPoolFactory.h"
#endif

#import <Cordova/CDVPluginResult.h>

// Download support imports
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define    kInAppBrowserTargetSelf @"_self"
#define    kInAppBrowserTargetSystem @"_system"
#define    kInAppBrowserTargetBlank @"_blank"

#define    kInAppBrowserToolbarBarPositionBottom @"bottom"
#define    kInAppBrowserToolbarBarPositionTop @"top"

#define    IAB_BRIDGE_NAME @"cordova_iab"

#define    TOOLBAR_HEIGHT 44.0
#define    LOCATIONBAR_HEIGHT 0.0
#define    FOOTER_HEIGHT ((TOOLBAR_HEIGHT) + (LOCATIONBAR_HEIGHT))

// Hooks URL.createObjectURL so that the real Blob object (e.g. a client-generated
// jsPDF/File Saver blob) can be recovered later when the WebView is asked to navigate
// to the resulting blob: URL - mirrors InAppBrowserDownloads.java's getBlobHookJavaScript()
// on Android, which is why this JS is identical in shape to that one.
#define    JOGET_BLOB_HOOK_JS @"(function() {" \
    "  if (window.__jogetBlobHookInstalled) { return; }" \
    "  window.__jogetBlobHookInstalled = true;" \
    "  window.__jogetBlobStore = window.__jogetBlobStore || {};" \
    "  window.__jogetBlobFilenames = window.__jogetBlobFilenames || {};" \
    "  var originalCreateObjectURL = URL.createObjectURL;" \
    "  URL.createObjectURL = function(blob) {" \
    "    var id = 'blob_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9);" \
    "    window.__jogetBlobStore[id] = blob;" \
    "    var originalUrl = originalCreateObjectURL(blob);" \
    "    window.__jogetBlobStore[originalUrl] = id;" \
    "    return originalUrl;" \
    "  };" \
    "  function jogetRecordAnchorDownload(el) {" \
    "    if (el && el.tagName === 'A' && el.download && el.href && el.href.indexOf('blob:') === 0) {" \
    "      window.__jogetBlobFilenames[el.href] = el.download;" \
    "    }" \
    "  }" \
    "  document.addEventListener('click', function(e) {" \
    "    var el = e.target;" \
    "    while (el && el.tagName !== 'A') { el = el.parentElement; }" \
    "    jogetRecordAnchorDownload(el);" \
    "  }, true);" \
    "  if (window.HTMLAnchorElement) {" \
    "    var originalAnchorClick = HTMLAnchorElement.prototype.click;" \
    "    HTMLAnchorElement.prototype.click = function() {" \
    "      jogetRecordAnchorDownload(this);" \
    "      return originalAnchorClick.apply(this, arguments);" \
    "    };" \
    "    var originalAnchorDispatchEvent = HTMLAnchorElement.prototype.dispatchEvent;" \
    "    HTMLAnchorElement.prototype.dispatchEvent = function(evt) {" \
    "      if (evt && evt.type === 'click') { jogetRecordAnchorDownload(this); }" \
    "      return originalAnchorDispatchEvent.apply(this, arguments);" \
    "    };" \
    "  }" \
    "})();"

#pragma mark CDVWKInAppBrowser

@interface CDVWKInAppBrowser () {
    NSInteger _previousStatusBarStyle;
}
@end

@implementation CDVWKInAppBrowser

static CDVWKInAppBrowser* instance = nil;

+ (id) getInstance{
    return instance;
}

- (void)pluginInitialize
{
    instance = self;
    _previousStatusBarStyle = -1;
    _callbackIdPattern = nil;
    _beforeload = @"";
    _waitForBeforeload = NO;
}

- (void)onReset
{
    [self close:nil];
}

- (void)close:(CDVInvokedUrlCommand*)command
{
    if (self.inAppBrowserViewController == nil) {
        NSLog(@"IAB.close() called but it was already closed.");
        return;
    }
    
    // Things are cleaned up in browserExit.
    [self.inAppBrowserViewController close];
}

- (BOOL) isSystemUrl:(NSURL*)url
{
    if ([[url host] isEqualToString:@"itunes.apple.com"]) {
        return YES;
    }
    
    return NO;
}

- (void)open:(CDVInvokedUrlCommand*)command
{
    CDVPluginResult* pluginResult;
    
    NSString* url = [command argumentAtIndex:0];
    NSString* target = [command argumentAtIndex:1 withDefault:kInAppBrowserTargetSelf];
    NSString* options = [command argumentAtIndex:2 withDefault:@"" andClass:[NSString class]];
    
    self.callbackId = command.callbackId;
    
    if (url != nil) {
        NSURL* baseUrl = [self.webViewEngine URL];
        NSURL* absoluteUrl = [[NSURL URLWithString:url relativeToURL:baseUrl] absoluteURL];
        
        if ([self isSystemUrl:absoluteUrl]) {
            target = kInAppBrowserTargetSystem;
        }
        
        if ([target isEqualToString:kInAppBrowserTargetSelf]) {
            [self openInCordovaWebView:absoluteUrl withOptions:options];
        } else if ([target isEqualToString:kInAppBrowserTargetSystem]) {
            [self openInSystem:absoluteUrl];
        } else { // _blank or anything else
            [self openInInAppBrowser:absoluteUrl withOptions:options];
        }
        
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"incorrect number of arguments"];
    }
    
    [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)openInInAppBrowser:(NSURL*)url withOptions:(NSString*)options
{
    CDVInAppBrowserOptions* browserOptions = [CDVInAppBrowserOptions parseOptions:options];
    
    WKWebsiteDataStore* dataStore = [WKWebsiteDataStore defaultDataStore];
    if (browserOptions.cleardata) {
        
        NSDate* dateFrom = [NSDate dateWithTimeIntervalSince1970:0];
        [dataStore removeDataOfTypes:[WKWebsiteDataStore allWebsiteDataTypes] modifiedSince:dateFrom completionHandler:^{
            NSLog(@"Removed all WKWebView data");
            self.inAppBrowserViewController.webView.configuration.processPool = [[WKProcessPool alloc] init]; // create new process pool to flush all data
        }];
    }
    
    if (browserOptions.clearcache) {
        bool isAtLeastiOS11 = false;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
        if (@available(iOS 11.0, *)) {
            isAtLeastiOS11 = true;
        }
#endif
            
        if(isAtLeastiOS11){
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
            // Deletes all cookies
            WKHTTPCookieStore* cookieStore = dataStore.httpCookieStore;
            [cookieStore getAllCookies:^(NSArray* cookies) {
                NSHTTPCookie* cookie;
                for(cookie in cookies){
                    [cookieStore deleteCookie:cookie completionHandler:nil];
                }
            }];
#endif
        }else{
            // https://stackoverflow.com/a/31803708/777265
            // Only deletes domain cookies (not session cookies)
            [dataStore fetchDataRecordsOfTypes:[WKWebsiteDataStore allWebsiteDataTypes]
             completionHandler:^(NSArray<WKWebsiteDataRecord *> * __nonnull records) {
                 for (WKWebsiteDataRecord *record  in records){
                     NSSet<NSString*>* dataTypes = record.dataTypes;
                     if([dataTypes containsObject:WKWebsiteDataTypeCookies]){
                         [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:record.dataTypes
                               forDataRecords:@[record]
                               completionHandler:^{}];
                     }
                 }
             }];
        }
    }
    
    if (browserOptions.clearsessioncache) {
        bool isAtLeastiOS11 = false;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
        if (@available(iOS 11.0, *)) {
            isAtLeastiOS11 = true;
        }
#endif
        if (isAtLeastiOS11) {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
            // Deletes session cookies
            WKHTTPCookieStore* cookieStore = dataStore.httpCookieStore;
            [cookieStore getAllCookies:^(NSArray* cookies) {
                NSHTTPCookie* cookie;
                for(cookie in cookies){
                    if(cookie.sessionOnly){
                        [cookieStore deleteCookie:cookie completionHandler:nil];
                    }
                }
            }];
#endif
        }else{
            NSLog(@"clearsessioncache not available below iOS 11.0");
        }
    }

    if (self.inAppBrowserViewController == nil) {
        self.inAppBrowserViewController = [[CDVWKInAppBrowserViewController alloc] initWithBrowserOptions: browserOptions andSettings:self.commandDelegate.settings];
        self.inAppBrowserViewController.navigationDelegate = self;
        
        if ([self.viewController conformsToProtocol:@protocol(CDVScreenOrientationDelegate)]) {
            self.inAppBrowserViewController.orientationDelegate = (UIViewController <CDVScreenOrientationDelegate>*)self.viewController;
        }
    }
    
    [self.inAppBrowserViewController showLocationBar:browserOptions.location];
    [self.inAppBrowserViewController showToolBar:browserOptions.toolbar :browserOptions.toolbarposition];
    if (browserOptions.closebuttoncaption != nil || browserOptions.closebuttoncolor != nil) {
        int closeButtonIndex = browserOptions.lefttoright ? (browserOptions.hidenavigationbuttons ? 1 : 4) : 0;
        [self.inAppBrowserViewController setCloseButtonTitle:browserOptions.closebuttoncaption :browserOptions.closebuttoncolor :closeButtonIndex];
    }
    // Set Presentation Style
    UIModalPresentationStyle presentationStyle = UIModalPresentationFullScreen; // default
    if (browserOptions.presentationstyle != nil) {
        if ([[browserOptions.presentationstyle lowercaseString] isEqualToString:@"pagesheet"]) {
            presentationStyle = UIModalPresentationPageSheet;
        } else if ([[browserOptions.presentationstyle lowercaseString] isEqualToString:@"formsheet"]) {
            presentationStyle = UIModalPresentationFormSheet;
        }
    }
    self.inAppBrowserViewController.modalPresentationStyle = presentationStyle;
    
    // Set Transition Style
    UIModalTransitionStyle transitionStyle = UIModalTransitionStyleCoverVertical; // default
    if (browserOptions.transitionstyle != nil) {
        if ([[browserOptions.transitionstyle lowercaseString] isEqualToString:@"fliphorizontal"]) {
            transitionStyle = UIModalTransitionStyleFlipHorizontal;
        } else if ([[browserOptions.transitionstyle lowercaseString] isEqualToString:@"crossdissolve"]) {
            transitionStyle = UIModalTransitionStyleCrossDissolve;
        }
    }
    self.inAppBrowserViewController.modalTransitionStyle = transitionStyle;
    
    //prevent webView from bouncing
    if (browserOptions.disallowoverscroll) {
        if ([self.inAppBrowserViewController.webView respondsToSelector:@selector(scrollView)]) {
            ((UIScrollView*)[self.inAppBrowserViewController.webView scrollView]).bounces = NO;
        } else {
            for (id subview in self.inAppBrowserViewController.webView.subviews) {
                if ([[subview class] isSubclassOfClass:[UIScrollView class]]) {
                    ((UIScrollView*)subview).bounces = NO;
                }
            }
        }
    }
    
    // use of beforeload event
    if([browserOptions.beforeload isKindOfClass:[NSString class]]){
        _beforeload = browserOptions.beforeload;
    }else{
        _beforeload = @"yes";
    }
    _waitForBeforeload = ![_beforeload isEqualToString:@""];
    
    [self.inAppBrowserViewController navigateTo:url];
    if (!browserOptions.hidden) {
        [self show:nil withNoAnimate:browserOptions.hidden];
    }
}

- (void)show:(CDVInvokedUrlCommand*)command{
    [self show:command withNoAnimate:NO];
}

- (void)show:(CDVInvokedUrlCommand*)command withNoAnimate:(BOOL)noAnimate
{
    BOOL initHidden = NO;
    if(command == nil && noAnimate == YES){
        initHidden = YES;
    }
    
    if (self.inAppBrowserViewController == nil) {
        NSLog(@"Tried to show IAB after it was closed.");
        return;
    }
    if (_previousStatusBarStyle != -1) {
        NSLog(@"Tried to show IAB while already shown");
        return;
    }
    
    if(!initHidden){
        _previousStatusBarStyle = [UIApplication sharedApplication].statusBarStyle;
    }
    
    __block CDVInAppBrowserNavigationController* nav = [[CDVInAppBrowserNavigationController alloc]
                                                        initWithRootViewController:self.inAppBrowserViewController];
    nav.orientationDelegate = self.inAppBrowserViewController;
    nav.navigationBarHidden = YES;
    nav.modalPresentationStyle = self.inAppBrowserViewController.modalPresentationStyle;
    nav.presentationController.delegate = self.inAppBrowserViewController;
    
    __weak CDVWKInAppBrowser* weakSelf = self;
    
    // Run later to avoid the "took a long time" log message.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf.inAppBrowserViewController != nil) {
            float osVersion = [[[UIDevice currentDevice] systemVersion] floatValue];
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf->tmpWindow) {
                CGRect frame = [[UIScreen mainScreen] bounds];
                if(initHidden && osVersion < 11){
                   frame.origin.x = -10000;
                }
                strongSelf->tmpWindow = [[UIWindow alloc] initWithFrame:frame];
            }
            UIViewController *tmpController = [[UIViewController alloc] init];
            [strongSelf->tmpWindow setRootViewController:tmpController];
            [strongSelf->tmpWindow setWindowLevel:UIWindowLevelNormal];

            if(!initHidden || osVersion < 11){
                [self->tmpWindow makeKeyAndVisible];
            }
            [tmpController presentViewController:nav animated:!noAnimate completion:nil];
        }
    });
}

- (void)hide:(CDVInvokedUrlCommand*)command
{
    // Set tmpWindow to hidden to make main webview responsive to touch again
    // https://stackoverflow.com/questions/4544489/how-to-remove-a-uiwindow
    self->tmpWindow.hidden = YES;
    self->tmpWindow = nil;

    if (self.inAppBrowserViewController == nil) {
        NSLog(@"Tried to hide IAB after it was closed.");
        return;
        
        
    }
    if (_previousStatusBarStyle == -1) {
        NSLog(@"Tried to hide IAB while already hidden");
        return;
    }
    
    _previousStatusBarStyle = [UIApplication sharedApplication].statusBarStyle;
    
    // Run later to avoid the "took a long time" log message.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.inAppBrowserViewController != nil) {
            _previousStatusBarStyle = -1;
            [self.inAppBrowserViewController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

- (void)openInCordovaWebView:(NSURL*)url withOptions:(NSString*)options
{
    NSURLRequest* request = [NSURLRequest requestWithURL:url];
    // the webview engine itself will filter for this according to <allow-navigation> policy
    // in config.xml for cordova-ios-4.0
    [self.webViewEngine loadRequest:request];
}

- (void)openInSystem:(NSURL*)url
{
    if ([[UIApplication sharedApplication] openURL:url] == NO) {
        [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPluginHandleOpenURLNotification object:url]];
        [[UIApplication sharedApplication] openURL:url];
    }
}

- (void)loadAfterBeforeload:(CDVInvokedUrlCommand*)command
{
    NSString* urlStr = [command argumentAtIndex:0];

    if ([_beforeload isEqualToString:@""]) {
        NSLog(@"unexpected loadAfterBeforeload called without feature beforeload=get|post");
    }
    if (self.inAppBrowserViewController == nil) {
        NSLog(@"Tried to invoke loadAfterBeforeload on IAB after it was closed.");
        return;
    }
    if (urlStr == nil) {
        NSLog(@"loadAfterBeforeload called with nil argument, ignoring.");
        return;
    }

    NSURL* url = [NSURL URLWithString:urlStr];
    //_beforeload = @"";
    _waitForBeforeload = NO;
    [self.inAppBrowserViewController navigateTo:url];
}

// This is a helper method for the inject{Script|Style}{Code|File} API calls, which
// provides a consistent method for injecting JavaScript code into the document.
//
// If a wrapper string is supplied, then the source string will be JSON-encoded (adding
// quotes) and wrapped using string formatting. (The wrapper string should have a single
// '%@' marker).
//
// If no wrapper is supplied, then the source string is executed directly.

- (void)injectDeferredObject:(NSString*)source withWrapper:(NSString*)jsWrapper
{
    // Ensure a message handler bridge is created to communicate with the CDVWKInAppBrowserViewController
    [self evaluateJavaScript: [NSString stringWithFormat:@"(function(w){if(!w._cdvMessageHandler) {w._cdvMessageHandler = function(id,d){w.webkit.messageHandlers.%@.postMessage({d:d, id:id});}}})(window)", IAB_BRIDGE_NAME]];
    
    if (jsWrapper != nil) {
        NSData* jsonData = [NSJSONSerialization dataWithJSONObject:@[source] options:0 error:nil];
        NSString* sourceArrayString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        if (sourceArrayString) {
            NSString* sourceString = [sourceArrayString substringWithRange:NSMakeRange(1, [sourceArrayString length] - 2)];
            NSString* jsToInject = [NSString stringWithFormat:jsWrapper, sourceString];
            [self evaluateJavaScript:jsToInject];
        }
    } else {
        [self evaluateJavaScript:source];
    }
}


//Synchronus helper for javascript evaluation
- (void)evaluateJavaScript:(NSString *)script {
    __block NSString* _script = script;
    [self.inAppBrowserViewController.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (error == nil) {
            if (result != nil) {
                NSLog(@"%@", result);
            }
        } else {
            NSLog(@"evaluateJavaScript error : %@ : %@", error.localizedDescription, _script);
        }
    }];
}

- (void)injectScriptCode:(CDVInvokedUrlCommand*)command
{
    NSString* jsWrapper = nil;
    
    if ((command.callbackId != nil) && ![command.callbackId isEqualToString:@"INVALID"]) {
        jsWrapper = [NSString stringWithFormat:@"_cdvMessageHandler('%@',JSON.stringify([eval(%%@)]));", command.callbackId];
    }
    [self injectDeferredObject:[command argumentAtIndex:0] withWrapper:jsWrapper];
}

- (void)injectScriptFile:(CDVInvokedUrlCommand*)command
{
    NSString* jsWrapper;
    
    if ((command.callbackId != nil) && ![command.callbackId isEqualToString:@"INVALID"]) {
        jsWrapper = [NSString stringWithFormat:@"(function(d) { var c = d.createElement('script'); c.src = %%@; c.onload = function() { _cdvMessageHandler('%@'); }; d.body.appendChild(c); })(document)", command.callbackId];
    } else {
        jsWrapper = @"(function(d) { var c = d.createElement('script'); c.src = %@; d.body.appendChild(c); })(document)";
    }
    [self injectDeferredObject:[command argumentAtIndex:0] withWrapper:jsWrapper];
}

- (void)injectStyleCode:(CDVInvokedUrlCommand*)command
{
    NSString* jsWrapper;
    
    if ((command.callbackId != nil) && ![command.callbackId isEqualToString:@"INVALID"]) {
        jsWrapper = [NSString stringWithFormat:@"(function(d) { var c = d.createElement('style'); c.innerHTML = %%@; c.onload = function() { _cdvMessageHandler('%@'); }; d.body.appendChild(c); })(document)", command.callbackId];
    } else {
        jsWrapper = @"(function(d) { var c = d.createElement('style'); c.innerHTML = %@; d.body.appendChild(c); })(document)";
    }
    [self injectDeferredObject:[command argumentAtIndex:0] withWrapper:jsWrapper];
}

- (void)injectStyleFile:(CDVInvokedUrlCommand*)command
{
    NSString* jsWrapper;
    
    if ((command.callbackId != nil) && ![command.callbackId isEqualToString:@"INVALID"]) {
        jsWrapper = [NSString stringWithFormat:@"(function(d) { var c = d.createElement('link'); c.rel='stylesheet'; c.type='text/css'; c.href = %%@; c.onload = function() { _cdvMessageHandler('%@'); }; d.body.appendChild(c); })(document)", command.callbackId];
    } else {
        jsWrapper = @"(function(d) { var c = d.createElement('link'); c.rel='stylesheet', c.type='text/css'; c.href = %@; d.body.appendChild(c); })(document)";
    }
    [self injectDeferredObject:[command argumentAtIndex:0] withWrapper:jsWrapper];
}

- (BOOL)isValidCallbackId:(NSString *)callbackId
{
    NSError *err = nil;
    // Initialize on first use
    if (self.callbackIdPattern == nil) {
        self.callbackIdPattern = [NSRegularExpression regularExpressionWithPattern:@"^InAppBrowser[0-9]{1,10}$" options:0 error:&err];
        if (err != nil) {
            // Couldn't initialize Regex; No is safer than Yes.
            return NO;
        }
    }
    if ([self.callbackIdPattern firstMatchInString:callbackId options:0 range:NSMakeRange(0, [callbackId length])]) {
        return YES;
    }
    return NO;
}

/**
 * The message handler bridge provided for the InAppBrowser is capable of executing any oustanding callback belonging
 * to the InAppBrowser plugin. Care has been taken that other callbacks cannot be triggered, and that no
 * other code execution is possible.
 */
- (void)webView:(WKWebView *)theWebView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    
    NSURL* url = navigationAction.request.URL;
    NSURL* mainDocumentURL = navigationAction.request.mainDocumentURL;
    BOOL isTopLevelNavigation = [url isEqual:mainDocumentURL];
    BOOL shouldStart = YES;
    BOOL useBeforeLoad = NO;
    NSString* httpMethod = navigationAction.request.HTTPMethod;
    NSString* errorMessage = nil;
    
    if([_beforeload isEqualToString:@"post"]){
        //TODO handle POST requests by preserving POST data then remove this condition
        errorMessage = @"beforeload doesn't yet support POST requests";
    }
    else if(isTopLevelNavigation && (
           [_beforeload isEqualToString:@"yes"]
       || ([_beforeload isEqualToString:@"get"] && [httpMethod isEqualToString:@"GET"])
    // TODO comment in when POST requests are handled
    // || ([_beforeload isEqualToString:@"post"] && [httpMethod isEqualToString:@"POST"])
    )){
        useBeforeLoad = YES;
    }

    // When beforeload, on first URL change, initiate JS callback. Only after the beforeload event, continue.
    if (_waitForBeforeload && useBeforeLoad) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                      messageAsDictionary:@{@"type":@"beforeload", @"url":[url absoluteString]}];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
        
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    
    if(errorMessage != nil){
        NSLog(errorMessage);
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                      messageAsDictionary:@{@"type":@"loaderror", @"url":[url absoluteString], @"code": @"-1", @"message": errorMessage}];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    }
    
    //if is an app store link, let the system handle it, otherwise it fails to load it
    if ([[ url scheme] isEqualToString:@"itms-appss"] || [[ url scheme] isEqualToString:@"itms-apps"]) {
        [theWebView stopLoading];
        [self openInSystem:url];
        shouldStart = NO;
    }
    else if ((self.callbackId != nil) && isTopLevelNavigation) {
        // Send a loadstart event for each top-level navigation (includes redirects).
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                      messageAsDictionary:@{@"type":@"loadstart", @"url":[url absoluteString]}];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
        
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    }

    if (useBeforeLoad) {
        _waitForBeforeload = YES;
    }
    
    if(shouldStart){
        // Fix GH-417 & GH-424: Handle non-default target attribute
        // Based on https://stackoverflow.com/a/25713070/777265
        if (!navigationAction.targetFrame){
            [theWebView loadRequest:navigationAction.request];
            decisionHandler(WKNavigationActionPolicyCancel);
        }else{
            decisionHandler(WKNavigationActionPolicyAllow);
        }
    }else{
        decisionHandler(WKNavigationActionPolicyCancel);
    }
}

#pragma mark WKScriptMessageHandler delegate
- (void)userContentController:(nonnull WKUserContentController *)userContentController didReceiveScriptMessage:(nonnull WKScriptMessage *)message {
    
    CDVPluginResult* pluginResult = nil;
    
    if([message.body isKindOfClass:[NSDictionary class]]){
        NSDictionary* messageContent = (NSDictionary*) message.body;
        NSString* scriptCallbackId = messageContent[@"id"];
        
        if([messageContent objectForKey:@"d"]){
            NSString* scriptResult = messageContent[@"d"];
            NSError* __autoreleasing error = nil;
            NSData* decodedResult = [NSJSONSerialization JSONObjectWithData:[scriptResult dataUsingEncoding:NSUTF8StringEncoding] options:kNilOptions error:&error];
            if ((error == nil) && [decodedResult isKindOfClass:[NSArray class]]) {
                pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:(NSArray*)decodedResult];
            } else {
                pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_JSON_EXCEPTION];
            }
        } else {
            pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:@[]];
        }
        [self.commandDelegate sendPluginResult:pluginResult callbackId:scriptCallbackId];
    }else if(self.callbackId != nil){
        // Send a message event
        NSString* messageContent = (NSString*) message.body;
        NSError* __autoreleasing error = nil;
        NSData* decodedResult = [NSJSONSerialization JSONObjectWithData:[messageContent dataUsingEncoding:NSUTF8StringEncoding] options:kNilOptions error:&error];
        if (error == nil) {
            NSMutableDictionary* dResult = [NSMutableDictionary new];
            [dResult setValue:@"message" forKey:@"type"];
            [dResult setObject:decodedResult forKey:@"data"];
            CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:dResult];
            [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
            [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
        }
    }
}

- (void)didStartProvisionalNavigation:(WKWebView*)theWebView
{
    NSLog(@"didStartProvisionalNavigation");
//    self.inAppBrowserViewController.currentURL = theWebView.URL;
}

- (void)didFinishNavigation:(WKWebView*)theWebView
{
    if (self.callbackId != nil) {
        NSString* url = [theWebView.URL absoluteString];
        if(url == nil){
            if(self.inAppBrowserViewController.currentURL != nil){
                url = [self.inAppBrowserViewController.currentURL absoluteString];
            }else{
                url = @"";
            }
        }
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                      messageAsDictionary:@{@"type":@"loadstop", @"url":url}];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
        
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    }
}

- (void)webView:(WKWebView*)theWebView didFailNavigation:(NSError*)error
{
    if (self.callbackId != nil) {
        NSString* url = [theWebView.URL absoluteString];
        if(url == nil){
            if(self.inAppBrowserViewController.currentURL != nil){
                url = [self.inAppBrowserViewController.currentURL absoluteString];
            }else{
                url = @"";
            }
        }
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                      messageAsDictionary:@{@"type":@"loaderror", @"url":url, @"code": [NSNumber numberWithInteger:error.code], @"message": error.localizedDescription}];
        [pluginResult setKeepCallback:[NSNumber numberWithBool:YES]];
        
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    }
}

- (void)browserExit
{
    if (self.callbackId != nil) {
        CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                                      messageAsDictionary:@{@"type":@"exit"}];
        [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
        self.callbackId = nil;
    }
    
    [self.inAppBrowserViewController.configuration.userContentController removeScriptMessageHandlerForName:IAB_BRIDGE_NAME];
    self.inAppBrowserViewController.configuration = nil;
    
    [self.inAppBrowserViewController.webView stopLoading];
    [self.inAppBrowserViewController.webView removeFromSuperview];
    [self.inAppBrowserViewController.webView setUIDelegate:nil];
    [self.inAppBrowserViewController.webView setNavigationDelegate:nil];
    self.inAppBrowserViewController.webView = nil;
    
    // Set navigationDelegate to nil to ensure no callbacks are received from it.
    self.inAppBrowserViewController.navigationDelegate = nil;
    self.inAppBrowserViewController = nil;

    // Set tmpWindow to hidden to make main webview responsive to touch again
    // Based on https://stackoverflow.com/questions/4544489/how-to-remove-a-uiwindow
    self->tmpWindow.hidden = YES;
    self->tmpWindow = nil;

    if (IsAtLeastiOSVersion(@"7.0")) {
        if (_previousStatusBarStyle != -1) {
            [[UIApplication sharedApplication] setStatusBarStyle:_previousStatusBarStyle];
            
        }
    }
    
    _previousStatusBarStyle = -1; // this value was reset before reapplying it. caused statusbar to stay black on ios7
}

@end //CDVWKInAppBrowser

#pragma mark CDVWKInAppBrowserViewController

@implementation CDVWKInAppBrowserViewController

@synthesize currentURL;

CGFloat lastReducedStatusBarHeight = 0.0;
BOOL isExiting = FALSE;

- (id)initWithBrowserOptions: (CDVInAppBrowserOptions*) browserOptions andSettings:(NSDictionary *)settings
{
    self = [super init];
    if (self != nil) {
        _browserOptions = browserOptions;
        _settings = settings;
        self.webViewUIDelegate = [[CDVWKInAppBrowserUIDelegate alloc] initWithTitle:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"]];
        [self.webViewUIDelegate setViewController:self];
        
        [self createViews];
    }
    
    return self;
}

-(void)dealloc {
    [self.downloadSession invalidateAndCancel];
    //NSLog(@"dealloc");
}

- (void)createViews
{
    // We create the views in code for primarily for ease of upgrades and not requiring an external .xib to be included
    
    CGRect webViewBounds = self.view.bounds;
    BOOL toolbarIsAtBottom = ![_browserOptions.toolbarposition isEqualToString:kInAppBrowserToolbarBarPositionTop];
    webViewBounds.size.height -= _browserOptions.location ? FOOTER_HEIGHT : TOOLBAR_HEIGHT;
    WKUserContentController* userContentController = [[WKUserContentController alloc] init];
    
    WKWebViewConfiguration* configuration = [[WKWebViewConfiguration alloc] init];
    
    NSString *userAgent = configuration.applicationNameForUserAgent;
    if (
        [self settingForKey:@"OverrideUserAgent"] == nil &&
        [self settingForKey:@"AppendUserAgent"] != nil
        ) {
        userAgent = [NSString stringWithFormat:@"%@ %@", userAgent, [self settingForKey:@"AppendUserAgent"]];
    }
    configuration.applicationNameForUserAgent = userAgent;
    configuration.userContentController = userContentController;
#if __has_include(<Cordova/CDVWebViewProcessPoolFactory.h>)
    configuration.processPool = [[CDVWebViewProcessPoolFactory sharedFactory] sharedProcessPool];
#elif __has_include("CDVWKProcessPoolFactory.h")
    configuration.processPool = [[CDVWKProcessPoolFactory sharedFactory] sharedProcessPool];
#endif
    [configuration.userContentController addScriptMessageHandler:self name:IAB_BRIDGE_NAME];

    // Install the blob-capture hook before any page script runs, so that a client-generated
    // download (e.g. jsPDF's pdf.save()) can be recovered and saved natively instead of
    // being shown as an inline preview (iOS WKWebView does not honor <a download> on blob: URLs).
    WKUserScript* blobHookScript = [[WKUserScript alloc] initWithSource:JOGET_BLOB_HOOK_JS
                                                           injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                        forMainFrameOnly:NO];
    [configuration.userContentController addUserScript:blobHookScript];

    //WKWebView options
    configuration.allowsInlineMediaPlayback = _browserOptions.allowinlinemediaplayback;
    if (IsAtLeastiOSVersion(@"10.0")) {
        configuration.ignoresViewportScaleLimits = _browserOptions.enableviewportscale;
        if(_browserOptions.mediaplaybackrequiresuseraction == YES){
            configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
        }else{
            configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
        }
    }else{ // iOS 9
        configuration.mediaPlaybackRequiresUserAction = _browserOptions.mediaplaybackrequiresuseraction;
    }
    
    if (@available(iOS 13.0, *)) {
        NSString *contentMode = [self settingForKey:@"PreferredContentMode"];
        if ([contentMode isEqual: @"mobile"]) {
            configuration.defaultWebpagePreferences.preferredContentMode = WKContentModeMobile;
        } else if ([contentMode  isEqual: @"desktop"]) {
            configuration.defaultWebpagePreferences.preferredContentMode = WKContentModeDesktop;
        }
        
    }
    

    self.webView = [[WKWebView alloc] initWithFrame:webViewBounds configuration:configuration];
    
    [self.view addSubview:self.webView];
    [self.view sendSubviewToBack:self.webView];
    
    self.webViewUIDelegate.webView = self.webView;
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self.webViewUIDelegate;
    self.webView.backgroundColor = [UIColor whiteColor];
    if ([self settingForKey:@"OverrideUserAgent"] != nil) {
        self.webView.customUserAgent = [self settingForKey:@"OverrideUserAgent"];
    }
    
    self.webView.clearsContextBeforeDrawing = YES;
    self.webView.clipsToBounds = YES;
    self.webView.contentMode = UIViewContentModeScaleToFill;
    self.webView.multipleTouchEnabled = YES;
    self.webView.opaque = YES;
    self.webView.userInteractionEnabled = YES;
    self.automaticallyAdjustsScrollViewInsets = YES ;
    [self.webView setAutoresizingMask:UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth];
    self.webView.allowsLinkPreview = NO;
    self.webView.allowsBackForwardNavigationGestures = NO;
    
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
   if (@available(iOS 11.0, *)) {
       [self.webView.scrollView setContentInsetAdjustmentBehavior:UIScrollViewContentInsetAdjustmentNever];
   }
#endif
    
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.alpha = 1.000;
    self.spinner.autoresizesSubviews = YES;
    self.spinner.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin);
    self.spinner.clearsContextBeforeDrawing = NO;
    self.spinner.clipsToBounds = NO;
    self.spinner.contentMode = UIViewContentModeScaleToFill;
    self.spinner.frame = CGRectMake(CGRectGetMidX(self.webView.frame), CGRectGetMidY(self.webView.frame), 20.0, 20.0);
    self.spinner.hidden = NO;
    self.spinner.hidesWhenStopped = YES;
    self.spinner.multipleTouchEnabled = NO;
    self.spinner.opaque = NO;
    self.spinner.userInteractionEnabled = NO;
    [self.spinner stopAnimating];
    
    self.closeButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.closeButton.enabled = YES;
    
    UIBarButtonItem* flexibleSpaceButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    
    UIBarButtonItem* fixedSpaceButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    fixedSpaceButton.width = 20;
    
    float toolbarY = toolbarIsAtBottom ? self.view.bounds.size.height - TOOLBAR_HEIGHT : 0.0;
    CGRect toolbarFrame = CGRectMake(0.0, toolbarY, self.view.bounds.size.width, TOOLBAR_HEIGHT);
    
    self.toolbar = [[UIToolbar alloc] initWithFrame:toolbarFrame];
    self.toolbar.alpha = 1.000;
    self.toolbar.autoresizesSubviews = YES;
    self.toolbar.autoresizingMask = toolbarIsAtBottom ? (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin) : UIViewAutoresizingFlexibleWidth;
    self.toolbar.barStyle = UIBarStyleBlackOpaque;
    self.toolbar.clearsContextBeforeDrawing = NO;
    self.toolbar.clipsToBounds = NO;
    self.toolbar.contentMode = UIViewContentModeScaleToFill;
    self.toolbar.hidden = NO;
    self.toolbar.multipleTouchEnabled = NO;
    self.toolbar.opaque = NO;
    self.toolbar.userInteractionEnabled = YES;
    if (_browserOptions.toolbarcolor != nil) { // Set toolbar color if user sets it in options
      UIColor* toolbarColor = [self colorFromHexString:_browserOptions.toolbarcolor];
      self.toolbar.barTintColor = toolbarColor;
      // barTintColor alone is ignored on iOS 15+ unless the UIToolbarAppearance proxies are also set
      UIToolbarAppearance* toolbarAppearance = [[UIToolbarAppearance alloc] init];
      [toolbarAppearance configureWithOpaqueBackground];
      toolbarAppearance.backgroundColor = toolbarColor;
      self.toolbar.standardAppearance = toolbarAppearance;
      self.toolbar.compactAppearance = toolbarAppearance;
      self.toolbar.scrollEdgeAppearance = toolbarAppearance;
      self.toolbar.compactScrollEdgeAppearance = toolbarAppearance;
    }
    if (!_browserOptions.toolbartranslucent) { // Set toolbar translucent to no if user sets it in options
      self.toolbar.translucent = NO;
    }
    
    CGFloat labelInset = 5.0;
    float locationBarY = toolbarIsAtBottom ? self.view.bounds.size.height - FOOTER_HEIGHT : self.view.bounds.size.height - LOCATIONBAR_HEIGHT;
    
    self.addressLabel = [[UILabel alloc] initWithFrame:CGRectMake(labelInset, locationBarY, self.view.bounds.size.width - labelInset, LOCATIONBAR_HEIGHT)];
    self.addressLabel.adjustsFontSizeToFitWidth = NO;
    self.addressLabel.alpha = 1.000;
    self.addressLabel.autoresizesSubviews = YES;
    self.addressLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
    self.addressLabel.backgroundColor = [UIColor clearColor];
    self.addressLabel.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
    self.addressLabel.clearsContextBeforeDrawing = YES;
    self.addressLabel.clipsToBounds = YES;
    self.addressLabel.contentMode = UIViewContentModeScaleToFill;
    self.addressLabel.enabled = YES;
    self.addressLabel.hidden = YES;
    self.addressLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    
    if ([self.addressLabel respondsToSelector:NSSelectorFromString(@"setMinimumScaleFactor:")]) {
        [self.addressLabel setValue:@(10.0/[UIFont labelFontSize]) forKey:@"minimumScaleFactor"];
    } else if ([self.addressLabel respondsToSelector:NSSelectorFromString(@"setMinimumFontSize:")]) {
        [self.addressLabel setValue:@(10.0) forKey:@"minimumFontSize"];
    }
    
    self.addressLabel.multipleTouchEnabled = NO;
    self.addressLabel.numberOfLines = 1;
    self.addressLabel.opaque = NO;
    self.addressLabel.shadowOffset = CGSizeMake(0.0, -1.0);
    self.addressLabel.text = NSLocalizedString(@"Loading...", nil);
    self.addressLabel.textAlignment = NSTextAlignmentLeft;
    self.addressLabel.textColor = [UIColor colorWithWhite:1.000 alpha:1.000];
    self.addressLabel.userInteractionEnabled = NO;
    
    NSString* frontArrowString = NSLocalizedString(@"►", nil); // create arrow from Unicode char
    self.forwardButton = [[UIBarButtonItem alloc] initWithTitle:frontArrowString style:UIBarButtonItemStylePlain target:self action:@selector(goForward:)];
    self.forwardButton.enabled = YES;
    self.forwardButton.imageInsets = UIEdgeInsetsZero;
    if (_browserOptions.navigationbuttoncolor != nil) { // Set button color if user sets it in options
      self.forwardButton.tintColor = [self colorFromHexString:_browserOptions.navigationbuttoncolor];
    }

    NSString* backArrowString = NSLocalizedString(@"◄", nil); // create arrow from Unicode char
    self.backButton = [[UIBarButtonItem alloc] initWithTitle:backArrowString style:UIBarButtonItemStylePlain target:self action:@selector(goBack:)];
    self.backButton.enabled = YES;
    self.backButton.imageInsets = UIEdgeInsetsZero;
    if (_browserOptions.navigationbuttoncolor != nil) { // Set button color if user sets it in options
      self.backButton.tintColor = [self colorFromHexString:_browserOptions.navigationbuttoncolor];
    }

    // Filter out Navigation Buttons if user requests so
    if (_browserOptions.hidenavigationbuttons) {
        if (_browserOptions.lefttoright) {
            [self.toolbar setItems:@[flexibleSpaceButton, self.closeButton]];
        } else {
            [self.toolbar setItems:@[self.closeButton, flexibleSpaceButton]];
        }
    } else if (_browserOptions.lefttoright) {
        [self.toolbar setItems:@[self.backButton, fixedSpaceButton, self.forwardButton, flexibleSpaceButton, self.closeButton]];
    } else {
        [self.toolbar setItems:@[self.closeButton, flexibleSpaceButton, self.backButton, fixedSpaceButton, self.forwardButton]];
    }
    
    self.view.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.toolbar];
    [self.view addSubview:self.addressLabel];
    [self.view addSubview:self.spinner];
}

- (id)settingForKey:(NSString*)key
{
    return [_settings objectForKey:[key lowercaseString]];
}

- (void) setWebViewFrame : (CGRect) frame {
    NSLog(@"Setting the WebView's frame to %@", NSStringFromCGRect(frame));
    [self.webView setFrame:frame];
}

- (void)setCloseButtonTitle:(NSString*)title : (NSString*) colorString : (int) buttonIndex
{
    // the advantage of using UIBarButtonSystemItemDone is the system will localize it for you automatically
    // but, if you want to set this yourself, knock yourself out (we can't set the title for a system Done button, so we have to create a new one)
    self.closeButton = nil;
    // Initialize with title if title is set, otherwise the title will be 'Done' localized
    self.closeButton = title != nil ? [[UIBarButtonItem alloc] initWithTitle:title style:UIBarButtonItemStyleBordered target:self action:@selector(close)] : [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.closeButton.enabled = YES;
    // If color on closebutton is requested then initialize with that that color, otherwise use initialize with default
    self.closeButton.tintColor = colorString != nil ? [self colorFromHexString:colorString] : [UIColor colorWithRed:60.0 / 255.0 green:136.0 / 255.0 blue:230.0 / 255.0 alpha:1];
    
    NSMutableArray* items = [self.toolbar.items mutableCopy];
    [items replaceObjectAtIndex:buttonIndex withObject:self.closeButton];
    [self.toolbar setItems:items];
}

- (void)showLocationBar:(BOOL)show
{
    CGRect locationbarFrame = self.addressLabel.frame;
    
    BOOL toolbarVisible = !self.toolbar.hidden;
    
    // prevent double show/hide
    if (show == !(self.addressLabel.hidden)) {
        return;
    }
    
    if (show) {
        self.addressLabel.hidden = NO;
        
        if (toolbarVisible) {
            // toolBar at the bottom, leave as is
            // put locationBar on top of the toolBar
            
            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= FOOTER_HEIGHT;
            [self setWebViewFrame:webViewBounds];
            
            locationbarFrame.origin.y = webViewBounds.size.height;
            self.addressLabel.frame = locationbarFrame;
        } else {
            // no toolBar, so put locationBar at the bottom
            
            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= LOCATIONBAR_HEIGHT;
            [self setWebViewFrame:webViewBounds];
            
            locationbarFrame.origin.y = webViewBounds.size.height;
            self.addressLabel.frame = locationbarFrame;
        }
    } else {
        self.addressLabel.hidden = YES;
        
        if (toolbarVisible) {
            // locationBar is on top of toolBar, hide locationBar
            
            // webView take up whole height less toolBar height
            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= TOOLBAR_HEIGHT;
            [self setWebViewFrame:webViewBounds];
        } else {
            // no toolBar, expand webView to screen dimensions
            [self setWebViewFrame:self.view.bounds];
        }
    }
}

- (void)showToolBar:(BOOL)show : (NSString *) toolbarPosition
{
    CGRect toolbarFrame = self.toolbar.frame;
    CGRect locationbarFrame = self.addressLabel.frame;
    
    BOOL locationbarVisible = !self.addressLabel.hidden;
    
    // prevent double show/hide
    if (show == !(self.toolbar.hidden)) {
        return;
    }
    
    if (show) {
        self.toolbar.hidden = NO;
        CGRect webViewBounds = self.view.bounds;
        
        if (locationbarVisible) {
            // locationBar at the bottom, move locationBar up
            // put toolBar at the bottom
            webViewBounds.size.height -= FOOTER_HEIGHT;
            locationbarFrame.origin.y = webViewBounds.size.height;
            self.addressLabel.frame = locationbarFrame;
            self.toolbar.frame = toolbarFrame;
        } else {
            // no locationBar, so put toolBar at the bottom
            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= TOOLBAR_HEIGHT;
            self.toolbar.frame = toolbarFrame;
        }
        
        if ([toolbarPosition isEqualToString:kInAppBrowserToolbarBarPositionTop]) {
            toolbarFrame.origin.y = 0;
            webViewBounds.origin.y += toolbarFrame.size.height;
            [self setWebViewFrame:webViewBounds];
        } else {
            toolbarFrame.origin.y = (webViewBounds.size.height + LOCATIONBAR_HEIGHT);
        }
        [self setWebViewFrame:webViewBounds];
        
    } else {
        self.toolbar.hidden = YES;
        
        if (locationbarVisible) {
            // locationBar is on top of toolBar, hide toolBar
            // put locationBar at the bottom
            
            // webView take up whole height less locationBar height
            CGRect webViewBounds = self.view.bounds;
            webViewBounds.size.height -= LOCATIONBAR_HEIGHT;
            [self setWebViewFrame:webViewBounds];
            
            // move locationBar down
            locationbarFrame.origin.y = webViewBounds.size.height;
            self.addressLabel.frame = locationbarFrame;
        } else {
            // no locationBar, expand webView to screen dimensions
            [self setWebViewFrame:self.view.bounds];
        }
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    if (isExiting && (self.navigationDelegate != nil) && [self.navigationDelegate respondsToSelector:@selector(browserExit)]) {
        [self.navigationDelegate browserExit];
        isExiting = FALSE;
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
    NSString* statusBarStylePreference = [self settingForKey:@"InAppBrowserStatusBarStyle"];
    if (statusBarStylePreference && [statusBarStylePreference isEqualToString:@"lightcontent"]) {
        return UIStatusBarStyleLightContent;
    } else if (statusBarStylePreference && [statusBarStylePreference isEqualToString:@"darkcontent"]) {
        if (@available(iOS 13.0, *)) {
            return UIStatusBarStyleDarkContent;
        } else {
            return UIStatusBarStyleDefault;
        }
    } else {
        return UIStatusBarStyleDefault;
    }
}

- (BOOL)prefersStatusBarHidden {
    return NO;
}

- (void)close
{
    self.currentURL = nil;
    
    __weak UIViewController* weakSelf = self;
    
    // Run later to avoid the "took a long time" log message.
    dispatch_async(dispatch_get_main_queue(), ^{
        isExiting = TRUE;
        lastReducedStatusBarHeight = 0.0;
        if ([weakSelf respondsToSelector:@selector(presentingViewController)]) {
            [[weakSelf presentingViewController] dismissViewControllerAnimated:YES completion:nil];
        } else {
            [[weakSelf parentViewController] dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

- (void)navigateTo:(NSURL*)url
{
    if ([url.scheme isEqualToString:@"file"]) {
        [self.webView loadFileURL:url allowingReadAccessToURL:url];
    } else {
        NSURLRequest* request = [NSURLRequest requestWithURL:url];
        [self.webView loadRequest:request];
    }
}

- (void)goBack:(id)sender
{
    [self.webView goBack];
}

- (void)goForward:(id)sender
{
    [self.webView goForward];
}

- (void)viewWillAppear:(BOOL)animated
{
    [self rePositionViews];

    [super viewWillAppear:animated];
}

//
// On iOS 7 the status bar is part of the view's dimensions, therefore it's height has to be taken into account.
// The height of it could be hardcoded as 20 pixels, but that would assume that the upcoming releases of iOS won't
// change that value.
//
- (float) getStatusBarOffset {
    return (float) IsAtLeastiOSVersion(@"7.0") ? [[UIApplication sharedApplication] statusBarFrame].size.height : 0.0;
}

- (void) rePositionViews {
    CGRect viewBounds = [self.webView bounds];
    CGFloat statusBarHeight = [self getStatusBarOffset];
    
    // orientation portrait or portraitUpsideDown: status bar is on the top and web view is to be aligned to the bottom of the status bar
    // orientation landscapeLeft or landscapeRight: status bar height is 0 in but lets account for it in case things ever change in the future
    viewBounds.origin.y = statusBarHeight;

    CGFloat leftMargin = [[[UIApplication sharedApplication] delegate] window].safeAreaInsets.left;
    CGFloat rightMargin = [[[UIApplication sharedApplication] delegate] window].safeAreaInsets.right;
    CGFloat screenWidth = [[UIScreen mainScreen] bounds].size.width;

    if (leftMargin > 0) {
        viewBounds.origin.x = leftMargin;
        viewBounds.size.width = screenWidth - leftMargin - rightMargin;
    } else {
        viewBounds.origin.x = 0;
        viewBounds.size.width = screenWidth;
    }
    
    // account for web view height portion that may have been reduced by a previous call to this method
    viewBounds.size.height = viewBounds.size.height - statusBarHeight + lastReducedStatusBarHeight;
    lastReducedStatusBarHeight = statusBarHeight;
    
    if ((_browserOptions.toolbar) && ([_browserOptions.toolbarposition isEqualToString:kInAppBrowserToolbarBarPositionTop])) {
        // if we have to display the toolbar on top of the web view, we need to account for its height
        viewBounds.origin.y += TOOLBAR_HEIGHT;
        self.toolbar.frame = CGRectMake(self.toolbar.frame.origin.x, statusBarHeight, self.toolbar.frame.size.width, self.toolbar.frame.size.height);
    }
    
    self.webView.frame = viewBounds;
}

// Helper function to convert hex color string to UIColor
// Assumes input like "#00FF00" (#RRGGBB).
// Taken from https://stackoverflow.com/questions/1560081/how-can-i-create-a-uicolor-from-a-hex-string
- (UIColor *)colorFromHexString:(NSString *)hexString {
    unsigned rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hexString];
    [scanner setScanLocation:1]; // bypass '#' character
    [scanner scanHexInt:&rgbValue];
    return [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0 green:((rgbValue & 0xFF00) >> 8)/255.0 blue:(rgbValue & 0xFF)/255.0 alpha:1.0];
}

// Add download file download support
#pragma mark Download Support

- (NSString*)getDocumentsDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths firstObject];
 
    // Create a Downloads subdirectory in Documents
    NSString *downloadsDirectory = [documentsDirectory stringByAppendingPathComponent:@"Downloads"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
 
    NSError *error = nil;
    if (![fileManager fileExistsAtPath:downloadsDirectory]) {
        [fileManager createDirectoryAtPath:downloadsDirectory withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"Failed to create Downloads directory: %@", error.localizedDescription);
            return documentsDirectory; // Fallback to Documents directory
        }
    }
 
    return downloadsDirectory;
}

// All download-destination selection funnels through this single serial queue so that two downloads racing on different threads 
static dispatch_queue_t JogetDownloadFileIOQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("org.joget.inappbrowser.downloadFileIO", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Claims a filename inside `directory`, rejecting path-traversal tokens outright rather than
// relying on the incidental fact that "directory/.." always resolves to an existing parent to
// force the rename branch below. Appends " (1)", " (2)", etc. 
- (NSString*)reserveUniqueDestinationPathInDirectory:(NSString*)directory forFilename:(NSString*)filename {
    __block NSString *reservedPath = nil;
    dispatch_sync(JogetDownloadFileIOQueue(), ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];

        NSString *safeFilename = filename;
        if (safeFilename.length == 0 ||
            [safeFilename isEqualToString:@"."] ||
            [safeFilename isEqualToString:@".."] ||
            [safeFilename rangeOfString:@"/"].location != NSNotFound) {
            safeFilename = [self generateFilename:nil];
        }

        NSString *destinationPath = [directory stringByAppendingPathComponent:safeFilename];
        if ([fileManager fileExistsAtPath:destinationPath]) {
            NSString *baseName = [safeFilename stringByDeletingPathExtension];
            NSString *extension = [safeFilename pathExtension];
            NSInteger counter = 1;
            do {
                NSString *candidateName = extension.length > 0
                    ? [NSString stringWithFormat:@"%@ (%ld).%@", baseName, (long)counter, extension]
                    : [NSString stringWithFormat:@"%@ (%ld)", baseName, (long)counter];
                destinationPath = [directory stringByAppendingPathComponent:candidateName];
                counter++;
            } while ([fileManager fileExistsAtPath:destinationPath]);
        }

        [fileManager createFileAtPath:destinationPath contents:nil attributes:nil];
        reservedPath = destinationPath;
    });
    return reservedPath;
}

- (NSString*)generateFilename:(NSString*)mimeType {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyyMMdd_HHmmss"];
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];
    
    NSString *extension = @"bin";
    if ([mimeType isEqualToString:@"application/pdf"]) {
        extension = @"pdf";
    } else if ([mimeType isEqualToString:@"image/jpeg"]) {
        extension = @"jpg";
    } else if ([mimeType isEqualToString:@"image/png"]) {
        extension = @"png";
    } else if ([mimeType hasPrefix:@"text/"]) {
        extension = @"txt";
    }
    
    return [NSString stringWithFormat:@"download_%@.%@", timestamp, extension];
}

- (NSString*)extractFileName:(NSString*)contentDisposition {
    if (contentDisposition == nil) return nil;
    
    NSRange filenameRange = [contentDisposition rangeOfString:@"filename="];
    if (filenameRange.location != NSNotFound) {
        NSString *filenamePart = [contentDisposition substringFromIndex:filenameRange.location + filenameRange.length];
        filenamePart = [filenamePart stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
        if (filenamePart.length > 0) {
            return filenamePart;
        }
    }
    return nil;
}

- (void)downloadFileFromURLWithCookies:(NSURL*)url {
    NSLog(@"Starting authenticated download from URL: %@", url.absoluteString);
    
    // Get cookies from WKWebView to preserve authentication
    WKHTTPCookieStore *cookieStore = self.webView.configuration.websiteDataStore.httpCookieStore;
    
    [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        
        // Copy cookies from WKWebView to the download request
        NSDictionary *headers = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies];
        for (NSString *key in headers) {
            [request setValue:headers[key] forHTTPHeaderField:key];
        }
        
        NSLog(@"Added %lu cookies to download request", (unsigned long)cookies.count);

        // Create download session if not exists
        if (self.downloadSession == nil) {
            NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
            configuration.HTTPCookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
            configuration.HTTPShouldSetCookies = YES;
            self.downloadSession = [NSURLSession sessionWithConfiguration:configuration
                                                                 delegate:self
                                                            delegateQueue:nil];
        }
        
        // Create download task with cookies
        _currentDownloadTask = [self.downloadSession downloadTaskWithRequest:request];
        [self showDownloadingToast];
        [_currentDownloadTask resume];
    }];
}

#pragma mark Download Complete Alert

- (void)presentDownloadCompleteAlertForFileAtPath:(NSString*)destinationPath filename:(NSString*)filename {
    NSURL *fileURL = [NSURL fileURLWithPath:destinationPath];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Download Complete"
                         message:[NSString stringWithFormat:@"File saved as %@.", filename]
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Open"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        self.documentInteractionController = [UIDocumentInteractionController interactionControllerWithURL:fileURL];
        self.documentInteractionController.delegate = self;
        if (![self.documentInteractionController presentPreviewAnimated:YES]) {
            [self.documentInteractionController presentOptionsMenuFromRect:self.view.bounds
                                                                   inView:self.view
                                                                 animated:YES];
        }
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Close"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentDownloadFailedAlertWithMessage:(NSString*)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Download Failed"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Downloading Toast

- (void)showDownloadingToast {
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *label = [[UILabel alloc] init];
        label.text = @"Downloading...";
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:14];
        label.textAlignment = NSTextAlignmentCenter;

        UIView *toast = [[UIView alloc] init];
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
        toast.layer.cornerRadius = 16;
        toast.clipsToBounds = YES;
        toast.alpha = 0;
        toast.translatesAutoresizingMaskIntoConstraints = NO;
        label.translatesAutoresizingMaskIntoConstraints = NO;

        [toast addSubview:label];
        [self.view addSubview:toast];

        [NSLayoutConstraint activateConstraints:@[
            [label.topAnchor constraintEqualToAnchor:toast.topAnchor constant:10],
            [label.bottomAnchor constraintEqualToAnchor:toast.bottomAnchor constant:-10],
            [label.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor constant:20],
            [label.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor constant:-20],

            [toast.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [toast.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-80]
        ]];

        [UIView animateWithDuration:0.25 animations:^{
            toast.alpha = 1;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.25 delay:2.0 options:0 animations:^{
                toast.alpha = 0;
            } completion:^(BOOL finished2) {
                [toast removeFromSuperview];
            }];
        }];
    });
}

#pragma mark WKDownloadDelegate (iOS 14.5+)
- (void)webView:(WKWebView *)webView navigationResponse:(WKNavigationResponse *)navigationResponse didBecomeDownload:(WKDownload *)download API_AVAILABLE(ios(14.5)) {
    NSLog(@"WKDownloadDelegate: Download started for URL: %@", navigationResponse.response.URL.absoluteString);
    download.delegate = self;
    [self showDownloadingToast];
}

- (void)download:(WKDownload *)download decideDestinationUsingResponse:(NSURLResponse *)response suggestedFilename:(NSString *)suggestedFilename completionHandler:(void (^)(NSURL * _Nullable destination))completionHandler API_AVAILABLE(ios(14.5)) {
    NSLog(@"WKDownloadDelegate: Deciding destination for file: %@", suggestedFilename);
    
    // Get the app's Documents directory for private storage
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = paths.firstObject;

    // Reserve the full file path, renaming to avoid clobbering an existing file of the same name
    NSString *destinationPath = [self reserveUniqueDestinationPathInDirectory:documentsDirectory forFilename:suggestedFilename];
    NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];

    [[NSFileManager defaultManager] removeItemAtPath:destinationPath error:nil];

    // Store the destination URL for later use
    _wkDownloadDestinationURL = destinationURL;
    
    NSLog(@"WKDownloadDelegate: Download destination: %@", destinationPath);
    completionHandler(destinationURL);
}

- (void)download:(WKDownload *)download didFailWithError:(NSError *)error API_AVAILABLE(ios(14.5)) {
    NSLog(@"WKDownloadDelegate: Download failed with error: %@", error.localizedDescription);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Download Failed"
                                                                       message:error.localizedDescription
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)download:(WKDownload *)download didReceiveData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite API_AVAILABLE(ios(14.5)) {
    NSLog(@"WKDownloadDelegate: Download progress: %lld / %lld bytes", totalBytesWritten, totalBytesExpectedToWrite);
}

- (void)downloadDidFinish:(WKDownload *)download API_AVAILABLE(ios(14.5)) {
    NSLog(@"WKDownloadDelegate: Download finished successfully");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_wkDownloadDestinationURL) {
            NSString *filename = [_wkDownloadDestinationURL lastPathComponent];
            NSString *destinationPath = [_wkDownloadDestinationURL path];

            [self presentDownloadCompleteAlertForFileAtPath:destinationPath filename:filename];

            _wkDownloadDestinationURL = nil;
        }
    });
}
#pragma mark NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSLog(@"Download progress: %lld / %lld bytes", totalBytesWritten, totalBytesExpectedToWrite);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    NSLog(@"Download finished to temporary location: %@", location.absoluteString);
    NSLog(@"Final URL: %@", downloadTask.originalRequest.URL.absoluteString);
    NSLog(@"Response URL: %@", downloadTask.response.URL.absoluteString);
    
    // Check if the download was redirected (possible authentication issue)
    if (![downloadTask.originalRequest.URL.absoluteString isEqualToString:downloadTask.response.URL.absoluteString]) {
        NSLog(@"WARNING: Download was redirected from %@ to %@", 
              downloadTask.originalRequest.URL.absoluteString, 
              downloadTask.response.URL.absoluteString);
    }
    
    // Check response status code
    if ([downloadTask.response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)downloadTask.response;
        NSLog(@"HTTP Status Code: %ld", (long)httpResponse.statusCode);
        
        if (httpResponse.statusCode != 200) {
            NSLog(@"ERROR: Download failed with status code %ld", (long)httpResponse.statusCode);
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Download Failed"
                                                                               message:[NSString stringWithFormat:@"Server returned status code %ld. Authentication may be required.", (long)httpResponse.statusCode]
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            });
            _currentDownloadTask = nil;
            return;
        }
    }
    
    // Check file size
    NSError *fileError = nil;
    NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:&fileError];
    if (fileError == nil) {
        NSNumber *fileSize = [fileAttributes objectForKey:NSFileSize];
        NSLog(@"Downloaded file size: %lld bytes", [fileSize longLongValue]);
        
        if ([fileSize longLongValue] == 0) {
            NSLog(@"ERROR: Downloaded file is empty - possible authentication failure");
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Download Failed"
                                                                               message:@"Downloaded file is empty. The download may have failed due to authentication or server error."
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            });
            _currentDownloadTask = nil;
            return;
        }
    }
    
    // Get filename from response or generate one
    NSString *filename = [downloadTask.response suggestedFilename];
    if (filename == nil) {
        filename = [self generateFilename:nil];
    }
    
    // Reserve a destination in the documents directory, renaming to avoid clobbering an
    // existing file of the same name
    NSString *documentsPath = [self getDocumentsDirectory];
    NSString *destinationPath = [self reserveUniqueDestinationPathInDirectory:documentsPath forFilename:filename];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;

    // moveItemAtURL: fails if the destination already exists, so release our reservation
    // placeholder immediately before moving the downloaded file into place.
    [fileManager removeItemAtPath:destinationPath error:nil];
    [fileManager moveItemAtURL:location toURL:[NSURL fileURLWithPath:destinationPath] error:&error];
    
    if (error) {
        NSLog(@"Failed to move file: %@", error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Download Failed"
                                                                           message:@"Failed to save the file."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    } else {
        NSLog(@"File saved successfully to: %@", destinationPath);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentDownloadCompleteAlertForFileAtPath:destinationPath filename:[destinationPath lastPathComponent]];
        });
    }

    _currentDownloadTask = nil;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        NSLog(@"Download failed with error: %@", error.localizedDescription);
        NSLog(@"Error code: %ld", (long)error.code);
        NSLog(@"Error domain: %@", error.domain);
        
        // Check if it's an authentication error
        if (error.code == NSURLErrorUserAuthenticationRequired || 
            error.code == NSURLErrorUserCancelledAuthentication ||
            [error.localizedDescription containsString:@"authentication"]) {
            NSLog(@"ERROR: Authentication required for download");
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Authentication Required"
                                                                               message:@"This download requires authentication. Please ensure you are logged in."
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Download Failed"
                                                                               message:error.localizedDescription
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            });
        }
    } else {
        NSLog(@"Download task completed successfully");
    }
    _currentDownloadTask = nil;
}

#pragma mark UIDocumentInteractionControllerDelegate
 
- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller {
    return self;
}
 
- (UIView *)documentInteractionControllerViewForPreview:(UIDocumentInteractionController *)controller {
    return self.view;
}
 
- (CGRect)documentInteractionControllerRectForPreview:(UIDocumentInteractionController *)controller {
    return self.view.bounds;
}

#pragma mark WKNavigationDelegate

- (void)webView:(WKWebView *)theWebView didStartProvisionalNavigation:(WKNavigation *)navigation{
    
    // loading url, start spinner, update back/forward
    
    self.addressLabel.text = NSLocalizedString(@"Loading...", nil);
    self.backButton.enabled = theWebView.canGoBack;
    self.forwardButton.enabled = theWebView.canGoForward;
    
    NSLog(_browserOptions.hidespinner ? @"Yes" : @"No");
    if(!_browserOptions.hidespinner) {
        [self.spinner startAnimating];
    }
    
    return [self.navigationDelegate didStartProvisionalNavigation:theWebView];
}

- (void)webView:(WKWebView *)theWebView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL *url = navigationAction.request.URL;
    NSURL *mainDocumentURL = navigationAction.request.mainDocumentURL;
    
    BOOL isTopLevelNavigation = [url isEqual:mainDocumentURL];
    
    if (isTopLevelNavigation) {
        self.currentURL = url;
    }
    
    [self.navigationDelegate webView:theWebView decidePolicyForNavigationAction:navigationAction decisionHandler:decisionHandler];
}

- (void)webView:(WKWebView *)theWebView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    NSLog(@"Navigation response - MIME type: %@", navigationResponse.response.MIMEType);

    NSString *mimeType = navigationResponse.response.MIMEType;

    // Decide to download based on Content-Disposition header
    NSString *disposition = nil;
    if ([navigationResponse.response isKindOfClass:[NSHTTPURLResponse class]]) {
        disposition = ((NSHTTPURLResponse *)navigationResponse.response).allHeaderFields[@"Content-Disposition"];
    }
    BOOL isAttachment = disposition && [disposition.lowercaseString containsString:@"attachment"];
    
    if (isAttachment) {
        NSLog(@"Content-Disposition: attachment — downloading: %@", navigationResponse.response.URL.absoluteString);
        if (@available(iOS 14.5, *)) {
            NSLog(@"Detected downloadable file: %@ with MIME type: %@", navigationResponse.response.URL.absoluteString, mimeType);
            NSLog(@"Using WKDownloadDelegate for authenticated download");
            decisionHandler(WKNavigationResponsePolicyDownload);
            return;
        } else {
            NSLog(@"Using cookie-based download for iOS < 14.5");
            decisionHandler(WKNavigationResponsePolicyCancel);
            [self downloadFileFromURLWithCookies:navigationResponse.response.URL];
        }
        return;
    }

    // Client-generated downloads (e.g. jsPDF's pdf.save()) never hit a real HTTP response, so
    // they carry no Content-Disposition header - they show up here as a top-level navigation to
    // a blob: URL instead. WKWebView doesn't honor <a download> for blob: URLs, so without this
    // it would just render the blob inline (looks like an unwanted "preview"). Recover the
    // original Blob via the hook installed in createViews and save it natively instead.
    if ([navigationResponse.response.URL.scheme isEqualToString:@"blob"]) {
        NSLog(@"Detected blob: URL navigation, treating as a client-generated download: %@", navigationResponse.response.URL.absoluteString);
        decisionHandler(WKNavigationResponsePolicyCancel);
        [self showDownloadingToast];
        [self handleBlobURLDownload:navigationResponse.response.URL mimeType:mimeType];
        return;
    }

    // let the webview render inline (preview) if it not an attachment
    decisionHandler(WKNavigationResponsePolicyAllow);

}

#pragma mark Blob URL Download Support

// Mirrors handleBlobUrlDownload() in InAppBrowserDownloads.java (Android): retrieve the real
// Blob object captured by the createObjectURL hook, convert it to a base64 data URL in JS, and
// post it back over the existing cordova_iab bridge for userContentController:didReceiveScriptMessage: to save.
- (void)handleBlobURLDownload:(NSURL*)blobURL mimeType:(NSString*)mimeType {
    NSString *safeBlobUrl = [blobURL.absoluteString stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString *safeMimeType = mimeType ? [mimeType stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"] : @"";

    NSString *jsCode = [NSString stringWithFormat:@"(function() {"
        "  function sendError(msg) {"
        "    webkit.messageHandlers.%@.postMessage(JSON.stringify({action:'blobDownloadError', message: msg}));"
        "  }"
        "  if (!window.__jogetBlobStore) { sendError('Blob store not available'); return; }"
        "  var blobId = window.__jogetBlobStore['%@'];"
        "  var blob = blobId ? window.__jogetBlobStore[blobId] : null;"
        "  if (!blob) {"
        "    var keys = Object.keys(window.__jogetBlobStore).filter(function(k) { return k.indexOf('blob_') === 0; });"
        "    var latestKey = keys.sort().pop();"
        "    blob = latestKey ? window.__jogetBlobStore[latestKey] : null;"
        "  }"
        "  if (!blob) { sendError('No blob found in store'); return; }"
        "  var filename = (window.__jogetBlobFilenames && window.__jogetBlobFilenames['%@']) || '';"
        "  var reader = new FileReader();"
        "  reader.onloadend = function() {"
        "    webkit.messageHandlers.%@.postMessage(JSON.stringify({action:'blobDownload', data: reader.result, mimeType: blob.type || '%@', filename: filename}));"
        "  };"
        "  reader.onerror = function() { sendError('Blob conversion failed'); };"
        "  reader.readAsDataURL(blob);"
        "})();", IAB_BRIDGE_NAME, safeBlobUrl, safeBlobUrl, IAB_BRIDGE_NAME, safeMimeType];

    [self.webView evaluateJavaScript:jsCode completionHandler:^(id result, NSError *error) {
        if (error != nil) {
            NSLog(@"handleBlobURLDownload evaluateJavaScript error: %@", error.localizedDescription);
        }
    }];
}

- (void)webView:(WKWebView *)theWebView didFinishNavigation:(WKNavigation *)navigation
{
    // update url, stop spinner, update back/forward
    
    self.addressLabel.text = [self.currentURL absoluteString];
    self.backButton.enabled = theWebView.canGoBack;
    self.forwardButton.enabled = theWebView.canGoForward;
    theWebView.scrollView.contentInset = UIEdgeInsetsZero;
    
    [self.spinner stopAnimating];
    
    [self.navigationDelegate didFinishNavigation:theWebView];
}
    
- (void)webView:(WKWebView*)theWebView failedNavigation:(NSString*) delegateName withError:(nonnull NSError *)error{
    // log fail message, stop spinner, update back/forward
    NSLog(@"webView:%@ - %ld: %@", delegateName, (long)error.code, [error localizedDescription]);
    
    self.backButton.enabled = theWebView.canGoBack;
    self.forwardButton.enabled = theWebView.canGoForward;
    [self.spinner stopAnimating];
    
    self.addressLabel.text = NSLocalizedString(@"Load Error", nil);
    
    [self.navigationDelegate webView:theWebView didFailNavigation:error];
}

- (void)webView:(WKWebView*)theWebView didFailNavigation:(null_unspecified WKNavigation *)navigation withError:(nonnull NSError *)error
{
    [self webView:theWebView failedNavigation:@"didFailNavigation" withError:error];
}
    
- (void)webView:(WKWebView*)theWebView didFailProvisionalNavigation:(null_unspecified WKNavigation *)navigation withError:(nonnull NSError *)error
{
    [self webView:theWebView failedNavigation:@"didFailProvisionalNavigation" withError:error];
}

#pragma mark WKScriptMessageHandler delegate
- (void)userContentController:(nonnull WKUserContentController *)userContentController didReceiveScriptMessage:(nonnull WKScriptMessage *)message {
    if (![message.name isEqualToString:IAB_BRIDGE_NAME]) {
        return;
    }

    // Handle blob-download messages produced by handleBlobURLDownload: locally - these are
    // internal to the mobile app and shouldn't be forwarded to the Joget page's message listener.
    if ([message.body isKindOfClass:[NSString class]]) {
        NSData* jsonData = [(NSString*)message.body dataUsingEncoding:NSUTF8StringEncoding];
        NSError* __autoreleasing jsonError = nil;
        id parsedBody = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
        if (jsonError == nil && [parsedBody isKindOfClass:[NSDictionary class]]) {
            NSString* action = ((NSDictionary*)parsedBody)[@"action"];
            if ([action isEqualToString:@"blobDownload"]) {
                [self handleBlobDownloadMessage:(NSDictionary*)parsedBody];
                return;
            } else if ([action isEqualToString:@"blobDownloadError"]) {
                NSString* errorMessage = ((NSDictionary*)parsedBody)[@"message"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self presentDownloadFailedAlertWithMessage:errorMessage ?: @"Unknown error"];
                });
                return;
            }
        }
    }

    //NSLog(@"Received script message %@", message.body);
    [self.navigationDelegate userContentController:userContentController didReceiveScriptMessage:message];
}

// Decodes the base64 data URL produced by handleBlobURLDownload:'s injected JS and saves it,
// using the captured filename when available, else falling back to generateFilename:.
- (void)handleBlobDownloadMessage:(NSDictionary*)messageDict {
    NSString* dataUrl = messageDict[@"data"];
    NSString* mimeType = messageDict[@"mimeType"];
    if (dataUrl == nil) {
        return;
    }

    NSRange commaRange = [dataUrl rangeOfString:@","];
    NSString* base64String = (commaRange.location != NSNotFound) ? [dataUrl substringFromIndex:commaRange.location + 1] : dataUrl;
    NSData* fileData = [[NSData alloc] initWithBase64EncodedString:base64String options:NSDataBase64DecodingIgnoreUnknownCharacters];

    if (fileData == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentDownloadFailedAlertWithMessage:@"Failed to decode downloaded file."];
        });
        return;
    }

    // Prefer the name captured by the click hook in JOGET_BLOB_HOOK_JS;
    NSString* suggestedFilename = messageDict[@"filename"];
    NSString* filename = (suggestedFilename.length > 0) ? [suggestedFilename lastPathComponent] : [self generateFilename:mimeType];
    NSString* documentsDirectory = [self getDocumentsDirectory];
    NSString* destinationPath = [self reserveUniqueDestinationPathInDirectory:documentsDirectory forFilename:filename];

    // NSDataWritingAtomic overwrites our reservation placeholder safely, no need to remove it first.
    NSError* writeError = nil;
    [fileData writeToFile:destinationPath options:NSDataWritingAtomic error:&writeError];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (writeError != nil) {
            NSLog(@"Failed to save blob download: %@", writeError.localizedDescription);
            [self presentDownloadFailedAlertWithMessage:@"Failed to save the file."];
        } else {
            [self presentDownloadCompleteAlertForFileAtPath:destinationPath filename:[destinationPath lastPathComponent]];
        }
    });
}

#pragma mark CDVScreenOrientationDelegate

- (BOOL)shouldAutorotate
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(shouldAutorotate)]) {
        return [self.orientationDelegate shouldAutorotate];
    }
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    if ((self.orientationDelegate != nil) && [self.orientationDelegate respondsToSelector:@selector(supportedInterfaceOrientations)]) {
        return [self.orientationDelegate supportedInterfaceOrientations];
    }
    
    return 1 << UIInterfaceOrientationPortrait;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context)
    {
        [self rePositionViews];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context)
    {

    }];

    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

#pragma mark UIAdaptivePresentationControllerDelegate

- (void)presentationControllerWillDismiss:(UIPresentationController *)presentationController {
    isExiting = TRUE;
}

@end //CDVWKInAppBrowserViewController
