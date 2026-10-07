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

#import "RouteResponse.h"

@interface RouteResponse ()
@property (nonatomic, copy) NSMutableDictionary<NSString *, NSString *> *mutableHeaders;
@end

@implementation RouteResponse

- (instancetype)init
{
  if ((self = [super init])) {
    _statusCode = 200;
    _mutableHeaders = [NSMutableDictionary dictionary];
  }
  return self;
}

- (NSDictionary<NSString *, NSString *> *)headers
{
  return self.mutableHeaders.copy;
}

- (void)setHeader:(NSString *)field value:(NSString *)value
{
  self.mutableHeaders[field] = value;
}

- (void)respondWithData:(NSData *)data
{
  _responseData = data.copy;
  if (nil == self.mutableHeaders[@"Content-Length"]) {
    self.mutableHeaders[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)data.length];
  }
}

- (void)respondWithString:(NSString *)string
{
  [self respondWithString:string encoding:NSUTF8StringEncoding];
}

- (void)respondWithString:(NSString *)string encoding:(NSStringEncoding)encoding
{
  [self respondWithData:[string dataUsingEncoding:encoding] ?: [NSData data]];
}

@end
