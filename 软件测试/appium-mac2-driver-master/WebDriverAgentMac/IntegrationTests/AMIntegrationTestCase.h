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

#import <XCTest/XCTest.h>
#import <WebDriverAgentLib/WebDriverAgentLib.h>

NS_ASSUME_NONNULL_BEGIN

@interface AMIntegrationTestCase : XCTestCase

@property (nonatomic, strong, readonly) XCUIApplication *testedApplication;

/**
 Launches application and resets side effects of testing like orientation etc.
 */
- (void)launchApplication;

- (void)switchToButtonsTab;

- (void)switchToEditsTab;

- (void)switchToWebViewTab;

/**
 Skips the current test unless this process is trusted for the Accessibility API.
 Tests that rely on the useDomIdAsAccessibilityId fallback need this - without it,
 WebKit DOM identifier resolution silently returns nothing, which otherwise surfaces
 as a confusing "found 0 elements" test failure rather than a clear "grant
 Accessibility permission and re-run" skip reason.
 */
- (void)skipUnlessAccessibilityTrusted;

@end

NS_ASSUME_NONNULL_END
