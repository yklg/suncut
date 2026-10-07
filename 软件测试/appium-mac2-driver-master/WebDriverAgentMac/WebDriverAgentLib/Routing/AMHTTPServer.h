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

// A minimal HTTP/1.1 server on top of AMTCPSocket (Network.framework-backed).
//
// No chunked encoding, range requests, or pipelining - just request line + headers +
// Content-Length body, and ":param" path matching.

#import <Foundation/Foundation.h>

#import "RouteRequest.h"
#import "RouteResponse.h"

NS_ASSUME_NONNULL_BEGIN

@interface AMHTTPServer : NSObject

/*! The port the server is (or will be) listening on */
@property (nonatomic) uint16_t port;

/*! Whether the server is currently listening for connections */
@property (nonatomic, readonly) BOOL isRunning;

/**
 Sets the dispatch queue on which route blocks are invoked. Pass NULL to invoke them
 synchronously on the socket's own queue.
 */
- (void)setRouteQueue:(nullable dispatch_queue_t)queue;

/**
 Sets a header which is added to every response, unless overridden by the route itself.
 */
- (void)setDefaultHeader:(NSString *)field value:(NSString *)value;

/**
 Sets the local IP address to bind the listener to. Must be called before -start:. Pass nil (the
 default) to listen on all interfaces.
 */
- (void)setInterface:(nullable NSString *)interface;

/**
 Registers a route handler for the given HTTP method and path pattern (":param" segments are
 captured into the request's `params`).
 */
- (void)handleMethod:(NSString *)method
            withPath:(NSString *)path
               block:(void (^)(RouteRequest *request, RouteResponse *response))block;

/**
 Convenience for -handleMethod:@"GET" withPath:path block:block.
 */
- (void)get:(NSString *)path withBlock:(void (^)(RouteRequest *request, RouteResponse *response))block;

/**
 Convenience for -handleMethod:@"DELETE" withPath:path block:block.
 */
- (void)delete:(NSString *)path withBlock:(void (^)(RouteRequest *request, RouteResponse *response))block;

/**
 Starts listening on `port`.
 */
- (BOOL)start:(NSError **)error;

/**
 Stops listening and disconnects all clients.
 */
- (void)stop:(BOOL)immediately;

@end

NS_ASSUME_NONNULL_END
