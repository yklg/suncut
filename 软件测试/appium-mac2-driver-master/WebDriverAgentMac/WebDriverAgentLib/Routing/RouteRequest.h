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

// A minimal request value type, exposing just the surface FBWebServer's route blocks and
// FBRoute.decorateRequest: read.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RouteRequest : NSObject

@property (nonatomic, copy, readonly) NSURL *url;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *params;
@property (nonatomic, copy, readonly) NSData *body;

- (instancetype)initWithURL:(NSURL *)url
                      params:(NSDictionary<NSString *, NSString *> *)params
                        body:(NSData *)body;

@end

NS_ASSUME_NONNULL_END
