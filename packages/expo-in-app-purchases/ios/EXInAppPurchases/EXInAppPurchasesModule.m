// Copyright 2018-present 650 Industries. All rights reserved.

#import <EXInAppPurchases/EXInAppPurchasesModule.h>

@interface EXInAppPurchasesModule ()

@property (weak, nonatomic) UMModuleRegistry *moduleRegistry;
@property (nonatomic, assign) BOOL queryingItems;
@property (nonatomic, weak) id <UMEventEmitterService> eventEmitter;
@property (strong, nonatomic) NSMutableDictionary *promises;
@property (strong, nonatomic) NSMutableDictionary *pendingTransactions;
@property (strong, nonatomic) NSMutableSet *retrievedItems;
@property (strong, nonatomic) SKProductsRequest *request;
@property (strong, nonatomic) NSArray<SKProduct*> *products;

@end

static NSString * const EXPurchasesUpdatedEventName = @"Expo.purchasesUpdated";
static NSString * const QUERY_HISTORY_KEY = @"QUERY_HISTORY";
static NSString * const QUERY_PURCHASABLE_KEY = @"QUERY_PURCHASABLE";
static NSString * const IN_APP = @"inapp";
static NSString * const SUBS = @"subs";
static NSString * const P0D = @"P0D";

static const int OK = 0;
static const int USER_CANCELED = 1;
static const int ERROR = 2;
static const int DEFERRED = 3;

@implementation EXInAppPurchasesModule

UM_EXPORT_MODULE(ExpoInAppPurchases);

- (void)setModuleRegistry:(UMModuleRegistry *)moduleRegistry
{
  _moduleRegistry = moduleRegistry;
  _eventEmitter = [moduleRegistry getModuleImplementingProtocol:@protocol(UMEventEmitterService)];
}

- (NSArray<NSString *> *)supportedEvents
{
  return @[EXPurchasesUpdatedEventName];
}

- (void)startObserving {}
- (void)stopObserving {}

UM_EXPORT_METHOD_AS(connectAsync,
                    connectAsync:(UMPromiseResolveBlock)resolve
                    reject:(UMPromiseRejectBlock)reject)
{
  // Initialize listener and object properties
  [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
  _promises = [NSMutableDictionary dictionary];
  _pendingTransactions = [NSMutableDictionary dictionary];
  _retrievedItems = [NSMutableSet set];
  _queryingItems = NO;
  BOOL promiseSet = [self setPromise:QUERY_HISTORY_KEY resolve:resolve reject:reject];

  if (promiseSet) {
    // Request history
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
  }
}

UM_EXPORT_METHOD_AS(getProductsAsync,
                    getProductsAsync:(NSArray *)productIDs
                    resolve:(UMPromiseResolveBlock)resolve
                    reject:(UMPromiseRejectBlock)reject)
{
  [self setPromise:QUERY_PURCHASABLE_KEY resolve:resolve reject:reject];

  for (NSString *identifier in productIDs) {
    [_retrievedItems addObject:identifier];
  }
  _queryingItems = YES;
  [self requestProducts:productIDs];
}

UM_EXPORT_METHOD_AS(purchaseItemAsync,
                    purchaseItemAsync:(NSString *)productIdentifier
                    resolve:(UMPromiseResolveBlock)resolve
                    reject:(UMPromiseRejectBlock)reject)
{
  if (![SKPaymentQueue canMakePayments]) {
    reject(@"E_MISSING_PERMISSIONS", @"User cannot make payments", nil);
    return;
  }
  if (![_retrievedItems containsObject:productIdentifier]) {
    reject(@"E_ITEM_NOT_QUERIED", @"Must query item from store before calling purchase", nil);
    return;
  }

  // Make the request
  BOOL promiseSet = [self setPromise:productIdentifier resolve:resolve reject:reject];
  if (promiseSet) {
    NSArray *productArray = @[productIdentifier];
    _queryingItems = NO;
    [self requestProducts:productArray];
  }
}

UM_EXPORT_METHOD_AS(finishTransactionAsync,
                    finishTransactionAsync:(NSString *)purchaseToken
                    consume:(BOOL)consume // ignore
                    resolve:(UMPromiseResolveBlock)resolve
                    reject:(UMPromiseRejectBlock)reject)
{
  SKPaymentTransaction *transaction = _pendingTransactions[purchaseToken];
  _pendingTransactions[purchaseToken] = nil;
  if (transaction != nil) {
    [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
  }
  resolve(nil);
}

UM_EXPORT_METHOD_AS(getPurchaseHistoryAsync,
                    getPurchaseHistoryAsync:(BOOL)refresh // ignore
                    resolve:(UMPromiseResolveBlock)resolve
                    reject:(UMPromiseRejectBlock)reject)
{
  BOOL promiseSet = [self setPromise:QUERY_HISTORY_KEY resolve:resolve reject:reject];

  if(promiseSet) {
    // Request history
    [[SKPaymentQueue defaultQueue] restoreCompletedTransactions];
  }
}

UM_EXPORT_METHOD_AS(disconnectAsync,
                    disconnectAsync:(UMPromiseResolveBlock)resolve
                    reject:(UMPromiseRejectBlock)reject)
{
  [[SKPaymentQueue defaultQueue] removeTransactionObserver:self];
  resolve(nil);
}

- (void)requestProducts:(NSArray *)productIdentifiers
{
  SKProductsRequest *productsRequest = [[SKProductsRequest alloc]
                                        initWithProductIdentifiers:[NSSet setWithArray:productIdentifiers]];
  // Keep a strong reference to the request.
  self.request = productsRequest;
  productsRequest.delegate = self;

  [productsRequest start];
}

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response
{

  for (NSString *invalidIdentifier in response.invalidProductIdentifiers) {
    if (!_queryingItems) {
      NSDictionary *results = [self formatResults:SKErrorStoreProductNotAvailable];
      [self resolvePromise:invalidIdentifier value:results];
    }
  }
  _products = response.products;
  NSMutableArray *result = [NSMutableArray array];

  for (SKProduct *validProduct in response.products) {
    if (_queryingItems) {
      // Retrieving product info
      NSDictionary *productData = [self getProductData:validProduct];
      [result addObject:productData];
    } else {
      // Making a purchase
      [self purchase:validProduct];
    }
  }

  _queryingItems = NO;
  NSDictionary *res = [self formatResults:result withResponseCode:OK];
  [self resolvePromise:QUERY_PURCHASABLE_KEY value:res];
}

// Returns a boolean indicating the promise was successfully set. Otherwise, we should return immediately
- (BOOL)setPromise:(NSString*)key resolve:(UMPromiseResolveBlock)resolve reject:(UMPromiseRejectBlock)reject
{
  NSArray *promise = _promises[key];

  if (promise == nil) {
    _promises[key] = @[resolve, reject];
    return YES;
  } else {
    reject(@"E_UNFINISHED_PROMISE", @"Must wait for promise to resolve before recalling function.", nil);
    return NO;
  }
}

- (void)resolvePromise:(NSString*)key value:(id)value
{
  NSArray *currentPromise = _promises[key];

  if (currentPromise != nil) {
    UMPromiseResolveBlock resolve = currentPromise[0];
    _promises[key] = nil;

    resolve(value);
  }
}

- (void)rejectPromise:(NSString*)key code:(NSString*)code message:(NSString*)message error:(NSError*) error
{
  NSArray* currentPromise = _promises[key];

  if (currentPromise != nil) {
    UMPromiseRejectBlock reject = currentPromise[1];
    _promises[key] = nil;

    reject(code, message, error);
  }
}

- (void)purchase:(SKProduct *)product
{
  SKPayment *payment = [SKPayment paymentWithProduct:product];
  [[SKPaymentQueue defaultQueue] addPayment:payment];
}

- (void)paymentQueueRestoreCompletedTransactionsFinished:(SKPaymentQueue *)queue
{
  NSMutableArray *results = [NSMutableArray array];

  for (SKPaymentTransaction *transaction in queue.transactions) {
    SKPaymentTransactionState transactionState = transaction.transactionState;
    if (transactionState == SKPaymentTransactionStateRestored || transactionState == SKPaymentTransactionStatePurchased) {
      NSDictionary * transactionData = [self getTransactionData:transaction];
      [results addObject:transactionData];

      [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
    }
  }

  NSDictionary *response = [self formatResults:results withResponseCode:OK];
  [self resolvePromise:QUERY_HISTORY_KEY value:response];
}

- (void)paymentQueue:(SKPaymentQueue *)queue restoreCompletedTransactionsFailedWithError:(NSError *)error {
  int errorCode = [self errorCodeNativeToJS:error.code];
  NSDictionary *response = [self formatResults:errorCode];
  [self resolvePromise:QUERY_HISTORY_KEY value:response];
}

- (NSDictionary *)getProductData:(SKProduct *)product
{
  // Use with caution: P0D also implies non-renewable subscription.
  NSString *subscriptionPeriod = [self getSubscriptionPeriod:product];
  NSString *type = [subscriptionPeriod isEqualToString:P0D] ? IN_APP : SUBS;

  NSDecimalNumber *oneMillion = [[NSDecimalNumber alloc] initWithInt:1000000];
  NSDecimalNumber *priceAmountMicros = [product.price decimalNumberByMultiplyingBy:oneMillion];
  NSString *price = [NSString stringWithFormat:@"%@%@", product.priceLocale.currencySymbol, product.price];

  return @{
          @"description": product.localizedDescription,
          @"price": price,
          @"priceAmountMicros": priceAmountMicros,
          @"priceCurrencyCode": product.priceLocale.currencyCode,
          @"productId": product.productIdentifier,
          @"subscriptionPeriod": subscriptionPeriod,
          @"title": product.localizedTitle,
          @"type": type
          };
}

- (NSDictionary *)getTransactionData:(SKPaymentTransaction *)transaction
{
  NSData *receiptData = [NSData dataWithContentsOfURL:[[NSBundle mainBundle] appStoreReceiptURL]];
  return @{
          @"acknowledged": @NO,
          @"productId": transaction.payment.productIdentifier,
          @"purchaseToken": transaction.transactionIdentifier,
          @"purchaseState": @(transaction.transactionState),
          @"purchaseTime": @(transaction.transactionDate.timeIntervalSince1970 * 1000),
          @"transactionReceipt": [receiptData base64EncodedStringWithOptions:0]
          };
}

- (NSString *)getSubscriptionPeriod:(SKProduct *)product
{
  // Subscription period specified in ISO 8601 format to match Android implementation (e.g. P3M = 3 months)
  if (@available(iOS 11.2, *)) {
    NSString *unit = [self getUnit:product];
    unsigned long numUnits = (unsigned long)product.subscriptionPeriod.numberOfUnits;
    return [NSString stringWithFormat:@"P%lu%@", numUnits, unit];
  }

  // Default to P0D if we can't get this info so we assume all products are in app
  return P0D;
}

- (NSString *)getUnit:(SKProduct *)product
{
  if (@available(iOS 11.2, *)) {
    switch(product.subscriptionPeriod.unit) {
      case SKProductPeriodUnitDay: {
        return @"D";
      }
      case SKProductPeriodUnitWeek: {
        return @"W";
      }
      case SKProductPeriodUnitMonth: {
        return @"M";
      }
      case SKProductPeriodUnitYear: {
        return @"Y";
      }
    }
  }
  return [NSString string];
}

/*
 This method handles transactions from the transaction queue which may or may not be initiated by the user.
 Transactions must be removed from the queue after they are processed by calling finishTransaction.
 */
- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions
{
  for (SKPaymentTransaction *transaction in transactions) {
    switch(transaction.transactionState) {
      case SKPaymentTransactionStatePurchasing: {
        break;
      }
      case SKPaymentTransactionStatePurchased: {
        // Save transaction to be finished later
        _pendingTransactions[transaction.transactionIdentifier] = transaction;

        // Emit results
        NSArray *results = @[[self getTransactionData:transaction]];
        NSDictionary *response = [self formatResults:results withResponseCode:OK];
        [_eventEmitter sendEventWithName:EXPurchasesUpdatedEventName body:response];

        // Resolve promise
        [self resolvePromise:transaction.payment.productIdentifier value:nil];
        break;
      }
      case SKPaymentTransactionStateRestored: {
        // Finish transaction right away since the developer has a record of this transaction via purchase history
        [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
        break;
      }
      case SKPaymentTransactionStateDeferred: {
        // Emit results with deferred response code
        NSArray *results = @[[self getTransactionData:transaction]];
        NSDictionary *response = [self formatResults:results withResponseCode:DEFERRED];
        [_eventEmitter sendEventWithName:EXPurchasesUpdatedEventName body:response];

        // Resolve promise
        [self resolvePromise:transaction.payment.productIdentifier value:nil];
        break;
      }
      case SKPaymentTransactionStateFailed: {
        // Emit results
        if(transaction.error.code == SKErrorPaymentCancelled){
          NSDictionary *response = [self formatResults:[NSArray array] withResponseCode:USER_CANCELED];
          [_eventEmitter sendEventWithName:EXPurchasesUpdatedEventName body:response];
        } else {
          NSDictionary *response = [self formatResults:transaction.error.code];
          [_eventEmitter sendEventWithName:EXPurchasesUpdatedEventName body:response];
        }

        // Finish transaction and resolve promise
        [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
        [self resolvePromise:transaction.payment.productIdentifier value:nil];
        break;
      }
    }
  }
}

- (NSDictionary *)formatResults:(NSArray *)results withResponseCode:(NSInteger)responseCode
{
  return @{
           @"results": results,
           @"responseCode": @(responseCode),
           };
}

- (NSDictionary *)formatResults:(SKErrorCode)errorCode
{
  int convertedErrorCode = [self errorCodeNativeToJS:errorCode];
  return @{
           @"results": [NSArray array],
           @"responseCode": @(ERROR),
           @"errorCode": @(convertedErrorCode),
           };
}

// Convert native error code to match TS enum
- (int)errorCodeNativeToJS:(SKErrorCode)errorCode
{
  switch(errorCode) {
    case SKErrorUnknown:
      return 0;
    case SKErrorClientInvalid:
    case SKErrorPaymentInvalid:
    case SKErrorPaymentNotAllowed:
    case SKErrorPaymentCancelled:
      return 1;
    case SKErrorStoreProductNotAvailable:
      return 6;
    case SKErrorCloudServiceRevoked:
    case SKErrorCloudServicePermissionDenied:
    case SKErrorCloudServiceNetworkConnectionFailed:
      return 10;
    case SKErrorPrivacyAcknowledgementRequired:
      return 11;
    case SKErrorUnauthorizedRequestData:
      return 12;
    case SKErrorInvalidSignature:
    case SKErrorInvalidOfferPrice:
    case SKErrorInvalidOfferIdentifier:
      return 13;
    case SKErrorMissingOfferParams:
      return 14;
  }
}

@end
