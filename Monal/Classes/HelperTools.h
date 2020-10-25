//
//  HelperTools.h
//  Monal
//
//  Created by Friedrich Altheide on 08.07.20.
//  Copyright © 2020 Monal.im. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MLConstants.h"

NS_ASSUME_NONNULL_BEGIN

void logException(NSException* exception);

@interface HelperTools : NSObject

+(NSString*) staticHandlerToId:(NSDictionary*) handler;
+(NSString*) staticHandlerToString:(NSDictionary*) handler;
+(NSDictionary*) createStaticHandlerWithDelegate:(id) delegate andMethod:(SEL) method andAdditionalArguments:(NSArray* _Nullable) args;
+(void) callStaticHandler:(NSDictionary*) handler withDefaultArguments:(NSArray* _Nullable) defaultArgs;
+(void) configureFileProtectionFor:(NSString*) file;
+(NSDictionary*) splitJid:(NSString*) jid;
+(void) postSendingErrorNotification;
+(BOOL) isInBackground;
+(void) dispatchSyncReentrant:(monal_void_block_t) block onQueue:(dispatch_queue_t) queue;
+(void) activityLog;
+(NSUserDefaults*) defaultsDB;
+(DDFileLogger*) configureLogging;
+(BOOL) isAppExtension;
+(NSString*) generateStringOfFeatureSet:(NSSet*) features;
+(NSSet*) getOwnFeatureSet;
+(NSString*) getEntityCapsHashForIdentities:(NSArray*) identities andFeatures:(NSSet*) features;
+(NSString* _Nullable) formatLastInteraction:(NSDate*) lastInteraction;
+(NSDate*) parseDateTimeString:(NSString*) datetime;
+(NSString*) generateDateTimeString:(NSDate*) datetime;
+(monal_void_block_t) startTimer:(double) timeout withHandler:(monal_void_block_t) handler;
+(monal_void_block_t) startTimer:(double) timeout withHandler:(monal_void_block_t) handler andCancelHandler:(monal_void_block_t _Nullable) cancelHandler;
+(NSString*) encodeRandomResource;
+(NSData* _Nullable) sha1:(NSData* _Nullable) data;
+(NSData* _Nullable) sha256:(NSData* _Nullable) data;
+(NSData* _Nullable) sha256HmacForKey:(NSString* _Nullable) key andData:(NSString* _Nullable) data;
+(NSString*) encodeBase64WithString:(NSString*) strData;
+(NSString*) encodeBase64WithData:(NSData*) objData;
+(NSData*) dataWithBase64EncodedString:(NSString*) string;

+ (NSString *)hexadecimalString:(NSData*) data;
+ (NSData *)dataWithHexString:(NSString *)hex;
+ (NSString *)signalHexKeyWithData:(NSData*) data;

+(UIView*) MLCustomViewHeaderWithTitle:(NSString*) title;

@end

NS_ASSUME_NONNULL_END
