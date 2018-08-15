#import "MSOneCollectorIngestion.h"
#import "MSAbstractLogInternal.h"
#import "MSAppCenterErrors.h"
#import "MSAppCenterInternal.h"
#import "MSCommonSchemaLog.h"
#import "MSCompression.h"
#import "MSConstants+Internal.h"
#import "MSHttpIngestionPrivate.h"
#import "MSLog.h"
#import "MSLogContainer.h"
#import "MSLoggerInternal.h"
#import "MSTicketCache.h"
#import "MSUtility+Date.h"

NSString *const kMSOneCollectorApiKey = @"apikey";
NSString *const kMSOneCollectorApiPath = @"/OneCollector";
NSString *const kMSOneCollectorApiVersion = @"1.0";
NSString *const kMSOneCollectorClientVersionKey = @"Client-Version";
NSString *const kMSOneCollectorContentType =
    @"application/x-json-stream; charset=utf-8";
NSString *const kMSOneCollectorLogSeparator = @"\n";
NSString *const kMSOneCollectorTicketsKey = @"Tickets";
NSString *const kMSOneCollectorUploadTimeKey = @"Upload-Time";

@implementation MSOneCollectorIngestion

- (id)initWithBaseUrl:(NSString *)baseUrl {
  self = [super
             initWithBaseUrl:baseUrl
                     apiPath:[NSString
                                 stringWithFormat:@"%@/%@",
                                                  kMSOneCollectorApiPath,
                                                  kMSOneCollectorApiVersion]
                     headers:@{
                       kMSHeaderContentTypeKey : kMSOneCollectorContentType,
                       kMSOneCollectorClientVersionKey : [NSString
                           stringWithFormat:kMSOneCollectorClientVersionFormat,
                                            [MSUtility sdkVersion]]
                     }
                queryStrings:nil
                reachability:[MS_Reachability reachabilityForInternetConnection]
              retryIntervals:@[ @(10), @(5 * 60), @(20 * 60) ]
      maxNumberOfConnections:2];
  return self;
}

- (void)sendAsync:(NSObject *)data
            appSecret:(NSString *)appSecret
    completionHandler:(MSSendAsyncCompletionHandler)handler {
  MSLogContainer *container = (MSLogContainer *)data;
  NSString *batchId = container.batchId;

  /*
   * FIXME: All logs are already validated at the time the logs are enqueued to
   * Channel. It is not necessary but it can still protect against invalid logs
   * being sent to server that are messed up somehow in Storage. If we see
   * performance issues due to this validation, we will remove `[container
   * isValid]` call below.
   */

  // Verify container.
  if (!container || ![container isValid]) {
    NSDictionary *userInfo =
        @{NSLocalizedDescriptionKey : kMSACLogInvalidContainerErrorDesc};
    NSError *error = [NSError errorWithDomain:kMSACErrorDomain
                                         code:kMSACLogInvalidContainerErrorCode
                                     userInfo:userInfo];
    MSLogError([MSAppCenter logTag], @"%@", [error localizedDescription]);
    handler(batchId, 0, nil, error);
    return;
  }
  [super sendAsync:container
              appSecret:appSecret
                 callId:container.batchId
      completionHandler:handler];
}

- (NSURLRequest *)createRequest:(NSObject *)data
                      appSecret:(NSString *)__unused appSecret {
  MSLogContainer *container = (MSLogContainer *)data;
  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:self.sendURL];

  // Set method.
  request.HTTPMethod = @"POST";

  // Set Header params.
  NSMutableDictionary *headers = [self.httpHeaders mutableCopy];
  NSMutableSet<NSString *> *apiKeys = [NSMutableSet new];
  for (id<MSLog> log in container.logs) {
    [apiKeys addObjectsFromArray:[log.transmissionTargetTokens allObjects]];
  }
  [headers setObject:[[apiKeys allObjects] componentsJoinedByString:@","]
              forKey:kMSOneCollectorApiKey];
  [headers
      setObject:[NSString
                    stringWithFormat:@"%lld",
                                     (long long)[MSUtility nowInMilliseconds]]
         forKey:kMSOneCollectorUploadTimeKey];

  // Gather tokens from logs.
  NSMutableString *ticketKeyString = [NSMutableString new];
  for (id<MSLog> log in container.logs) {
    MSCommonSchemaLog *csLog = (MSCommonSchemaLog *)log;
    if (csLog.ext.protocolExt) {
      NSArray<NSString *> *ticketKeys = [[[csLog ext] protocolExt] ticketKeys];
      for (NSString *ticketKey in ticketKeys) {
        NSString *authenticationToken = [[MSTicketCache sharedInstance] ticketFor:ticketKey];
        if (authenticationToken) {

          /*
           * Format to look like this:
           * "ticketKey1"="d:token1";"ticketKey2"="d:token2" or
           * "ticketKey1"="p:token1";"ticketKey2"="p:token2". The value (p: vs.
           * d:) is determined by MSAnalyticsAuthenticationProvider before
           * saving the token to the TicketCache.
           */
          NSString *ticketKeyAndToken =
              [NSString stringWithFormat:@"\"%@\"=\"%@\";", ticketKey, authenticationToken];
          [ticketKeyString appendString:ticketKeyAndToken];
        }
      }
    }
  }

  // Delete last ";" if applicable and set header.
  if (ticketKeyString && (ticketKeyString.length > 0)) {
    [ticketKeyString
        deleteCharactersInRange:NSMakeRange([ticketKeyString length] - 1, 1)];
    [headers setObject:ticketKeyString forKey:kMSOneCollectorTicketsKey];
  }
  request.allHTTPHeaderFields = headers;

  // Set body.
  NSMutableString *jsonString = [NSMutableString new];
  for (id<MSLog> log in container.logs) {
    MSAbstractLog *abstractLog = (MSAbstractLog *)log;
    [jsonString appendString:[abstractLog serializeLogWithPrettyPrinting:NO]];

    // Separator for one collector logs.
    [jsonString appendString:kMSOneCollectorLogSeparator];
  }
  NSData *httpBody = [jsonString dataUsingEncoding:NSUTF8StringEncoding];

  // Zip HTTP body if length worth it.
  if (httpBody.length >= kMSHTTPMinGZipLength) {
    NSData *compressedHttpBody = [MSCompression compressData:httpBody];
    if (compressedHttpBody) {
      [request setValue:kMSHeaderContentEncoding
          forHTTPHeaderField:kMSHeaderContentEncodingKey];
      httpBody = compressedHttpBody;
    }
  }
  request.HTTPBody = httpBody;

  // Always disable cookies.
  [request setHTTPShouldHandleCookies:NO];

  // Don't loose time pretty printing headers if not going to be printed.
  if ([MSLogger currentLogLevel] <= MSLogLevelVerbose) {
    MSLogVerbose([MSAppCenter logTag], @"URL: %@", request.URL);
    MSLogVerbose([MSAppCenter logTag], @"Headers: %@",
                 [super prettyPrintHeaders:request.allHTTPHeaderFields]);
  }
  return request;
}

- (NSString *)obfuscateHeaderValue:(NSString *)key value:(NSString *)value {
  if ([key isEqualToString:kMSOneCollectorApiKey]) {
    return [self obfuscateTargetTokens:value];
  } else if ([key isEqualToString:kMSOneCollectorTicketsKey]) {
    return [self obfuscateTickets:value];
  }
  return value;
}

- (NSString *)obfuscateTargetTokens:(NSString *)tokenString {
  NSArray *tokens = [tokenString componentsSeparatedByString:@","];
  NSMutableArray *obfuscatedTokens = [NSMutableArray new];
  for (NSString *token in tokens) {
    [obfuscatedTokens addObject:[MSIngestionUtil hideSecret:token]];
  }
  return [obfuscatedTokens componentsJoinedByString:@","];
}

- (NSString *)obfuscateTickets:(NSString *)tokenString {
  NSArray *tickets = [tokenString componentsSeparatedByString:@";"];
  NSMutableArray *obfuscatedTickets = [NSMutableArray new];
  for (NSString *ticket in tickets) {
    NSString *obfuscatedTicket;
    NSRange separator = [ticket rangeOfString:@"\"=\""];
    if (separator.location != NSNotFound) {
      NSRange tokenRange = NSMakeRange(NSMaxRange(separator), ticket.length - NSMaxRange(separator) - 1);
      NSString *token = [ticket substringWithRange:tokenRange];
      token = [MSIngestionUtil hideSecret:token];
      obfuscatedTicket = [ticket stringByReplacingCharactersInRange:tokenRange withString:token];
    } else {
      obfuscatedTicket = [MSIngestionUtil hideSecret:ticket];
    }
    [obfuscatedTickets addObject:obfuscatedTicket];
  }
  return [obfuscatedTickets componentsJoinedByString:@";"];
}

@end