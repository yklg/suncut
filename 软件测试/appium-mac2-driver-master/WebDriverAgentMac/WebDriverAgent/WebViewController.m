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

#import "WebViewController.h"

#import <WebKit/WebKit.h>

/*
 None of these elements set a native accessibility identifier, so WebKit leaves their
 standard AXIdentifier empty and only exposes their DOM `id` through AXDOMIdentifier -
 this mirrors real-world web content and is what useDomIdAsAccessibilityId is meant to
 fall back onto.
 */
static NSString *const AMWebViewHTML =
@"<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>"
@"<div id=\"am-web-container\" role=\"group\">"
@"<button id=\"am-dom-button\">Web Button</button>"
@"<span id=\"am-dom-text\">Web Text</span>"
@"</div>"
@"</body></html>";

@implementation WebViewController

- (void)loadView
{
  self.view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 450, 300)];
}

- (void)viewDidLoad
{
  [super viewDidLoad];

  [(WKWebView *)self.view loadHTMLString:AMWebViewHTML baseURL:nil];
}

@end
