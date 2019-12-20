/*
 * Endless
 * Copyright (c) 2014-2018 joshua stein <jcs@jcs.org>
 *
 * See LICENSE file for redistribution terms.
 */

#import <AVFoundation/AVFoundation.h>

#import "AppDelegate.h"
#import "HTTPSEverywhere.h"
#import "DownloadHelper.h"

#import "UIResponder+FirstResponder.h"

#import "OBRootViewController.h"
#import "SilenceWarnings.h"
#import "OnionBrowser-Swift.h"

@implementation AppDelegate
{
	NSMutableArray *_keyCommands;
	NSMutableArray *_allKeyBindings;
	NSArray *_allCommandsAndKeyBindings;

	BOOL inStartupPhase;

	UIAlertController *authAlertController;
}


# pragma mark: - UIApplicationDelegate

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	inStartupPhase = YES;

	self.socksProxyPort = 39050;
	_sslCertCache = [[NSCache alloc] init];
	_certificateAuthentication = [[CertificateAuthentication alloc] init];
	_defaultUserAgent = [self createUserAgent];

	[JAHPAuthenticatingHTTPProtocol setDelegate:self];
	[JAHPAuthenticatingHTTPProtocol start];

	_hstsCache = [HSTSCache retrieve];
	_cookieJar = [[CookieJar alloc] init];

	/* handle per-version upgrades or migrations */
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	long lastBuild = [userDefaults integerForKey:@"last_build"];
	
	NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
	f.numberStyle = NSNumberFormatterDecimalStyle;
	long thisBuild = [[f numberFromString:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"]] longValue];
	
	if (lastBuild != thisBuild) {
		NSLog(@"migrating from build %ld -> %ld", lastBuild, thisBuild);
		// Nothing to migrate, currently.

		[userDefaults setInteger:thisBuild forKey:@"last_build"];
		[userDefaults synchronize];
	}
	
	self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	self.window.backgroundColor = [UIColor groupTableViewBackgroundColor];
	self.window.rootViewController = [[OBRootViewController alloc] init];
	self.window.rootViewController.restorationIdentifier = @"OBRootViewController";

	[self adjustMuteSwitchBehavior];
	
    [Migration migrate];

	[DownloadHelper deleteDownloadsDirectory];

    return YES;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	[self.window makeKeyAndVisible];

	if (launchOptions != nil && [launchOptions objectForKey:UIApplicationLaunchOptionsShortcutItemKey]) {
		[self handleShortcut:[launchOptions objectForKey:UIApplicationLaunchOptionsShortcutItemKey]];
	}
	
	return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application
{
	[application ignoreSnapshotOnNextApplicationLaunch];
	[self.browsingUi becomesInvisible];

	[BlurredSnapshot create];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
	if (![self areTesting]) {
		[HostSettings store];
		[[self hstsCache] persist];
	}
	
	[TabSecurity handleBackgrounding];

	[application ignoreSnapshotOnNextApplicationLaunch];

    if (OnionManager.shared.state != TorStateStopped) {
        [OnionManager.shared stopTor];
    }
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
	[BlurredSnapshot remove];

	[self.browsingUi becomesVisible];

    if (!inStartupPhase && OnionManager.shared.state != TorStateStarted && OnionManager.shared.state != TorStateConnected) {
        // TODO: actually use UI instead of silently trying to restart Tor.
        [OnionManager.shared startTorWithDelegate:nil];

//        if ([self.window.rootViewController class] != [OBRootViewController class]) {
//                self.window.rootViewController = [[OBRootViewController alloc] init];
//                self.window.rootViewController.restorationIdentifier = @"OBRootViewController";
//        }
    }
    else {
		// During app startup, we don't start Tor from here, but from
		// OBRootViewController in order to catch the delegate callback for progress.
		inStartupPhase = NO;
//        [self.browsingUi becomesVisible];
    }
}

- (void)applicationWillTerminate:(UIApplication *)application
{
	/* this definitely ends our sessions */
	[[self cookieJar] clearAllNonWhitelistedData];

	[DownloadHelper deleteDownloadsDirectory];

	[application ignoreSnapshotOnNextApplicationLaunch];
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
#ifdef TRACE
	NSLog(@"[AppDelegate] request to open url: %@", url);
#endif

	url = url.withFixedScheme;

	// In case, a modal view controller is overlaying the WebViewController,
	// we need to close it *before* adding a new tab. Otherwise, the UI will
	// be broken on iPhone-X-type devices: The address field will be in the
	// notch area.
	if (self.browsingUi.presentedViewController != nil)
	{
		[self.browsingUi dismissViewControllerAnimated:YES completion:^{
			[self.browsingUi addNewTab:url];
		}];
	}
	// If there's no modal view controller, however, the completion block would
	// never be called.
	else {
		[self.browsingUi addNewTab:url];
	}

	return YES;
}

- (void)application:(UIApplication *)application performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL))completionHandler
{
	[self handleShortcut:shortcutItem];
	completionHandler(YES);
}

- (BOOL)application:(UIApplication *)application shouldAllowExtensionPointIdentifier:(NSString *)extensionPointIdentifier {
	if ([extensionPointIdentifier isEqualToString:UIApplicationKeyboardExtensionPointIdentifier]) {
		return Settings.thirdPartyKeyboards;
	}
	return YES;
}

- (BOOL)application:(UIApplication *)application shouldRestoreApplicationState:(NSCoder *)coder
{
	if ([self areTesting])
		return NO;
	
	/* if we tried last time and failed, the state might be corrupt */
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	if ([userDefaults objectForKey:STATE_RESTORE_TRY_KEY] != nil) {
		NSLog(@"[AppDelegate] previous startup failed, not restoring application state");
		[userDefaults removeObjectForKey:STATE_RESTORE_TRY_KEY];
		return NO;
	}
	else
		[userDefaults setBool:YES forKey:STATE_RESTORE_TRY_KEY];
	
	[userDefaults synchronize];

	return YES;
}

- (BOOL)application:(UIApplication *)application shouldSaveApplicationState:(NSCoder *)coder
{
	if ([self areTesting])
		return NO;

	return !TabSecurity.isClearOnBackground;
}


# pragma mark: - Endless

- (NSArray<UIKeyCommand *> *)keyCommands
{
	if (!_keyCommands) {
		_keyCommands = [[NSMutableArray alloc] init];
		
		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"[" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Go Back", nil)]];
		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"]" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Go Forward", nil)]];

		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"b" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Show Bookmarks", nil)]];

		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"l" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Focus URL Field", nil)]];

		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"r" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Reload Tab", nil)]];

		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"t" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Create New Tab", nil)]];
		[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"w" modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:NSLocalizedString(@"Close Tab", nil)]];

		for (int i = 1; i <= 10; i++)
			[_keyCommands addObject:[UIKeyCommand keyCommandWithInput:[NSString stringWithFormat:@"%d", (i == 10 ? 0 : i)] modifierFlags:UIKeyModifierCommand action:@selector(handleKeyboardShortcut:) discoverabilityTitle:[NSString stringWithFormat:NSLocalizedString(@"Switch to Tab %d", nil), i]]];
	}
	
	if (!_allKeyBindings) {
		_allKeyBindings = [[NSMutableArray alloc] init];
		const long modPermutations[] = {
					     UIKeyModifierAlphaShift,
					     UIKeyModifierShift,
					     UIKeyModifierControl,
					     UIKeyModifierAlternate,
					     UIKeyModifierCommand,
					     UIKeyModifierCommand | UIKeyModifierAlternate,
					     UIKeyModifierCommand | UIKeyModifierControl,
					     UIKeyModifierControl | UIKeyModifierAlternate,
					     UIKeyModifierControl | UIKeyModifierCommand,
					     UIKeyModifierControl | UIKeyModifierAlternate | UIKeyModifierCommand,
					     kNilOptions,
		};

		NSString *chars = @"`1234567890-=\b\tqwertyuiop[]\\asdfghjkl;'\rzxcvbnm,./ ";
		for (int j = 0; j < sizeof(modPermutations); j++) {
			for (int i = 0; i < [chars length]; i++) {
				NSString *c = [chars substringWithRange:NSMakeRange(i, 1)];

				[_allKeyBindings addObject:[UIKeyCommand keyCommandWithInput:c modifierFlags:modPermutations[j] action:@selector(handleKeyboardShortcut:)]];
			}
		
			[_allKeyBindings addObject:[UIKeyCommand keyCommandWithInput:UIKeyInputUpArrow modifierFlags:modPermutations[j] action:@selector(handleKeyboardShortcut:)]];
			[_allKeyBindings addObject:[UIKeyCommand keyCommandWithInput:UIKeyInputDownArrow modifierFlags:modPermutations[j] action:@selector(handleKeyboardShortcut:)]];
			[_allKeyBindings addObject:[UIKeyCommand keyCommandWithInput:UIKeyInputLeftArrow modifierFlags:modPermutations[j] action:@selector(handleKeyboardShortcut:)]];
			[_allKeyBindings addObject:[UIKeyCommand keyCommandWithInput:UIKeyInputRightArrow modifierFlags:modPermutations[j] action:@selector(handleKeyboardShortcut:)]];
			[_allKeyBindings addObject:[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:modPermutations[j] action:@selector(handleKeyboardShortcut:)]];
		}
		
		_allCommandsAndKeyBindings = [_keyCommands arrayByAddingObjectsFromArray:_allKeyBindings];
	}
	
	/* if settings are up or something else, ignore shortcuts */
	if (![[self topViewController] isKindOfClass:[BrowsingViewController class]])
		return nil;
	
	id cur = [UIResponder currentFirstResponder];
	if (cur == nil || [NSStringFromClass([cur class]) isEqualToString:@"UIWebView"])
		return _allCommandsAndKeyBindings;
	else {
#ifdef TRACE_KEYBOARD_INPUT
		NSLog(@"[AppDelegate] current first responder is a %@, only passing shortcuts", NSStringFromClass([cur class]));
#endif
		return _keyCommands;
	}
}

- (void)handleKeyboardShortcut:(UIKeyCommand *)keyCommand
{
	if ([keyCommand modifierFlags] == UIKeyModifierCommand) {
		if ([[keyCommand input] isEqualToString:@"b"]) {
			[self.browsingUi showBookmarks];
			return;
		}

		if ([[keyCommand input] isEqualToString:@"l"]) {
			[self.browsingUi focusSearchField];
			return;
		}
		
		if ([[keyCommand input] isEqualToString:@"r"]) {
			[self.browsingUi.currentTab refresh];
			return;
		}

		if ([[keyCommand input] isEqualToString:@"t"]) {
			[self.browsingUi addEmptyTabAndFocus];
			return;
		}
		
		if ([[keyCommand input] isEqualToString:@"w"]) {
			[self.browsingUi removeCurrentTab];
			return;
		}
		
		if ([[keyCommand input] isEqualToString:@"["]) {
			[self.browsingUi.currentTab goBack];
			return;
		}
		
		if ([[keyCommand input] isEqualToString:@"]"]) {
			[self.browsingUi.currentTab goForward];
			return;
		}

		for (int i = 0; i <= 9; i++) {
			if ([[keyCommand input] isEqualToString:[NSString stringWithFormat:@"%d", i]]) {
				[self.browsingUi switchToTab:(i == 0 ? 9 : i - 1)];
				return;
			}
		}
	}
	
	if (self.browsingUi && self.browsingUi.currentTab)
		[self.browsingUi.currentTab handleKeyCommand:keyCommand];
}

- (UIViewController *)topViewController
{
	return [self topViewController:[UIApplication sharedApplication].keyWindow.rootViewController];
}

- (UIViewController *)topViewController:(UIViewController *)rootViewController
{
	if (rootViewController.presentedViewController == nil)
		return rootViewController;
	
	if ([rootViewController.presentedViewController isMemberOfClass:[UINavigationController class]]) {
		UINavigationController *navigationController = (UINavigationController *)rootViewController.presentedViewController;
		UIViewController *lastViewController = [[navigationController viewControllers] lastObject];
		return [self topViewController:lastViewController];
	}
	
	UIViewController *presentedViewController = (UIViewController *)rootViewController.presentedViewController;
	return [self topViewController:presentedViewController];
}

- (BOOL)areTesting
{
	if (NSClassFromString(@"XCTestProbe") != nil) {
		NSLog(@"we are testing");
		return YES;
	}
	else {
		NSDictionary *environment = [[NSProcessInfo processInfo] environment];
		if (environment[@"ARE_UI_TESTING"]) {
			NSLog(@"we are UI testing");
			return YES;
		}
	}
	
	return NO;
}

- (void)handleShortcut:(UIApplicationShortcutItem *)shortcutItem
{
	if ([shortcutItem.type containsString:@"OpenNewTab"])
	{
		[self.browsingUi dismissViewControllerAnimated:YES completion:nil];
		[self.browsingUi addEmptyTabAndFocus];
	}
	else if ([shortcutItem.type containsString:@"ClearData"]) {
		[self.browsingUi removeAllTabs];
	}
	else {
		NSLog(@"[AppDelegate] need to handle action %@", [shortcutItem type]);
	}
}

- (void)adjustMuteSwitchBehavior
{
	if (Settings.muteWithSwitch) {
		/* setting AVAudioSessionCategoryAmbient will prevent audio from UIWebView from pausing already-playing audio from other apps */
		[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
		[[AVAudioSession sharedInstance] setActive:NO error:nil];
	} else {
		[[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
	}
}

/**
 Some sites do mobile detection by looking for Safari in the UA, so make us look like Mobile Safari

 from "Mozilla/5.0 (iPhone; CPU iPhone OS 8_4_1 like Mac OS X) AppleWebKit/600.1.4 (KHTML, like Gecko) Mobile/12H321"
 to   "Mozilla/5.0 (iPhone; CPU iPhone OS 8_4_1 like Mac OS X) AppleWebKit/600.1.4 (KHTML, like Gecko) Version/8.0 Mobile/12H321 Safari/600.1.4"
 */
- (NSString *)createUserAgent
{
	SILENCE_DEPRECATION_ON
	UIWebView *twv = [[UIWebView alloc] initWithFrame:CGRectZero];
	SILENCE_WARNINGS_OFF
	NSString *ua = [twv stringByEvaluatingJavaScriptFromString:@"navigator.userAgent"];

	NSMutableArray *uapieces = [[ua componentsSeparatedByString:@" "] mutableCopy];
	NSString *uamobile = uapieces[uapieces.count - 1];

	// Assume Safari major version will match iOS major.
	NSArray *osv = [UIDevice.currentDevice.systemVersion componentsSeparatedByString:@"."];
	uapieces[uapieces.count - 1] = [NSString stringWithFormat:@"Version/%@.0", osv[0]];

	[uapieces addObject:uamobile];

	// Now tack on "Safari/XXX.X.X" from WebKit version.
	for (NSString* j in uapieces) {
		if ([j containsString:@"AppleWebKit/"]) {
			[uapieces addObject:[j stringByReplacingOccurrencesOfString:@"AppleWebKit" withString:@"Safari"]];
			break;
		}
	}

	return [uapieces componentsJoinedByString:@" "];
}


# pragma mark: Psiphon

+ (AppDelegate *)sharedAppDelegate
{
	__block AppDelegate *delegate;

	if ([NSThread isMainThread])
	{
		delegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
	}
	else {
		dispatch_sync(dispatch_get_main_queue(), ^{
			delegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
		});
	}
	
	return delegate;
}


# pragma mark: JAHPAuthenticatingHTTPProtocol delegate methods

#ifdef TRACE
- (void)authenticatingHTTPProtocol:(JAHPAuthenticatingHTTPProtocol *)authenticatingHTTPProtocol logWithFormat:(NSString *)format arguments:(va_list)arguments {
	NSLog(@"[JAHPAuthenticatingHTTPProtocol] %@", [[NSString alloc] initWithFormat:format arguments:arguments]);
}
#endif

- (BOOL)authenticatingHTTPProtocol:( JAHPAuthenticatingHTTPProtocol *)authenticatingHTTPProtocol canAuthenticateAgainstProtectionSpace:( NSURLProtectionSpace *)protectionSpace {
	return ([protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPDigest]
			|| [protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodHTTPBasic]);
}

- (JAHPDidCancelAuthenticationChallengeHandler)authenticatingHTTPProtocol:( JAHPAuthenticatingHTTPProtocol *)authenticatingHTTPProtocol didReceiveAuthenticationChallenge:( NSURLAuthenticationChallenge *)challenge {
	NSURLCredential *nsuc;

	/* if we have existing credentials for this realm, try it first */
	if ([challenge previousFailureCount] == 0) {
		NSDictionary *d = [[NSURLCredentialStorage sharedCredentialStorage] credentialsForProtectionSpace:[challenge protectionSpace]];
		if (d != nil) {
			for (id u in d) {
				nsuc = [d objectForKey:u];
				break;
			}
		}
	}

	/* no credentials, prompt the user */
	if (nsuc == nil) {
		dispatch_async(dispatch_get_main_queue(), ^{
			self->authAlertController = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Authentication Required", @"HTTP authentication alert title") message:@"" preferredStyle:UIAlertControllerStyleAlert];

			if ([[challenge protectionSpace] realm] != nil && ![[[challenge protectionSpace] realm] isEqualToString:@""])
			[self->authAlertController setMessage:[NSString stringWithFormat:@"%@: \"%@\"", [[challenge protectionSpace] host], [[challenge protectionSpace] realm]]];
			else
			[self->authAlertController setMessage:[[challenge protectionSpace] host]];

			[self->authAlertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
				textField.placeholder = NSLocalizedString(@"User Name", "HTTP authentication alert user name input title");
			}];

			[self->authAlertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
				textField.placeholder = NSLocalizedString(@"Password", @"HTTP authentication alert password input title");
				textField.secureTextEntry = YES;
			}];

			[self->authAlertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", @"Cancel action") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
				[[challenge sender] cancelAuthenticationChallenge:challenge];
				[authenticatingHTTPProtocol.client URLProtocol:authenticatingHTTPProtocol didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:@{ ORIGIN_KEY: @YES }]];
			}]];

			[self->authAlertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Log In", @"HTTP authentication alert log in button action") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
				UITextField *login = self->authAlertController.textFields.firstObject;
				UITextField *password = self->authAlertController.textFields.lastObject;

				NSURLCredential *nsuc = [[NSURLCredential alloc] initWithUser:[login text] password:[password text] persistence:NSURLCredentialPersistenceForSession];

				// We only want one set of credentials per [challenge protectionSpace]
				// in case we stored incorrect credentials on the previous login attempt
				// Purge stored credentials for the [challenge protectionSpace]
				// before storing new ones.
				// Based on a snippet from http://www.springenwerk.com/2008/11/i-am-currently-building-iphone.html

				NSDictionary *credentialsDict = [[NSURLCredentialStorage sharedCredentialStorage] credentialsForProtectionSpace:[challenge protectionSpace]];
				if ([credentialsDict count] > 0) {
					NSEnumerator *userNameEnumerator = [credentialsDict keyEnumerator];
					id userName;

					// iterate over all usernames, which are the keys for the actual NSURLCredentials
					while (userName = [userNameEnumerator nextObject]) {
						NSURLCredential *cred = [credentialsDict objectForKey:userName];
						if(cred) {
							[[NSURLCredentialStorage sharedCredentialStorage] removeCredential:cred forProtectionSpace:[challenge protectionSpace]];
						}
					}
				}

				[[NSURLCredentialStorage sharedCredentialStorage] setCredential:nsuc forProtectionSpace:[challenge protectionSpace]];

				[authenticatingHTTPProtocol resolvePendingAuthenticationChallengeWithCredential:nsuc];
			}]];

			[AppDelegate.sharedAppDelegate.browsingUi presentViewController:self->authAlertController animated:YES completion:nil];
		});
	}
	else {
		[[NSURLCredentialStorage sharedCredentialStorage] setCredential:nsuc forProtectionSpace:[challenge protectionSpace]];
		[authenticatingHTTPProtocol resolvePendingAuthenticationChallengeWithCredential:nsuc];
	}

	return nil;

}

- (void)authenticatingHTTPProtocol:( JAHPAuthenticatingHTTPProtocol *)authenticatingHTTPProtocol didCancelAuthenticationChallenge:( NSURLAuthenticationChallenge *)challenge {
	if(authAlertController) {
		if (authAlertController.isViewLoaded && authAlertController.view.window) {
			[authAlertController dismissViewControllerAnimated:NO completion:nil];
		}
	}
}

@end
