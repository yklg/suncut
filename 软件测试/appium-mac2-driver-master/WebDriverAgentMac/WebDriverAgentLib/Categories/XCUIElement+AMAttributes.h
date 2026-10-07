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

NS_ASSUME_NONNULL_BEGIN

/*!
 Predicate string / class chain keypath names for the am_* attributes below. These are
 non-standard, Mac2-driver-specific attributes, in addition to the standard
 XCUIElementAttributes ones.
 */
extern NSString *const AM_IDENTIFIER_ATTRIBUTE_NAME;
extern NSString *const AM_RECT_ATTRIBUTE_NAME;
extern NSString *const AM_TEXT_ATTRIBUTE_NAME;
extern NSString *const AM_TYPE_ATTRIBUTE_NAME;
extern NSString *const AM_HAS_KEYBOARD_INPUT_FOCUS_ATTRIBUTE_NAME;

@interface XCUIElement (AMAttributes)

/**
 Retrieves WebDriver-compatible value for the given attribute name

 @param name one of supported attribute names. See https://developer.apple.com/documentation/xctest/xcuielementattributes?language=objc
 @return The attribute value converted to a string or nil. Only `frame` value is returned as dictionary
 */
- (nullable id)am_wdAttributeValueWithName:(NSString *)name;

/**
 Element rectangle in dictionary representation
 */
- (NSDictionary<NSString *, NSNumber *> *)am_rect;

/**
 Element text. If no text is found then an empty string is returned.

 @throws Error if `fetchFullText` setting is enabled and there was an error while fetching the snapshot
 */
- (NSString *)am_text;

/**
 Element type represented as string
 */
- (NSString *)am_type;

/**
 Results in YES if the current element has the keyboard input focus
 */
- (BOOL)am_hasKeyboardInputFocus;

/**
 The element's identifier as WebDriver reports it: the standard accessibility
 identifier, falling back to the WebKit DOM identifier for web nodes, which leave the
 standard one empty. The fallback only applies while useDomIdAsAccessibilityId is
 enabled, and only takes a snapshot when it is actually needed.

 @return The identifier. Could be an empty string
 */
- (NSString *)am_identifier;

/**
 The full set of am_* predicate attribute names (AM_IDENTIFIER_ATTRIBUTE_NAME and
 friends) usable in predicate string / class chain locators.
 */
+ (NSArray<NSString *> *)am_predicateAttributeNames;

/**
 Resolves the value of an am_* predicate attribute name directly against a target,
 which may be a live XCUIElement or a raw id<XCUIElementSnapshot> - the latter keeps
 per-node predicate evaluation cheap by not needing to resolve a live element first.

 @param name one of AM_IDENTIFIER_ATTRIBUTE_NAME and friends
 @param target the XCUIElement or id<XCUIElementSnapshot> to resolve the value against
 @return The resolved value, or nil if name is not a known am_* attribute name
 */
+ (nullable id)am_valueForPredicateAttributeName:(NSString *)name target:(id)target;

@end

NS_ASSUME_NONNULL_END
