/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * See the NOTICE file distributed with this work for additional
 * information regarding copyright ownership.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "AMIntegrationTestCase.h"

#import "AMSnapshotUtils.h"
#import "FBConfiguration.h"

@interface AMIntegrationTestCase ()
@property (nonatomic, strong) XCUIApplication *testedApplication;
@end

@implementation AMIntegrationTestCase

- (void)setUp
{
  [super setUp];
  FBConfiguration.sharedConfiguration.attributeKeyPathAnalysis = NO;
  FBConfiguration.sharedConfiguration.automaticScreenshots = NO;
  self.continueAfterFailure = NO;
  self.testedApplication = [XCUIApplication new];
}

- (void)tearDown
{
  [super tearDown];
}

- (void)launchApplication
{
  [self.testedApplication launch];
}

- (void)switchToButtonsTab
{
  [self.testedApplication.radioButtons[@"Buttons"].firstMatch click];
}

- (void)switchToEditsTab
{
  [self.testedApplication.radioButtons[@"Edits"].firstMatch click];
}

- (void)switchToWebViewTab
{
  [self.testedApplication.radioButtons[@"WebView"].firstMatch click];
}

/**
 Reading AXDOMIdentifier (unlike ordinary XCTest snapshotting) goes through the macOS
 Accessibility API, which requires the process to be trusted under System Settings > Privacy &
 Security > Accessibility. Two things make that grant easy to lose track of while iterating
 locally in Xcode:

 - Ad-hoc code signing loses the grant on every rebuild. macOS ties an Accessibility grant to
   the binary's signing identity (its CDHash), and the default ad-hoc signature
   (Signature=adhoc, no Team ID) gets a new CDHash on every build. The permission then appears
   to "not stick" - it was actually granted, just to a binary that no longer exists. Assigning
   a stable signing identity (e.g. an "Apple Development" certificate under a real Team ID) in
   the target's Signing & Capabilities keeps the CDHash constant across rebuilds, so the grant
   persists. This has to be done for both the WebDriverAgent app target and the
   IntegrationTests test bundle target - granting only one leaves the other still ad-hoc signed
   and still losing trust every build.
 - xcodebuild build alone does not regenerate the signed XCTRunner wrapper app that actually
   hosts and runs the tests, so a plain build after a signing change can silently run against a
   stale runner. Use build-for-testing (or test, or Xcode's own Test action) instead.
 */
- (void)skipUnlessAccessibilityTrusted
{
  XCTSkipUnless(AMSnapshotUtils.isAccessibilityTrusted,
               @"This process is not trusted for the Accessibility API. Grant Accessibility "
               @"permission to it in System Settings > Privacy & Security > Accessibility "
               @"(note: an ad-hoc-signed build's grant does not survive a rebuild), then re-run.");
}

@end
