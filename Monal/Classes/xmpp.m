//
//  xmpp.m
//  Monal
//
//  Created by Anurodh Pokharel on 6/29/13.
//
//

#import <CommonCrypto/CommonCrypto.h>
#import <CFNetwork/CFSocketStream.h>
#import "xmpp.h"
#import "DataLayer.h"
#import "EncodingTools.h"
#import "MLXMPPManager.h"

#import "MLSignalStore.h"


#if TARGET_OS_IPHONE
#import "UIAlertView+Blocks.h"
#endif

#import "SAMKeychain.h"


#import "MLImageManager.h"

//objects
#import "XMPPIQ.h"
#import "XMPPPresence.h"
#import "XMPPMessage.h"

//parsers
#import "ParseStream.h"
#import "ParseIq.h"
#import "ParsePresence.h"
#import "ParseMessage.h"
#import "ParseChallenge.h"
#import "ParseFailure.h"
#import "ParseEnabled.h"
#import "ParseA.h"
#import "ParseResumed.h"
#import "ParseFailed.h"

#import "NXOAuth2.h"
#import "MLHTTPRequest.h"

#ifndef DISABLE_OMEMO
#import "SignalProtocolObjC.h"
#endif

#include <openssl/evp.h>
#include <openssl/rand.h>


#define kXMPPReadSize 5120 // bytes

#define kConnectTimeout 20ull //seconds
#define kPingTimeout 120ull //seconds


NSString *const kId=@"id";
NSString *const kMessageId=@"MessageID";
NSString *const kSendTimer=@"SendTimer";

NSString *const kStanzaID=@"stanzaID";
NSString *const kStanza=@"stanza";


NSString *const kFileName=@"fileName";
NSString *const kContentType=@"contentType";
NSString *const kData=@"data";
NSString *const kContact=@"contact";

NSString *const kCompletion=@"completion";


NSString *const kXMPPError =@"error";
NSString *const kXMPPSuccess =@"success";
NSString *const kXMPPPresence = @"presence";


static const int ddLogLevel = LOG_LEVEL_VERBOSE;

@interface xmpp()
{
    BOOL _loginStarted;
    BOOL _reconnectScheduled;
}

@property (nonatomic ,strong) NSDate *loginStartTimeStamp;

@property (nonatomic, strong) NSString *pingID;
@property (nonatomic, strong) NSOperationQueue *networkQueue;
@property (nonatomic, strong) NSOperationQueue *processQueue;

@property (nonatomic, assign) BOOL supportsPush;
@property (nonatomic, assign) BOOL supportsRosterVersion;


//HTTP upload
@property (nonatomic, assign) BOOL supportsHTTPUpload;
@property (nonatomic, strong) NSMutableArray *httpUploadQueue;

//ping
@property (nonatomic, assign) BOOL supportsPing;

//stream resumption
@property (nonatomic, assign) BOOL supportsSM3;
@property (nonatomic, assign) BOOL resuming;
@property (nonatomic, strong) NSString *streamID;
@property (nonatomic, strong) NSNumber *streamExpireSeconds;

@property (nonatomic, assign) BOOL hasDiscoAndRoster;

// client state
@property (nonatomic, assign) BOOL supportsClientState;

//message archive
@property (nonatomic, assign) BOOL supportsMam2;

//carbons
@property (nonatomic, assign) BOOL usingCarbons2;
@property (nonatomic, assign) BOOL pushEnabled;

//server details
@property (nonatomic, strong) NSSet *serverFeatures;

/**
 h to go out in r stanza
 */
@property (nonatomic, strong) NSNumber *lastHandledInboundStanza;

/**
 h from a stanza
 */
@property (nonatomic, strong) NSNumber *lastHandledOutboundStanza;

/**
 internal counter that should match lastHandledOutboundStanza
 */
@property (nonatomic, strong) NSNumber *lastOutboundStanza;

/**
 Array of NSdic with stanzas that have not been acked.
 NSDic {stanzaID, stanza}
 */
@property (nonatomic, strong) NSMutableArray *unAckedStanzas;

@property (nonatomic, strong) NXOAuth2Account *oauthAccount;

#ifndef DISABLE_OMEMO
@property (nonatomic, strong) SignalContext *signalContext;
@property (nonatomic, strong) MLSignalStore *monalSignalStore;
#endif


@end



@implementation xmpp

-(id) init
{
    self=[super init];
    _accountState = kStateLoggedOut;
    
    _discoveredServerList=[[NSMutableArray alloc] init];
    _inputBuffer=[[NSMutableString alloc] init];
    _outputQueue=[[NSMutableArray alloc] init];
    _port=5552;
    _SSL=YES;
    _oldStyleSSL=NO;
   
    
    self.networkQueue =[[NSOperationQueue alloc] init];
    self.networkQueue.maxConcurrentOperationCount=1;
    
    self.processQueue =[[NSOperationQueue alloc] init];
    
    //placing more common at top to reduce iteration
    _stanzaTypes=[NSArray arrayWithObjects:
                  @"a", // one of the most frequent
                  @"iq",
                  @"message",
                  @"presence",
                  @"stream:stream",
                  @"stream:error",
                  @"stream",
                  @"csi",
                  @"features",
                  @"proceed",
                  @"failure",
                  @"challenge",
                  @"response",
                  @"success",
                  @"enabled",
                  @"resumed", // should be before r since that will match many things
                  @"failed",
                  @"r",
                  nil];
    
    
    _versionHash=[self getVersionString];

    
    self.priority=[[[NSUserDefaults standardUserDefaults] stringForKey:@"XMPPPriority"] integerValue];
    self.statusMessage=[[NSUserDefaults standardUserDefaults] stringForKey:@"StatusMessage"];
    self.awayState=[[NSUserDefaults standardUserDefaults] boolForKey:@"Away"];
    
    if([[NSUserDefaults standardUserDefaults] objectForKey:@"Visible"]){
        self.visibleState=[[NSUserDefaults standardUserDefaults] boolForKey:@"Visible"];
    }
    else  {
        self.visibleState=YES;
    }
    

    return self;
}

-(void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

-(void) setRunLoop
{
    [_oStream setDelegate:self];
    [_oStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    
    [_iStream setDelegate:self];
    [_iStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
}

-(void) createStreams
{
    
    DDLogInfo(@"stream  creating to  server: %@ port: %d", _server, (UInt32)_port);
    
    NSInputStream *localIStream;
    NSOutputStream *localOStream;
    
    [NSStream getStreamsToHostWithName:self.server port:self.port inputStream:&localIStream outputStream:&localOStream];
    if(localIStream) {
        _iStream=localIStream;
    }
    
    if(localOStream) {
        _oStream = localOStream;
    }
    
    
    if((_iStream==nil) || (_oStream==nil))
    {
        DDLogError(@"Connection failed");
        [[NSNotificationCenter defaultCenter] postNotificationName:kXMPPError object:@[self, @"Unable to connect to server"]];
        
        return;
    }
    else {
        DDLogInfo(@"streams created ok");
    }
    
    
    if((_SSL==YES)  && (_oldStyleSSL==YES))
    {
        // do ssl stuff here
        DDLogInfo(@"securing connection.. for old style");
        
        NSMutableDictionary *settings = [ [NSMutableDictionary alloc ]
                                         initWithObjectsAndKeys:
                                         kCFStreamSocketSecurityLevelNegotiatedSSL,
                                         kCFStreamSSLLevel,
                                         nil ];
        
        
        if(self.selfSigned)
        {
            NSDictionary* secureOFF= [ [NSDictionary alloc ]
                                      initWithObjectsAndKeys:
                                      [NSNumber numberWithBool:NO], kCFStreamSSLValidatesCertificateChain, nil];
            
            [settings addEntriesFromDictionary:secureOFF];
            
            
            
        }
        
        
        CFReadStreamSetProperty((__bridge CFReadStreamRef)_iStream,
                                kCFStreamPropertySSLSettings, (__bridge CFTypeRef)settings);
        CFWriteStreamSetProperty((__bridge CFWriteStreamRef)_oStream,
                                 kCFStreamPropertySSLSettings, (__bridge CFTypeRef)settings);
        
        DDLogInfo(@"connection secured");
    }
    
    MLXMLNode* xmlOpening = [[MLXMLNode alloc] initWithElement:@"xml"];
    [self send:xmlOpening];
    [self startStream];
    [self setRunLoop];
    
    
    
    dispatch_queue_t q_background = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_source_t streamTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,q_background
                                                           );
    
    dispatch_source_set_timer(streamTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 5ull * NSEC_PER_SEC),
                              DISPATCH_TIME_FOREVER
                              , 1ull * NSEC_PER_SEC);
    
    dispatch_source_set_event_handler(streamTimer, ^{
        DDLogError(@"stream connection timed out");
        dispatch_source_cancel(streamTimer);
        
        [self disconnect];
    });
    
    dispatch_source_set_cancel_handler(streamTimer, ^{
        DDLogError(@"stream timer cancelled");
    });
    
    dispatch_resume(streamTimer);
    
    [_iStream open];
    [_oStream open];
    
    dispatch_source_cancel(streamTimer);
    
}

-(void) connectionTask
{
    
    if([_domain length]>0) {
        _fulluser=[NSString stringWithFormat:@"%@@%@", _username, _domain];
    }
    else {
        _fulluser=_username;
    }
    
    if(self.oAuth) {
        
        [[NXOAuth2AccountStore sharedStore] setClientID:@"472865344000-q63msgarcfs3ggiabdobkkis31ehtbug.apps.googleusercontent.com"
                                                 secret:@"IGo7ocGYBYXf4znad5Qhumjt"
                                                  scope:[NSSet setWithArray:@[@"https://www.googleapis.com/auth/googletalk"]]
                                       authorizationURL:[NSURL URLWithString:@"https://accounts.google.com/o/oauth2/auth"]
                                               tokenURL:[NSURL URLWithString:@"https://www.googleapis.com/oauth2/v3/token"]
                                            redirectURL:[NSURL URLWithString:@"urn:ietf:wg:oauth:2.0:oob:auto"]
                                          keyChainGroup:@"MonalGTalk"
                                         forAccountType:_fulluser];
        
        
        [[NSNotificationCenter defaultCenter] addObserverForName:NXOAuth2AccountStoreDidFailToRequestAccessNotification
                                                          object:[NXOAuth2AccountStore sharedStore]
                                                           queue:nil
                                                      usingBlock:^(NSNotification *aNotification){
                                                          //                                                          NSError *error = [aNotification.userInfo objectForKey:NXOAuth2AccountStoreErrorKey];
                                                          // Do something with the error
                                                      }];
        
        NSArray *accounts= [[NXOAuth2AccountStore sharedStore] accountsWithAccountType:_fulluser];
        
        if([accounts count]>0)
        {
            self.oauthAccount= [accounts objectAtIndex:0];
        }
        
        [[NSNotificationCenter defaultCenter] addObserverForName:NXOAuth2AccountDidChangeAccessTokenNotification
                                                          object:self.oauthAccount queue:nil usingBlock:^(NSNotification *note) {
                                                              
                                                              
                                                              self.password= self.oauthAccount.accessToken.accessToken;
                                                              
                                                              [self reconnect];
                                                              
                                                              
                                                          }];
    }
    
    if(_oldStyleSSL==NO) {
        // do DNS discovery if it hasn't already been set
        if([_discoveredServerList count]==0) {
           _discoveredServerList= [[[MLDNSLookup alloc] init] dnsDiscoverOnDomain:_domain];
        }
    }
    
    if([_discoveredServerList count]>0) {
        _server=[[_discoveredServerList objectAtIndex:0] objectForKey:@"server"];
        _port=[[[_discoveredServerList objectAtIndex:0] objectForKey:@"port"] integerValue];
    }
    
    [self createStreams];
}


-(void) connect
{
    if(self.explicitLogout) return;
    if(self.accountState>=kStateLoggedIn )
    {
        DDLogError(@"assymetrical call to login without a teardown logout");
        return;
    }
    _loginStarted=YES;
    self.loginStartTimeStamp=[NSDate date];
    self.pingID=nil;
    
    DDLogInfo(@"XMPP connnect  start");
    _outputQueue=[[NSMutableArray alloc] init];
    
    //read persistent state
    [self readState];
    
    [self connectionTask];
    
    dispatch_queue_t q_background = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_source_t loginCancelOperation = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                                    q_background);
    
    dispatch_source_set_timer(loginCancelOperation,
                              dispatch_time(DISPATCH_TIME_NOW, kConnectTimeout* NSEC_PER_SEC),
                              DISPATCH_TIME_FOREVER,
                              1ull * NSEC_PER_SEC);
    
    dispatch_source_set_event_handler(loginCancelOperation, ^{
        DDLogInfo(@"login cancel op");
        
        self->_loginStarted=NO;
        // try again
        if((self.accountState<kStateHasStream) && (self->_loggedInOnce))
        {
            DDLogInfo(@"trying to login again");
            //make sure we are enabled still.
            if([[DataLayer sharedInstance] isAccountEnabled:[NSString stringWithFormat:@"%@",self.accountNo]]) {
#if TARGET_OS_IPHONE
                //temp background task while a new one is created
                __block UIBackgroundTaskIdentifier tempTask= [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^(void) {
                    [[UIApplication sharedApplication] endBackgroundTask:tempTask];
                    tempTask=UIBackgroundTaskInvalid;
                }];
                
#endif
                [self reconnect];
                
#if TARGET_OS_IPHONE
                [[UIApplication sharedApplication] endBackgroundTask:tempTask];
                tempTask=UIBackgroundTaskInvalid;
#endif
                
            }
        }
        else if (self.accountState>=kStateLoggedIn ) {
            NSString *accountName =[NSString stringWithFormat:@"%@@%@", self.username, self.domain];
            NSDictionary *dic =@{@"AccountNo":self.accountNo, @"AccountName":accountName};
            [[NSNotificationCenter defaultCenter] postNotificationName:kMLHasConnectedNotice object:dic];
        }
        else {
            DDLogInfo(@"failed to login and not retrying");
        }
        
    });
    
    dispatch_source_cancel(loginCancelOperation);
    
    
    dispatch_source_set_cancel_handler(loginCancelOperation, ^{
        DDLogInfo(@"login timer cancelled");
        if(self.accountState<kStateHasStream)
        {
            if(!self->_reconnectScheduled)
            {
                self->_loginStarted=NO;
                DDLogInfo(@"login client does not have stream");
                self->_accountState=kStateReconnecting;
                [self reconnect];
            }
        }
    });
    
    dispatch_resume(loginCancelOperation);
}

-(void) disconnect
{
    [self disconnectWithCompletion:nil];
}

-(void) closeSocket
{
    [self.networkQueue cancelAllOperations];
    [self.networkQueue addOperationWithBlock:^{
        
        self.connectedTime =nil;
        
        self.pingID=nil;
        DDLogInfo(@"removing streams");
        
        //prevent any new read or write
        [self->_iStream setDelegate:nil];
        [self->_oStream setDelegate:nil];
        
        [self->_oStream removeFromRunLoop:[NSRunLoop mainRunLoop]
                            forMode:NSDefaultRunLoopMode];
        
        [self->_iStream removeFromRunLoop:[NSRunLoop mainRunLoop]
                            forMode:NSDefaultRunLoopMode];
        DDLogInfo(@"removed streams");
        
        self->_inputBuffer=[[NSMutableString alloc] init];
        self->_outputQueue=[[NSMutableArray alloc] init];
        
        @try
        {
            [self->_iStream close];
        }
        @catch(id theException)
        {
            DDLogError(@"Exception in istream close");
        }
        
        @try
        {
            [self->_oStream close];
        }
        @catch(id theException)
        {
            DDLogError(@"Exception in ostream close");
        }
        
    }];
}

-(void) resetValues
{
    _startTLSComplete=NO;
    _streamHasSpace=NO;
    _loginStarted=NO;
    _loginStartTimeStamp=nil;
    _loginError=NO;
    _accountState=kStateDisconnected;
    _reconnectScheduled =NO;
    
    self.httpUploadQueue =nil;
}

-(void) cleanUpState
{
    if(self.explicitLogout)
    {
        _unAckedStanzas=nil;
        self.discoveredServices=nil;
        [self persistState];
    }
    
    [_contactsVC clearContactsForAccount:_accountNo];
    [[DataLayer sharedInstance] resetContactsForAccount:_accountNo];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:kMonalAccountStatusChanged object:nil];
    
    DDLogInfo(@"Connections closed");

    [self resetValues];
    
    DDLogInfo(@"All closed and cleaned up");
    
}

-(void) disconnectWithCompletion:(void(^)(void))completion
{
    if(self.explicitLogout && _accountState>=kStateHasStream)
    {
        if(_accountState>=kStateBound)
        {
            //disable push for this node
            if(self.pushNode && [self.pushNode length]>0 && self.supportsPush)
            {
                XMPPIQ* disable=[[XMPPIQ alloc] initWithType:kiqSetType];
                [disable setPushDisableWithNode:self.pushNode];
                [self writeToStream:disable.XMLString]; // dont even bother queueing
            }
            
            //send last smacks ack as required by smacks revision 1.5.2
            if(self.supportsSM3)
            {
                MLXMLNode *aNode = [[MLXMLNode alloc] initWithElement:@"a"];
                NSDictionary *dic= @{@"xmlns":@"urn:xmpp:sm:3",@"h":[NSString stringWithFormat:@"%@",self.lastHandledInboundStanza] };
                aNode.attributes = [dic mutableCopy];
                [self writeToStream:aNode.XMLString]; // dont even bother queueing
            }
            
            
        }
        
        //close stream
        MLXMLNode* stream = [[MLXMLNode alloc] init];
        stream.element = @"/stream:stream"; //hack to close stream
        [self writeToStream:stream.XMLString]; // dont even bother queueing
        
        //preserve unAckedStanzas even on explicitLogout and resend them on next connect
        //if we don't do this messages could be lost when logging out directly after sending them
        //and: sending messages twice is less intrusive than silently losing them
        NSMutableArray* stanzas = self.unAckedStanzas;
        
        //reset smacks state to sane values (this can be done even if smacks is not supported)
        [self initSM3];
        self.unAckedStanzas=stanzas;
        
        //persist these changes
        [self persistState];
        
    }
    
    [self closeSocket];
    
    [self.networkQueue addOperationWithBlock:^{
        [self cleanUpState];
        if(completion) completion();
    }];
    
}

-(void) reconnect
{
    [self reconnect:5.0];
}

-(void) reconnect:(NSInteger) scheduleWait
{
    [self.networkQueue cancelAllOperations];
    
    [self.networkQueue addOperationWithBlock: ^{
        DDLogVerbose(@"reconnecting ");
        //can be called multiple times
        
        if(!self.loginStartTimeStamp)  self.loginStartTimeStamp=[NSDate date]; // can be destroyed by threads resulting in a deadlock
        if (self->_loginStarted && [[NSDate date] timeIntervalSinceDate:self.loginStartTimeStamp]>10)
        {
            DDLogVerbose(@"reconnect called while one already in progress that took more than 10 seconds. disconnect before reconnect.");
            [self disconnectWithCompletion:^{
                [self reconnect];
            }];
            return; 
        }
        else if(self->_loginStarted) {
            DDLogVerbose(@"reconnect called while one already in progress. Stopping.");
            return;
        }
        
        DDLogVerbose(@"Login started is %d timestamp diff %f",self->_loginStarted, [[NSDate date] timeIntervalSinceDate:self.loginStartTimeStamp]);
      
        
        self->_loginStarted=YES;
        
        NSTimeInterval wait=scheduleWait;
        if(!self->_loggedInOnce) {
            wait=0;
        }
#if TARGET_OS_IPHONE
     
        
        if(self.pushEnabled)
        {
            DDLogInfo(@"Using Push path for reconnct");
    
            if(!_reconnectScheduled)
            {
                _reconnectScheduled=YES;
                DDLogInfo(@"Trying to connect again in %d seconds. ", wait);
                dispatch_queue_t q_background = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, wait * NSEC_PER_SEC), q_background,  ^{
                    //there may be another login operation freom reachability or another timer
                    if(self.accountState<kStateReconnecting) {
                        [self connect];
                    }
                });
            } else  {
                DDLogInfo(@"reconnect scheduled already" );
            }
        }
        else  {
             DDLogInfo(@"Using non push path for reconnct");
        __block UIBackgroundTaskIdentifier reconnectBackgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^(void) {
            
            if((([UIApplication sharedApplication].applicationState==UIApplicationStateBackground)
                || ([UIApplication sharedApplication].applicationState==UIApplicationStateInactive )) && _accountState<kStateHasStream)
            {
                //present notification
                NSDate* theDate=[NSDate dateWithTimeIntervalSinceNow:0]; //immediate fire
                UIApplication* app = [UIApplication sharedApplication];
                // Create a new notification
                UILocalNotification* alarm = [[UILocalNotification alloc] init];
                if (alarm)
                {
                    if(!_hasShownAlert ) {
                        _hasShownAlert=YES;
                        //scehdule info
                        alarm.fireDate = theDate;
                        alarm.timeZone = [NSTimeZone defaultTimeZone];
                        alarm.repeatInterval = 0;
                        alarm.alertBody =  @"Could not reconnect and fetch messages. Please reopen and make sure you are connected.";
                        
                        [app scheduleLocalNotification:alarm];
                        
                        DDLogVerbose(@"Scheduled local disconnect alert ");
                        [self disconnect];
                    }
                    
                }
            }
            
            DDLogVerbose(@"Reconnect bgtask took too long. closing");
            [[UIApplication sharedApplication] endBackgroundTask:reconnectBackgroundTask];
            reconnectBackgroundTask=UIBackgroundTaskInvalid;
            
        }];
        
        if (reconnectBackgroundTask != UIBackgroundTaskInvalid) {
            if(_accountState>=kStateReconnecting) {
                DDLogInfo(@" account sate >=reconencting, disconnecting first" );
                [self disconnectWithCompletion:^{
                    [self reconnect:0];
                }];
                return;
            }
            
            if(!_reconnectScheduled)
            {
                _reconnectScheduled=YES;
                DDLogInfo(@"Trying to connect again in %f seconds. ", wait);
                dispatch_queue_t q_background = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, wait * NSEC_PER_SEC), q_background,  ^{
                    //there may be another login operation freom reachability or another timer
                    if(self.accountState<kStateReconnecting) {
                        [self connect];
                        [[UIApplication sharedApplication] endBackgroundTask:reconnectBackgroundTask];
                        reconnectBackgroundTask=UIBackgroundTaskInvalid;
                    }
                });
            } else  {
                DDLogInfo(@"reconnect scheduled already" );
            }
        }
    }
#else
        if(_accountState>=kStateReconnecting) {
            DDLogInfo(@" account sate >=reconencting, disconnecting first" );
            [self disconnectWithCompletion:^{
                [self reconnect:0];
            }];
            return;
        }
    
        
        if(!_reconnectScheduled)
        {
            _loginStarted=YES;
            _reconnectScheduled=YES;
            DDLogInfo(@"Trying to connect again in %f seconds. ", wait);
            dispatch_queue_t q_background = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, wait * NSEC_PER_SEC), q_background,  ^{
                //there may be another login operation freom reachability or another timer
                if(self.accountState<kStateReconnecting) {
                    [self connect];
                }
            });
        } else  {
            DDLogInfo(@"reconnect scheduled already" );
        }
        
#endif
        
        DDLogInfo(@"reconnect exits");
    }];
}

#pragma mark XMPP

-(void) startStream
{
    [self.networkQueue addOperationWithBlock: ^{
        //flush buffer to ignore all prior input
        self->_inputBuffer=[[NSMutableString alloc] init];
        
        DDLogInfo(@" got read queue");
        
        MLXMLNode* stream = [[MLXMLNode alloc] init];
        stream.element=@"stream:stream";
        [stream.attributes setObject:@"jabber:client" forKey:@"xmlns"];
        [stream.attributes setObject:@"http://etherx.jabber.org/streams" forKey:@"xmlns:stream"];
        [stream.attributes setObject:@"1.0" forKey:@"version"];
        if(self->_domain)
            [stream.attributes setObject:self->_domain forKey:@"to"];
        [self send:stream];
    }];
}


-(void)setPingTimerForID:(NSString *)pingID
{
    DDLogInfo(@"setting timer for ping %@", pingID);
    self.pingID=pingID;
    dispatch_queue_t q_background = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_source_t pingTimeOut = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                           q_background);
    
    dispatch_source_set_timer(pingTimeOut,
                              dispatch_time(DISPATCH_TIME_NOW, kPingTimeout* NSEC_PER_SEC),
                              DISPATCH_TIME_FOREVER,
                              1ull * NSEC_PER_SEC);
    
    dispatch_source_set_event_handler(pingTimeOut, ^{
        
        if(self.pingID)
        {
            DDLogVerbose(@"ping timed out without a reply to %@",self.pingID);
            _accountState=kStateReconnecting;
            [self reconnect];
        }
        else
        {
            DDLogVerbose(@"ping reply was seen");
            
        }
        
        dispatch_source_cancel(pingTimeOut);
        
    });
    
    dispatch_source_set_cancel_handler(pingTimeOut, ^{
        DDLogInfo(@"ping timer cancelled");
    });
    
    dispatch_resume(pingTimeOut);
}

-(void) sendPing
{
    if(self.accountState<kStateReconnecting  && !_reconnectScheduled)
    {
        DDLogInfo(@" ping calling reconnect");
        _accountState=kStateReconnecting;
        [self reconnect:0];
        return;
    }
    
    if(self.accountState<kStateBound)
    {
        if(_loginStarted && [[NSDate date] timeIntervalSinceDate:self.loginStartTimeStamp]<=10) {
            DDLogInfo(@"ping attempt before logged in and bound. returning.");
            return;
        }
        else if (_loginStarted && [[NSDate date] timeIntervalSinceDate:self.loginStartTimeStamp]>10)
        {
            DDLogVerbose(@"ping called while one already in progress that took more than 10 seconds. disconnect before reconnect.");
            [self reconnect:0];
        }
        
    }
    else {
        //always use smacks pings if supported (they are shorter and better than whitespace pings)
        if(self.supportsSM3)
        {
            MLXMLNode* rNode =[[MLXMLNode alloc] initWithElement:@"r"];
            NSDictionary *dic=@{@"xmlns":@"urn:xmpp:sm:3"};
            rNode.attributes =[dic mutableCopy];
            [self send:rNode];
        }
        else  {
            if(self.supportsPing) {
                XMPPIQ* ping =[[XMPPIQ alloc] initWithType:kiqGetType];
                [ping setiqTo:_domain];
                [ping setPing];
                [self send:ping];
            } else  {
                [self sendWhiteSpacePing];
            }
        }
    }
}

-(void) sendWhiteSpacePing
{
    if(self.accountState<kStateReconnecting  )
    {
        DDLogInfo(@" whitespace ping calling reconnect");
        _accountState=kStateReconnecting;
        [self reconnect:0];
        return;
    }
    
    MLXMLNode* ping =[[MLXMLNode alloc] initWithElement:@"whitePing"]; // no such element. Node has logic to  print white space
    [self send:ping];
}




-(NSMutableDictionary*) nextStanza
{
    NSString* __block toReturn=nil;
    NSString* __block stanzaType=nil;
    
 //   DDLogVerbose(@"maxPos %ld", _inputBuffer.length );
    
    if(_inputBuffer.length<2)
    {
        return nil;
    }
    //accouting for white space
    NSRange startrange=[_inputBuffer rangeOfString:@"<"
                                           options:NSCaseInsensitiveSearch range:NSMakeRange(0, [_inputBuffer length])];
    if (startrange.location==NSNotFound)
    {
        toReturn= nil;
        return nil;
    }
   // DDLogVerbose(@"input bufffer  %@", _inputBuffer);
    NSInteger finalstart=0;
    NSInteger finalend=0;
    
    NSInteger startpos=startrange.location;
   DDLogVerbose(@"start pos%ld", (long)startpos);
    if(startpos!=0)
    {
        //this shoudlnt happen
        DDLogVerbose(@"start in the middle. there was a glitch or whitespace");
    }
    
    
    if(_inputBuffer.length>startpos)
    {
        NSString *element;
        NSRange pos;
        NSRange endPos=[_inputBuffer rangeOfString:@">"
                                           options:NSCaseInsensitiveSearch range:NSMakeRange(startpos, _inputBuffer.length-startpos)];
        //we have the max bounds of he XML tag.
        if(endPos.location==NSNotFound) {
            DDLogVerbose(@"dont have the end. exit at 0 ");
            return nil;
        }
        else  {
            //look for a space if there is one
            NSRange spacePos=[_inputBuffer rangeOfString:@" "
                                                 options:NSCaseInsensitiveSearch range:NSMakeRange(startpos, endPos.location-startpos)];
            pos=endPos;
            
            if(spacePos.location!=NSNotFound) {
                pos=spacePos;
            }
            
            element= [_inputBuffer substringWithRange:NSMakeRange(startpos+1, pos.location-(startpos+1))];
            DDLogVerbose(@"got element %@", element);
            
            if([element isEqualToString:@"?xml"] || [element isEqualToString:@"stream:stream"] || [element isEqualToString:@"stream"])
            {
                stanzaType= element;
                element =nil;
                NSRange endPos=[_inputBuffer rangeOfString:@">"
                                                   options:NSCaseInsensitiveSearch range:NSMakeRange(pos.location, _inputBuffer.length-pos.location)];
                
                finalstart=startpos;
                finalend=endPos.location+1;
                DDLogVerbose(@"exiting at 1 ");
                
            }
        }
        
        if(element)
        {
            stanzaType= element;
            
            {
                NSRange dupePos=[_inputBuffer rangeOfString:[NSString stringWithFormat:@"<%@",stanzaType]
                                                    options:NSCaseInsensitiveSearch range:NSMakeRange(pos.location+1, _inputBuffer.length-pos.location-1)];
                
                
                if([stanzaType isEqualToString:@"message"] && dupePos.location!=NSNotFound) {
                    //check for carbon forwarded
                    NSRange forwardPos=[_inputBuffer rangeOfString:@"<forwarded"
                                                           options:NSCaseInsensitiveSearch range:NSMakeRange(pos.location, dupePos.location-pos.location-1)];
                    
                    NSRange firstClose=[_inputBuffer rangeOfString:@"</message"
                                                           options:NSCaseInsensitiveSearch range:NSMakeRange(pos.location, dupePos.location-pos.location-1)];
                    //if message clsoed before forwarded, not the same
                    
                    
                    if(forwardPos.location!=NSNotFound && firstClose.location==NSNotFound) {
                        
                        //look for next message close
                        NSRange forwardClosePos=[_inputBuffer rangeOfString:@"</forwarded"
                                                                    options:NSCaseInsensitiveSearch range:NSMakeRange(forwardPos.location, _inputBuffer.length-forwardPos.location)];
                        
                        if(forwardClosePos.location!=NSNotFound) {
                            NSRange messageClose =[_inputBuffer rangeOfString:[NSString stringWithFormat:@"</%@",stanzaType]
                                                                      options:NSCaseInsensitiveSearch range:NSMakeRange(forwardClosePos.location, _inputBuffer.length-forwardClosePos.location)];
                            //ensure it is set to future max
                            
                            finalstart=startpos;
                            finalend=messageClose.location+messageClose.length+1; //+1 to inclde closing <
                            DDLogVerbose(@"at  2.5");
                            // break;
                        }
                        else {
                            DDLogVerbose(@"Incomplete stanza  missing forward close. at 2.6");
                            return nil;
                        }
                        
                    }
                    else if(firstClose.location!=NSNotFound) {
                        DDLogVerbose(@"found close without forward . at 2.7");
                        finalend=firstClose.location+firstClose.length+1;
                    }
                }
                
                else {
                    
                    //since there is another block of the same stanza, short cuts dont work.check to find beginning of next element
                    NSInteger maxPos=_inputBuffer.length;
                    if((dupePos.location<_inputBuffer.length) && (dupePos.location!=NSNotFound))
                    {
                        //reduce search to within the set of this and at max the next element of the same kind
                        maxPos=dupePos.location;
                        
                    }
                    
                    //  we need to find the end of this stanza
                    NSRange closePos=[_inputBuffer rangeOfString:[NSString stringWithFormat:@"</%@",stanzaType]
                                                         options:NSCaseInsensitiveSearch range:NSMakeRange(pos.location, maxPos-pos.location)];
                    
                    if((closePos.location<maxPos) && (closePos.location!=NSNotFound)){
                        //we have the start of the stanza close
                        
                        NSRange endPos=[_inputBuffer rangeOfString:@">"
                                                           options:NSCaseInsensitiveSearch range:NSMakeRange(closePos.location, maxPos-closePos.location)];
                        
                        finalstart=startpos;
                        finalend=endPos.location+1; //+1 to inclde closing >
                        DDLogVerbose(@"at  3");
                        //  break;
                    }
                    else {
                        
                        //check if self closed
                        NSRange endPos=[_inputBuffer rangeOfString:@"/>"
                                                           options:NSCaseInsensitiveSearch range:NSMakeRange(startpos, _inputBuffer.length-startpos)];
                        
                        //are ther children, then not self closed
                        if(endPos.location<_inputBuffer.length && endPos.location!=NSNotFound)
                        {
                            NSRange childPos=[_inputBuffer rangeOfString:[NSString stringWithFormat:@"<"]
                                                                 options:NSCaseInsensitiveSearch range:NSMakeRange(startpos+1, endPos.location-startpos)];
                            if((childPos.location<_inputBuffer.length) && (childPos.location!=NSNotFound)){
                                DDLogVerbose(@"at 3.5 looks like incomplete stanza. need to get more. loc %d", childPos.location);
                                return nil;
                                // break;
                            }
                        }
                        
                        
                        if((endPos.location<_inputBuffer.length) && (endPos.location!=NSNotFound)) {
                            finalstart=startpos;
                            finalend=endPos.location+2; //+2 to inclde closing />
                            DDLogVerbose(@"at  4 self closed");
                            // break;
                        }
                        else
                            if([stanzaType isEqualToString:@"stream"]) {
                                //stream will have no terminal.
                                finalstart=pos.location;
                                finalend=maxPos;
                                DDLogVerbose(@"at  5 stream");
                            }
                        
                    }
                }
            }
        }
    }
    
    
    
    //if this happens its  probably a stream error.sanity check is  preventing crash
    
    if((finalend-finalstart<=_inputBuffer.length) && finalend!=NSNotFound && finalstart!=NSNotFound && finalend>=finalstart)
    {
        toReturn=  [_inputBuffer substringWithRange:NSMakeRange(finalstart,finalend-finalstart)];
    }
    if([toReturn length]==0) toReturn=nil;
    
    if(!stanzaType)
    {
        //this is junk data no stanza start
        _inputBuffer=[[NSMutableString alloc] init];
        DDLogVerbose(@"wiped input buffer with no start");
        
    }
    else{
        if((finalend-finalstart<=_inputBuffer.length) && finalend!=NSNotFound && finalstart!=NSNotFound && finalend>=finalstart)
        {
            //  DDLogVerbose(@"to del start %d end %d: %@", finalstart, finalend, _inputBuffer);
            if(finalend <=[_inputBuffer length] ) {
                [_inputBuffer deleteCharactersInRange:NSMakeRange(finalstart, finalend-finalstart) ];
            } else {
                DDLogVerbose(@"Something wrong with lengths."); //This should not happen
                [_inputBuffer deleteCharactersInRange:NSMakeRange(finalstart, [_inputBuffer length] -finalstart) ];
            }
            
        }
    }
    
    NSMutableDictionary* returnDic=nil;
    
    if(stanzaType && toReturn)
    {
        returnDic=[[NSMutableDictionary alloc]init];
        [returnDic setObject:toReturn forKey:@"stanzaString"];
        [returnDic setObject:stanzaType forKey:@"stanzaType"];
    }
    
    return  returnDic;
}

#pragma mark message ACK
-(void) sendUnAckedMessages
{
    [self.networkQueue addOperation:
     [NSBlockOperation blockOperationWithBlock:^{
        if(self.unAckedStanzas)
        {
            for (NSDictionary *dic in self.unAckedStanzas)
            {
                [self send:(MLXMLNode*)[dic objectForKey:kStanza]];
            }
        }
    }]];
}

-(void) removeUnAckedMessagesLessThan:(NSNumber*) hvalue
{
    [self.networkQueue addOperation:
     [NSBlockOperation blockOperationWithBlock:^{
        if(self.unAckedStanzas)
        {
            NSMutableArray *iterationArray = [self.unAckedStanzas mutableCopy];
            DDLogDebug(@"removeUnAckedMessagesLessThan: hvalue %@, lastOutboundStanza %@", hvalue, self.lastOutboundStanza);
            NSMutableArray *discard =[[NSMutableArray alloc] initWithCapacity:[self.unAckedStanzas count]];
            for(NSDictionary *dic in iterationArray)
            {
                NSNumber *stanzaNumber = [dic objectForKey:kStanzaID];
                if([stanzaNumber integerValue]<[hvalue integerValue])
                {
                    [discard addObject:dic];
                }
            }
            
            [iterationArray removeObjectsInArray:discard];
            if(self.unAckedStanzas) self.unAckedStanzas= iterationArray; // if it was set to nil elsewhere, dont restore
            
            //persist these changes
            [self persistState];
        }
        
    }]];
}


#pragma mark stanza handling

-(void) enableCarbons
{
    XMPPIQ* carbons =[[XMPPIQ alloc] initWithId:@"enableCarbons" andType:kiqSetType];
    MLXMLNode *enable =[[MLXMLNode alloc] initWithElement:@"enable"];
    [enable setXMLNS:@"urn:xmpp:carbons:2"];
    [carbons.children addObject:enable];
    [self send:carbons];
}
-(void) parseFeatures
{
    if([self.serverFeatures containsObject:@"urn:xmpp:carbons:2"])
    {
        if(!self.usingCarbons2){
            [self enableCarbons];
        }
    }
    
    if([self.serverFeatures containsObject:@"urn:xmpp:ping"])
    {
        self.supportsPing=YES;
    }
    
}

-(void) processInput
{
    //prevent reconnect attempt
    if(_accountState<kStateHasStream) _accountState=kStateHasStream;
    [self.networkQueue addOperationWithBlock:^{
        NSDictionary* stanzaToParse=[self nextStanza];
        while (stanzaToParse)
        {
            [self.processQueue addOperationWithBlock:^{
                DDLogDebug(@"got stanza %@", stanzaToParse);
                
                if([[stanzaToParse objectForKey:@"stanzaType"]  isEqualToString:@"iq"])
                {
                    if(self.accountState>=kStateBound)
                        self.lastHandledInboundStanza=[NSNumber numberWithInteger: [self.lastHandledInboundStanza integerValue]+1];
                    ParseIq* iqNode= [[ParseIq alloc]  initWithDictionary:stanzaToParse];
                    if ([iqNode.type isEqualToString:kiqErrorType])
                    {
                        return;
                    }
                    
                    if(iqNode.discoInfo) {
                        [self cleanDisco];
                    }
                    
                    if(iqNode.features && iqNode.discoInfo) {
                        if([iqNode.from isEqualToString:self.server] || [iqNode.from isEqualToString:self.domain]) {
                            self.serverFeatures=[iqNode.features copy];
                            [self parseFeatures];
                        }
                        
                        if([iqNode.features containsObject:@"urn:xmpp:http:upload"])
                        {
                            self.supportsHTTPUpload=YES;
                            self.uploadServer = iqNode.from;
                        }
                        
                        if([iqNode.features containsObject:@"http://jabber.org/protocol/muc"])
                        {
                            self.conferenceServer=iqNode.from;
                        }
                      
                        if([iqNode.features containsObject:@"urn:xmpp:push:0"])
                        {
                            self.supportsPush=true;
                            [self enablePush];
                        }
                        
                        if([iqNode.features containsObject:@"urn:xmpp:mam:2"])
                        {
                            self.supportsMam2=YES;
                            DDLogInfo(@" supports mam:2");
                        }
                    }
                    
                    if(iqNode.legacyAuth)
                    {
                        XMPPIQ* auth =[[XMPPIQ alloc] initWithId:@"auth2" andType:kiqSetType];
                        [auth setAuthWithUserName:self.username resource:self.resource andPassword:self.password];
                        [self send:auth];
                    }
                    
                    if(iqNode.shouldSetBind)
                    {
                        self->_jid=iqNode.jid;
                        DDLogVerbose(@"Set jid %@", self->_jid);
                        
                        if(self.supportsSM3)
                        {
                            MLXMLNode *enableNode =[[MLXMLNode alloc] initWithElement:@"enable"];
                            NSDictionary *dic=@{@"xmlns":@"urn:xmpp:sm:3",@"resume":@"true" };
                            enableNode.attributes =[dic mutableCopy];
                            [self send:enableNode];
                        }
                        else
                        {
                            //init session and query disco, roster etc.
                            [self initSession];
                        }
                    }
                    
                    if([iqNode.type isEqualToString:kiqGetType])
                    {
                        if((iqNode.discoInfo))
                        {
                            XMPPIQ* discoInfo =[[XMPPIQ alloc] initWithId:iqNode.idval andType:kiqResultType];
                            [discoInfo setiqTo:iqNode.from];
                            [discoInfo setDiscoInfoWithFeaturesAndNode:iqNode.queryNode];
                            [self send:discoInfo];
                            
                        }
                        
                        
                    }
                    
                    if(iqNode.vCard && iqNode.user)
                    {
                        NSString* fullname=iqNode.fullName;
                        if(!fullname) fullname= iqNode.user;
                        [[DataLayer sharedInstance] setFullName:fullname forContact:iqNode.user andAccount:self->_accountNo];
                        
                        if(iqNode.photoBinValue)
                        {
                            [[MLImageManager sharedInstance] setIconForContact:iqNode.user andAccount:self->_accountNo WithData:[iqNode.photoBinValue copy]];
                            
                        }
                        
                        if(!fullname) fullname=iqNode.user;
                        
                        NSDictionary* userDic=@{kusernameKey: iqNode.user,
                                                kfullNameKey: fullname,
                                                kaccountNoKey:self->_accountNo
                                                };
                        [[NSNotificationCenter defaultCenter] postNotificationName:kMonalContactRefresh object:self userInfo:userDic];
                        
                    }
                    
                    if(iqNode.ping)
                    {
                        XMPPIQ* pong =[[XMPPIQ alloc] initWithId:iqNode.idval andType:kiqResultType];
                        [pong setiqTo:self->_domain];
                        [self send:pong];
                    }
                    
                    if([iqNode.idval isEqualToString:self.pingID])
                    {
                        //response to my ping
                        self.pingID=nil;
                    }
                    
                    if(iqNode.httpUpload)
                    {
                        NSDictionary *matchingRow;
                        //look up id val in upload queue array
                        for(NSDictionary * row in self.httpUploadQueue)
                        {
                            if([[row objectForKey:kId] isEqualToString:iqNode.idval])
                            {
                                matchingRow= row;
                                break;
                            }
                        }
                        
                        if(matchingRow) {
                            
                            //upload to put
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [MLHTTPRequest sendWithVerb:kPut path:iqNode.putURL withArguments:nil data:[matchingRow objectForKey:kData] andCompletionHandler:^(NSError *error, id result) {
                                    void (^completion) (NSString *url,  NSError *error)  = [matchingRow objectForKey:kCompletion];
                                    if(!error)
                                    {
                                        //send get to contact
                                        if(completion)
                                        {
                                            completion(iqNode.getURL, nil);
                                        }
                                    } else  {
                                        if(completion)
                                        {
                                            completion(nil, error);
                                        }
                                    }
                                    
                                }];
                            });
                            
                        }
                    }
                    
                    
                    if (iqNode.version)
                    {
                        XMPPIQ* versioniq =[[XMPPIQ alloc] initWithId:iqNode.idval andType:kiqResultType];
                        [versioniq setiqTo:iqNode.from];
                        [versioniq setVersion];
                        [self send:versioniq];
                    }
                    
                    if (iqNode.last)
                    {
                        XMPPIQ* lastiq =[[XMPPIQ alloc] initWithId:iqNode.idval andType:kiqResultType];
                        [lastiq setiqTo:iqNode.from];
                        [lastiq setLast];
                        [self send:lastiq];
                    }
                    
                    if (iqNode.time)
                    {
                        XMPPIQ* timeiq =[[XMPPIQ alloc] initWithId:iqNode.idval andType:kiqResultType];
                        [timeiq setiqTo:iqNode.from];
                        //[lastiq setLast];
                        [self send:timeiq];
                    }
                    
                    
                    if ([iqNode.type isEqualToString:kiqResultType])
                    {
                        if(iqNode.mam2Last && !iqNode.mam2fin)
                        {
                            //RSM seems broken on servers. Tell UI there is more to fetch
                            [[NSNotificationCenter defaultCenter] postNotificationName:kMLMAMMore object:nil];
                            
                        }
                        
                        //OMEMO
 #ifndef DISABLE_OMEMO
                        if(iqNode.omemoDevices)
                        {
                            [iqNode.omemoDevices enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                                NSString *device  =(NSString *)obj;
                                [self queryOMEMOBundleFrom:iqNode.from andDevice:device];
                            }];
                            
                        }
                        

                        if(iqNode.signedPreKeyPublic && self.signalContext)
                        {
                            SignalAddress *address = [[SignalAddress alloc] initWithName:iqNode.from deviceId:0];
                            SignalSessionBuilder *builder = [[SignalSessionBuilder alloc] initWithAddress:address context:self.signalContext];
                            NSError *error;
                            
                            [iqNode.preKeys enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                                
                                NSDictionary *row = (NSDictionary *) obj;
                                NSString *keyid = (NSString *)[row objectForKey:@"preKeyId"];
                                
                                SignalPreKeyBundle *bundle = [[SignalPreKeyBundle alloc] initWithRegistrationId:0
                                                                                                       deviceId:(uint32_t)[iqNode.deviceid intValue]
                                                                                                       preKeyId:[keyid integerValue]
                                                                                                   preKeyPublic:[EncodingTools dataWithBase64EncodedString:[row objectForKey:@"preKey"]]
                                                                                                 signedPreKeyId:iqNode.signedPreKeyId.integerValue
                                                                                             signedPreKeyPublic:[EncodingTools dataWithBase64EncodedString:iqNode.signedPreKeyPublic]
                                                                                                      signature:[EncodingTools dataWithBase64EncodedString:iqNode.signedPreKeySignature]
                                                                                                    identityKey:[EncodingTools dataWithBase64EncodedString:iqNode.identityKey]
                                                                                                          ];
                             
                                [builder processPreKeyBundle:bundle error:nil];
                            }];
                            
                        }
#endif
                        
                        
                        if([iqNode.idval isEqualToString:@"enableCarbons"])
                        {
                            self.usingCarbons2=YES;
                            [self cleanEnableCarbons];
                        }
                        
                        if(iqNode.mam2default)
                        {
                            [[NSNotificationCenter defaultCenter] postNotificationName:kMLMAMPref object:@{@"mamPref":iqNode.mam2default}];
                        }
                        
                        
                        if(iqNode.discoItems==YES)
                        {
                            if(([iqNode.from isEqualToString:self.server] || [iqNode.from isEqualToString:self.domain]) && !self->_discoveredServices)
                            {
                                for (NSDictionary* item in iqNode.items)
                                {
                                    if(!self->_discoveredServices) _discoveredServices=[[NSMutableArray alloc] init];
                                    [self->_discoveredServices addObject:item];
                                    
                                    if((![[item objectForKey:@"jid"] isEqualToString:self.server]  &&  ![[item objectForKey:@"jid"] isEqualToString:self.domain])) {
                                        [self discoverService:[item objectForKey:@"jid"]];
                                    }
                                }
                                [self discoverService:self.fulluser];   //discover push support
                            }
                            else
                            {
                                
                            }
                        }
                        else if (iqNode.roster==YES)
                        {
                            self.rosterList=iqNode.items;
                            
                            for(NSDictionary* contact in self.rosterList)
                            {
                                
                                if([[contact objectForKey:@"subscription"] isEqualToString:@"both"])
                                {
                                    [[DataLayer sharedInstance] addContact:[contact objectForKey:@"jid"]?[contact objectForKey:@"jid"]:@"" forAccount:_accountNo fullname:[contact objectForKey:@"name"]?[contact objectForKey:@"name"]:@"" nickname:[contact objectForKey:@"name"]?[contact objectForKey:@"name"]:@"" withCompletion:^(BOOL success) {
                                        
                                        if(!success && ((NSString *)[contact objectForKey:@"name"]).length>0)
                                        {
                                            [[DataLayer sharedInstance] setFullName:[contact objectForKey:@"name"]?[contact objectForKey:@"name"]:@"" forContact:[contact objectForKey:@"jid"]?[contact objectForKey:@"jid"]:@"" andAccount:_accountNo ] ;
                                        }
                                        
                                    }];
                                    
                                }
                                else
                                {
                                    
                                }
                            }
                         
                            // iterate roster and get cards
                            [self getVcards];
                        }
                        
                        //confirmation of set call after we accepted
                        if([iqNode.idval isEqualToString:self.jingle.idval])
                        {
                            NSArray* nameParts= [iqNode.from componentsSeparatedByString:@"/"];
                            NSString* from;
                            if([nameParts count]>1) {
                                from=[nameParts objectAtIndex:0];
                            } else from = iqNode.from;
                            
                            NSString* fullName;
                            fullName=[[DataLayer sharedInstance] fullName:from forAccount:self->_accountNo];
                            if(!fullName) fullName=from;
                            
                            NSDictionary* userDic=@{@"buddy_name":from,
                                                    @"full_name":fullName,
                                                    kAccountID:self->_accountNo
                                                    };
                            
                            [[NSNotificationCenter defaultCenter]
                             postNotificationName: kMonalCallStartedNotice object: userDic];
                            
                            
                            [self.jingle rtpConnect];
                            return;
                        }
                        
                    }
                    
                    
                    if ([iqNode.type isEqualToString:kiqSetType]) {
                        if(iqNode.jingleSession) {
                            
                            //accpetance of our call
                            if([[iqNode.jingleSession objectForKey:@"action"] isEqualToString:@"session-accept"] &&
                               [[iqNode.jingleSession objectForKey:@"sid"] isEqualToString:self.jingle.thesid])
                            {
                                
                                NSDictionary* transport1;
                                NSDictionary* transport2;
                                for(NSDictionary* candidate in iqNode.jingleTransportCandidates) {
                                    if([[candidate objectForKey:@"component"] isEqualToString:@"1"]) {
                                        transport1=candidate;
                                    }
                                    if([[candidate objectForKey:@"component"] isEqualToString:@"2"]) {
                                        transport2=candidate;
                                    }
                                }
                                
                                NSDictionary* pcmaPayload;
                                for(NSDictionary* payload in iqNode.jinglePayloadTypes) {
                                    if([[payload objectForKey:@"name"] isEqualToString:@"PCMA"]) {
                                        pcmaPayload=payload;
                                        break;
                                    }
                                }
                                
                                if (pcmaPayload && transport1) {
                                    self.jingle.recipientIP=[transport1 objectForKey:@"ip"];
                                    self.jingle.destinationPort= [transport1 objectForKey:@"port"];
                                    
                                    XMPPIQ* node = [[XMPPIQ alloc] initWithId:iqNode.idval andType:kiqResultType];
                                    [node setiqTo:[NSString stringWithFormat:@"%@/%@", iqNode.user,iqNode.resource]];
                                    [self send:node];
                                    
                                    [self.jingle rtpConnect];
                                }
                                return;
                            }
                            
                            if([[iqNode.jingleSession objectForKey:@"action"] isEqualToString:@"session-terminate"] &&  [[iqNode.jingleSession objectForKey:@"sid"] isEqualToString:self.jingle.thesid]) {
                                XMPPIQ* node = [[XMPPIQ alloc] initWithId:iqNode.idval andType:kiqResultType];
                                [node setiqTo:[NSString stringWithFormat:@"%@/%@", iqNode.user,iqNode.resource]];
                                [self send:node];
                                [self.jingle rtpDisconnect];
                            }
                            
                            if([[iqNode.jingleSession objectForKey:@"action"] isEqualToString:@"session-initiate"]) {
                                NSDictionary* pcmaPayload;
                                for(NSDictionary* payload in iqNode.jinglePayloadTypes) {
                                    if([[payload objectForKey:@"name"] isEqualToString:@"PCMA"]) {
                                        pcmaPayload=payload;
                                        break;
                                    }
                                }
                                
                                NSDictionary* transport1;
                                NSDictionary* transport2;
                                for(NSDictionary* candidate in iqNode.jingleTransportCandidates) {
                                    if([[candidate objectForKey:@"component"] isEqualToString:@"1"]) {
                                        transport1=candidate;
                                    }
                                    if([[candidate objectForKey:@"component"] isEqualToString:@"2"]) {
                                        transport2=candidate;
                                    }
                                }
                                
                                if (pcmaPayload && transport1) {
                                    self.jingle = [[jingleCall alloc] init];
                                    self.jingle.initiator= [iqNode.jingleSession objectForKey:@"initiator"];
                                    self.jingle.responder= [iqNode.jingleSession objectForKey:@"responder"];
                                    if(!self.jingle.responder)
                                    {
                                        self.jingle.responder = [NSString stringWithFormat:@"%@/%@", iqNode.to, self.resource];
                                    }
                                    
                                    self.jingle.thesid= [iqNode.jingleSession objectForKey:@"sid"];
                                    self.jingle.destinationPort= [transport1 objectForKey:@"port"];
                                    self.jingle.idval=iqNode.idval;
                                    if(transport2) {
                                        self.jingle.destinationPort2= [transport2 objectForKey:@"port"];
                                    }
                                    else {
                                        self.jingle.destinationPort2=[transport1 objectForKey:@"port"]; // if nothing is provided just reuse..
                                    }
                                    self.jingle.recipientIP=[transport1 objectForKey:@"ip"];
                                    
                                    
                                    if(iqNode.user && iqNode.resource && self.fulluser) {
                                        
                                        NSDictionary *dic= @{@"from":iqNode.from,
                                                             @"user":iqNode.user,
                                                             @"resource":iqNode.resource,
                                                             @"id": iqNode.idval,
                                                             kAccountID:_accountNo,
                                                             kAccountName: self.fulluser
                                                             };
                                        
                                        [[NSNotificationCenter defaultCenter]
                                         postNotificationName: kMonalCallRequestNotice object: dic];
                                        
                                    }
                                }
                                else {
                                    //does not support the same formats
                                }
                                
                            }
                        }
                    }
                    
                    
                    if([iqNode.from isEqualToString:self->_conferenceServer] && iqNode.discoItems)
                    {
                        self->_roomList=iqNode.items;
                        [[NSNotificationCenter defaultCenter]
                         postNotificationName: kMLHasRoomsNotice object: self];
                    }
                    
                    
                    if(iqNode.roster)
                    {
                        for (NSDictionary *item in iqNode.items)
                        {
                            
                            if(![[item objectForKey:@"subscription"] isEqualToString:@"none"]) {
                                [[DataLayer sharedInstance] addContact:[item objectForKey:@"jid"] forAccount:self->_accountNo fullname:[item objectForKey:@"name"] nickname:@"" withCompletion:^(BOOL success){
                                    
                                    
                                }];
                            }
                        }
                    }
                    
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"]  isEqualToString:@"message"])
                {
                    if(self.accountState>=kStateBound)
                        self.lastHandledInboundStanza=[NSNumber numberWithInteger: [self.lastHandledInboundStanza integerValue]+1];
                    ParseMessage* messageNode= [[ParseMessage alloc]  initWithDictionary:stanzaToParse];
                    if([messageNode.type isEqualToString:kMessageErrorType])
                    {
                        //TODO: mark message as error
                        return;
                    }
                    
                    
                    if(messageNode.mucInvite)
                    {
                        dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_IPHONE
                            NSString* messageString = [NSString  stringWithFormat:NSLocalizedString(@"You have been invited to a conversation %@?", nil), messageNode.from ];
                            RIButtonItem* cancelButton = [RIButtonItem itemWithLabel:NSLocalizedString(@"Cancel", nil) action:^{
                                
                            }];
                            
                            RIButtonItem* yesButton = [RIButtonItem itemWithLabel:NSLocalizedString(@"Join", nil) action:^{
                                
                                [self joinRoom:messageNode.from withNick:@"test" andPassword:nil]; //TODO fix this
                            }];
                            
                            UIAlertView* alert =[[UIAlertView alloc] initWithTitle:@"Chat Invite" message:messageString cancelButtonItem:cancelButton otherButtonItems:yesButton, nil];
                            [alert show];
#else
#endif
                        });
                        
                    }
                    
                    NSString *recipient=messageNode.to;
                    
                    if(!recipient)
                    {
                        recipient= self->_fulluser;
                    }
                    
                    if(messageNode.subject && messageNode.type==kMessageGroupChatType)
                    {
                        [[DataLayer sharedInstance] updateMucSubject:messageNode.subject forAccount:self.accountNo andRoom:messageNode.from withCompletion:nil];
                     
                    }
                    NSString *decrypted;
                    
                    #ifndef DISABLE_OMEMO
                    if(messageNode.encryptedPayload)
                    {
                        SignalAddress *address = [[SignalAddress alloc] initWithName:messageNode.from deviceId:messageNode.sid.integerValue];
                        if(!self.signalContext) return; 
                    
                        
                        __block NSDictionary *messageKey;
                        [messageNode.signalKeys enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                            NSDictionary *currentKey = (NSDictionary *) obj;
                            NSString* rid=[currentKey objectForKey:@"rid"];
                            if(rid.integerValue==self.monalSignalStore.deviceid)
                            {
                                messageKey=currentKey;
                                *stop=YES;
                            }
                            
                        }];
                        
                        if(!messageKey) return;
                        
                        SignalSessionCipher *cipher = [[SignalSessionCipher alloc] initWithAddress:address context:self.signalContext];
                        SignalCiphertextType messagetype;
                        
                        if([[messageKey objectForKey:@"prekey"] isEqualToString:@"1"])
                        {
                            messagetype=SignalCiphertextTypePreKeyMessage;
                        } else  {
                            messagetype= SignalCiphertextTypeMessage;
                        }
                        
                        NSData *decoded= [EncodingTools dataWithBase64EncodedString:[messageKey objectForKey:@"key"]];
                        
                        SignalCiphertext *ciphertext = [[SignalCiphertext alloc] initWithData:decoded type:messagetype];
                        NSError *error;
                        NSData *decryptedKey=  [cipher decryptCiphertext:ciphertext error:&error];
                        
                        NSData *key;
                        NSData *auth;
                        
                        if(decryptedKey.length==16*2)
                        {
                            key=[decryptedKey subdataWithRange:NSMakeRange(0,16)];
                            auth=[decryptedKey subdataWithRange:NSMakeRange(16,16)];
                        }
                        else {
                            key=decryptedKey;
                        }
                        
                        if(key){
                            NSData *iv = [EncodingTools dataWithBase64EncodedString:messageNode.iv];
                            NSData *decodedPayload = [EncodingTools dataWithBase64EncodedString:messageNode.encryptedPayload];
                         
                            EVP_CIPHER_CTX *ctx =EVP_CIPHER_CTX_new();
                            int outlen, rv;
                            unsigned char outbuf[decodedPayload.length];
                     
                            /* Select cipher */
                            EVP_DecryptInit_ex(ctx, EVP_aes_128_gcm(), NULL, NULL, NULL);
                            /* Set IV length, omit for 96 bits */
                            EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, (int)iv.length, NULL);
                            /* Specify key and IV */
                            EVP_DecryptInit_ex(ctx, NULL, NULL, key.bytes, iv.bytes);
                            EVP_CIPHER_CTX_set_padding(ctx,1);
                            /* Decrypt plaintext */
                            EVP_DecryptUpdate(ctx, outbuf, &outlen, decodedPayload.bytes, (int)decodedPayload.length);
                            /* Output decrypted block */
                           
                          if(auth) {
                            /* Set expected tag value. */
                            EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_TAG, (int)auth.length, auth.bytes);
                          }
                            /* Finalise: note get no output for GCM */
                            rv = EVP_DecryptFinal_ex(ctx, outbuf, &outlen);
                            
                            NSData *decdata = [[NSData alloc] initWithBytes:outbuf length:decodedPayload.length];
                            decrypted= [[NSString alloc] initWithData:decdata encoding:NSUTF8StringEncoding];
                            
                            EVP_CIPHER_CTX_free(ctx);
                                
                        }
                        
                    }
#endif
                    
                    if(messageNode.hasBody || messageNode.subject||decrypted)
                    {
                        NSString *ownNick;
                        //TODO if muc find own nick to see if echo
                        if(messageNode.type==kMessageGroupChatType)
                        {
                            ownNick = [[DataLayer sharedInstance] ownNickNameforMuc:messageNode.from forAccount:self.accountNo];
                        }
                        
                        if ([messageNode.type isEqualToString:kMessageGroupChatType]
                            && [messageNode.actualFrom isEqualToString:ownNick])
                        {
                            //this is just a muc echo
                        }
                        else
                        {
                            NSString *jidWithoutResource = [NSString stringWithFormat:@"%@@%@", self.username, self.domain ];
                            
                            BOOL unread=YES;
                            BOOL showAlert=YES;
                            if( [messageNode.from isEqualToString:jidWithoutResource] || messageNode.mamResult ) {
                                unread=NO;
                                showAlert=NO;
                            }
                            
                            NSString *body=messageNode.messageText;
                            if(decrypted) body=decrypted;
                            
                            NSString *messageType=nil;
                            if(!body  && messageNode.subject)
                            {
                                body =[NSString stringWithFormat:@"%@ changed the subject to: %@", messageNode.actualFrom, messageNode.subject];
                                messageType=kMessageTypeStatus;
                            }
                            
                            if(messageNode.oobURL)
                            {
                                messageType=kMessageTypeImage;
                                body=messageNode.oobURL; 
                            }
                            if(!body) body=@"";
                            
                            BOOL encrypted=NO;
                            if(decrypted) encrypted=YES;
                            
                            [[DataLayer sharedInstance] addMessageFrom:messageNode.from to:recipient
                                                            forAccount:_accountNo withBody:body
                                                          actuallyfrom:messageNode.actualFrom delivered:YES  unread:unread  serverMessageId:messageNode.idval
                                                           messageType:messageType
                                                       andOverrideDate:messageNode.delayTimeStamp
                                                             encrypted:encrypted
                                                        withCompletion:^(BOOL success) {
                                                              if(success)
                                                              {
                                                                  if(messageNode.requestReceipt
                                                                     && !messageNode.mamResult
                                                                     && ![messageNode.from isEqualToString:
                                                                          [NSString stringWithFormat:@"%@@%@", self.username, self.domain]]
                                                                     )
                                                                  {
                                                                      XMPPMessage *receiptNode = [[XMPPMessage alloc] init];
                                                                      [receiptNode.attributes setObject:messageNode.from forKey:@"to"];
                                                                      [receiptNode setXmppId:[[NSUUID UUID] UUIDString]];
                                                                      [receiptNode setReceipt:messageNode.idval];
                                                                      [self send:receiptNode];
                                                                  }
                                                                  
                                                                  [self.networkQueue addOperationWithBlock:^{
                                                                     
                                                                      if(![messageNode.from isEqualToString:
                                                                           [NSString stringWithFormat:@"%@@%@", self.username, self.domain]]) {
                                                                          [[DataLayer sharedInstance] addActiveBuddies:messageNode.from forAccount:self->_accountNo withCompletion:nil];
                                                                      } else  {
                                                                            [[DataLayer sharedInstance] addActiveBuddies:messageNode.to forAccount:self->_accountNo withCompletion:nil];
                                                                      }
                                                                      
                                                                      
                                                                      if(messageNode.from  ) {
                                                                          NSString* actuallyFrom= messageNode.actualFrom;
                                                                          if(!actuallyFrom) actuallyFrom=messageNode.from;
                                                                          
                                                                          NSString* messageText=messageNode.messageText;
                                                                          if(!messageText) messageText=@"";
                                                                          
                                                                          BOOL shouldRefresh = NO;
                                                                          if(messageNode.delayTimeStamp)  shouldRefresh =YES;
                                                                          
                                                                          NSArray *jidParts= [self.jid componentsSeparatedByString:@"/"];
                                                                          
                                                                          NSString *recipient;
                                                                          if([jidParts count]>1) {
                                                                              recipient= jidParts[0];
                                                                          }
                                                                          if(!recipient) recipient= _fulluser;
                                                                          
                                                                          
                                                                          NSDictionary* userDic=@{@"from":messageNode.from,
                                                                                                  @"actuallyfrom":actuallyFrom,
                                                                                                  @"messageText":body,
                                                                                                  @"to":messageNode.to?messageNode.to:recipient,
                                                                                                  @"accountNo":_accountNo,
                                                                                                  @"showAlert":[NSNumber numberWithBool:showAlert],
                                                                                                  @"shouldRefresh":[NSNumber numberWithBool:shouldRefresh],
                                                                                                  @"messageType":messageType?messageType:kMessageTypeText,
                                                                                                   @"muc_subject":messageNode.subject?messageNode.subject:@"",
                                                                                                  @"delayTimeStamp":messageNode.delayTimeStamp?messageNode.delayTimeStamp:@""
                                                                                                  };
                                                                          
                                                                          [[NSNotificationCenter defaultCenter] postNotificationName:kMonalNewMessageNotice object:self userInfo:userDic];
                                                                      }
                                                                  }];
                                                              }
                                                              else {
                                                                  DDLogVerbose(@"error adding message");
                                                              }
                                                              
                                                          }];
                            
                        }
                    }
                    
                    if(messageNode.avatarData)
                    {
                        
                        [[MLImageManager sharedInstance] setIconForContact:messageNode.actualFrom andAccount:_accountNo WithData:messageNode.avatarData];
                        
                    }
                    
                    if(messageNode.receivedID)
                    {
                        //save in DB
                        [[DataLayer sharedInstance] setMessageId:messageNode.receivedID received:YES];
                        
                        //Post notice
                        [[NSNotificationCenter defaultCenter] postNotificationName:kMonalMessageReceivedNotice object:self userInfo:@{kMessageId:messageNode.receivedID}];
                        
                    }
                  
                    
                    
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"]  isEqualToString:@"presence"])
                {
                    if(self.accountState>=kStateBound)
                        self.lastHandledInboundStanza=[NSNumber numberWithInteger: [self.lastHandledInboundStanza integerValue]+1];
                    ParsePresence* presenceNode= [[ParsePresence alloc]  initWithDictionary:stanzaToParse];
                    
                    NSString *recipient=presenceNode.to;
                    
                    if(!recipient)
                    {
                        recipient= _fulluser;
                    }
                    
                    
                    if([presenceNode.user isEqualToString:_fulluser]) {
                        //ignore self
                    }
                    else {
                        if([presenceNode.type isEqualToString:kpresencesSubscribe])
                        {
                            
                            dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_IPHONE
                                
                                NSString* messageString = [NSString  stringWithFormat:NSLocalizedString(@"Do you wish to allow %@ to add you to their contacts?", nil), presenceNode.from ];
                                RIButtonItem* cancelButton = [RIButtonItem itemWithLabel:NSLocalizedString(@"No", nil) action:^{
                                    [self rejectFromRoster:presenceNode.from];
                                    
                                }];
                                
                                RIButtonItem* yesButton = [RIButtonItem itemWithLabel:NSLocalizedString(@"Yes", nil) action:^{
                                    [self approveToRoster:presenceNode.from];
                                    [self addToRoster:presenceNode.from];
                                    
                                }];
                                
                                UIAlertView* alert =[[UIAlertView alloc] initWithTitle:@"Approve Contact" message:messageString cancelButtonItem:cancelButton otherButtonItems:yesButton, nil];
                                [alert show];
#else
                                [self.contactsVC showAuthRequestForContact:presenceNode.from  withCompletion:^(BOOL allowed) {
                                    
                                    if(allowed)
                                    {
                                        [self approveToRoster:presenceNode.from];
                                        [self addToRoster:presenceNode.from];
                                    } else {
                                        [self rejectFromRoster:presenceNode.from];
                                    }
                                    
                                }];
                                
#endif
                            });
                            
                        }
                        
                        if(presenceNode.MUC)
                        {
                            for (NSString* code in presenceNode.statusCodes) {
                                if([code isEqualToString:@"201"]) {
                                    //201- created and needs configuration
                                    //make instant room
                                    XMPPIQ *configNode = [[XMPPIQ alloc] initWithType:kiqSetType];
                                    [configNode setiqTo:presenceNode.from];
                                    [configNode setInstantRoom];
                                    [self send:configNode];
                                }
                            }
                            
                            if([presenceNode.type isEqualToString:kpresenceUnavailable])
                            {
                                //handle this differently later
                                return;
                            }
                            
                        }
                        
                        if(presenceNode.type ==nil)
                        {
                            DDLogVerbose(@"presence priority notice from %@", presenceNode.user);
                            
                            if((presenceNode.user!=nil) && ([[presenceNode.user stringByTrimmingCharactersInSet:
                                                              [NSCharacterSet whitespaceAndNewlineCharacterSet]] length]>0))
                            {
                                
                                
                                [[DataLayer sharedInstance] addContact:[presenceNode.user copy] forAccount:self->_accountNo fullname:@"" nickname:@"" withCompletion:^(BOOL success) {
                                    if(!success)
                                    {
                                        DDLogVerbose(@"Contact already in list");
                                    }
                                    else
                                    {
                                        DDLogVerbose(@"Contact not already in list");
                                    }
                                    
                                    DDLogVerbose(@" showing as online from presence");
                                    
                                    [[DataLayer sharedInstance] setOnlineBuddy:presenceNode forAccount:self->_accountNo];
                                    [[DataLayer sharedInstance] setBuddyState:presenceNode forAccount:self->_accountNo];
                                    [[DataLayer sharedInstance] setBuddyStatus:presenceNode forAccount:self->_accountNo];
                                    
                                    NSString* state=presenceNode.show;
                                    if(!state) state=@"";
                                    NSString* status=presenceNode.status;
                                    if(!status) status=@"";
                                    NSDictionary* userDic=@{kusernameKey: presenceNode.user,
                                                            kaccountNoKey:self->_accountNo,
                                                            kstateKey:state,
                                                            kstatusKey:status
                                                            };
                                    
                                    [[NSNotificationCenter defaultCenter] postNotificationName:kMonalContactOnlineNotice object:self userInfo:userDic];
                                    
                                }];
                                
                                if(!presenceNode.MUC) {
                                    // do not do this in the background
                                    
                                    __block  BOOL checkChange = YES;
                                    
                                    
#if TARGET_OS_IPHONE
                                    //TODO maybe not a good idea to do this. but bad to crash as well.  fix later.
                                    dispatch_sync(dispatch_get_main_queue(), ^{
                                        if([UIApplication sharedApplication].applicationState==UIApplicationStateBackground)
                                        {
                                            checkChange=NO;
                                        }
                                    });
                                    
#else
#endif
                                    
                                    if(checkChange)
                                    {
                                        //check for vcard change
                                        if(presenceNode.photoHash) {
                                            [[DataLayer sharedInstance]  contactHash:[presenceNode.user copy] forAccount:self->_accountNo withCompeltion:^(NSString *iconHash) {
                                                if([presenceNode.photoHash isEqualToString:iconHash])
                                                {
                                                    DDLogVerbose(@"photo hash is the  same");
                                                }
                                                else
                                                {
                                                    [[DataLayer sharedInstance]  setContactHash:presenceNode forAccount:self->_accountNo];
                                              
                                                    [self getVCard:presenceNode.user];
                                                }
                                                
                                            }];
                                            
                                        }
                                    }
                                    else
                                    {
                                        // just set and request when in foreground if needed
                                        [[DataLayer sharedInstance]  setContactHash:presenceNode  forAccount:self->_accountNo];
                                    }
                                }
                                else {
                                    
                                }
                                
                            }
                            else
                            {
                                DDLogError(@"ERROR: presence priority notice but no user name.");
                                
                            }
                        }
                        else if([presenceNode.type isEqualToString:kpresenceUnavailable])
                        {
                            if ([[DataLayer sharedInstance] setOfflineBuddy:presenceNode forAccount:self->_accountNo] ) {
                                NSDictionary* userDic=@{kusernameKey: presenceNode.user,
                                                        kaccountNoKey:self->_accountNo};
                                [self.networkQueue addOperationWithBlock: ^{
                                    
                                    [[NSNotificationCenter defaultCenter] postNotificationName:kMonalContactOfflineNotice object:self userInfo:userDic];
                                }];
                            }
                            
                        }
                    }
                    
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"stream:error"])
                {
                    [[NSNotificationCenter defaultCenter] postNotificationName:kXMPPError object:@[self, @"XMPP stream error"]];
                    
                    [self disconnectWithCompletion:^{
                        [self reconnect:5];
                    }];
                   
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"stream:stream"])
                {
                    //  ParseStream* streamNode= [[ParseStream alloc]  initWithDictionary:nextStanzaPos];
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"stream"] ||  [[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"stream:features"])
                {
                    ParseStream* streamNode= [[ParseStream alloc]  initWithDictionary:stanzaToParse];
                    
                    //perform logic to handle stream
                    if(streamNode.error)
                    {
                        return;
                        
                    }
                    
                    if(self.accountState<kStateLoggedIn )
                    {
                        
                        if(streamNode.callStartTLS &&  self->_SSL)
                        {
                            MLXMLNode* startTLS= [[MLXMLNode alloc] init];
                            startTLS.element=@"starttls";
                            [startTLS.attributes setObject:@"urn:ietf:params:xml:ns:xmpp-tls" forKey:@"xmlns"];
                            [self send:startTLS];
                            
                        }
                        
                        if ((self->_SSL && self->_startTLSComplete)
                            || (!self->_SSL && !self->_startTLSComplete)
                            || (self->_SSL && self->_oldStyleSSL))
                        {
                            //look at menchanisms presented
                            
                            if(streamNode.SASLX_OAUTH2 && self.oAuth)
                            {
                                NSString* saslplain=[EncodingTools encodeBase64WithString: [NSString stringWithFormat:@"\0%@\0%@",  self->_username, self.oauthAccount.accessToken.accessToken ]];
                                
                                MLXMLNode* saslXML= [[MLXMLNode alloc]init];
                                saslXML.element=@"auth";
                                [saslXML.attributes setObject: @"urn:ietf:params:xml:ns:xmpp-sasl"  forKey:@"xmlns"];
                                [saslXML.attributes setObject: @"X-OAUTH2"forKey: @"mechanism"];
                                [saslXML.attributes setObject: @"auth:service"forKey: @"oauth2"];
                                
                                [saslXML.attributes setObject:@"http://www.google.com/talk/protocol/auth" forKey: @"xmlns:auth"];
                                
                                saslXML.data=saslplain;
                                [self send:saslXML];
                                
                            }
                            else if (streamNode.SASLPlain)
                            {
                                NSString* saslplain=[EncodingTools encodeBase64WithString: [NSString stringWithFormat:@"\0%@\0%@",  self->_username, self->_password ]];
                                
                                MLXMLNode* saslXML= [[MLXMLNode alloc]init];
                                saslXML.element=@"auth";
                                [saslXML.attributes setObject: @"urn:ietf:params:xml:ns:xmpp-sasl"  forKey:@"xmlns"];
                                [saslXML.attributes setObject: @"PLAIN"forKey: @"mechanism"];
                                
                                
                                [saslXML.attributes setObject:@"http://www.google.com/talk/protocol/auth" forKey: @"xmlns:ga"];
                                [saslXML.attributes setObject:@"true" forKey: @"ga:client-uses-full-bind-result"];
                                
                                saslXML.data=saslplain;
                                [self send:saslXML];
                                
                            }
                            else
                                if(streamNode.SASLDIGEST_MD5)
                                {
                                    MLXMLNode* saslXML= [[MLXMLNode alloc]init];
                                    saslXML.element=@"auth";
                                    [saslXML.attributes setObject: @"urn:ietf:params:xml:ns:xmpp-sasl"  forKey:@"xmlns"];
                                    [saslXML.attributes setObject: @"DIGEST-MD5"forKey: @"mechanism"];
                                    
                                    [self send:saslXML];
                                }
                                else
                                {
                                    
                                    //no supported auth mechanism try legacy
                                    //[self disconnect];
                                    DDLogInfo(@"no auth mechanism. will try legacy auth");
                                    XMPPIQ* iqNode =[[XMPPIQ alloc] initWithElement:@"iq"];
                                    [iqNode getAuthwithUserName:self.username ];
                                    [self send:iqNode];
                                }
                        }
                        
                        
                    }
                    else
                    {
                        if(streamNode.supportsClientState)
                        {
                            self.supportsClientState=YES;
                        }
                        
                        if(streamNode.supportsSM3)
                        {
                            self.supportsSM3=YES;
                        } else {
                            [[DataLayer sharedInstance] resetContactsForAccount:_accountNo];
                        }
                        
                        if(streamNode.supportsRosterVer)
                        {
                            self.supportsRosterVersion=true;
                            
                        }
                        
                        //test if smacks is supported and allows resume
                        if(self.supportsSM3 && self.streamID) {
                            MLXMLNode *resumeNode=[[MLXMLNode alloc] initWithElement:@"resume"];
                            NSDictionary *dic=@{@"xmlns":@"urn:xmpp:sm:3",@"h":[NSString stringWithFormat:@"%@",self.lastHandledInboundStanza], @"previd":self.streamID };
                            
                            resumeNode.attributes=[dic mutableCopy];
                            self.resuming=YES;      //this is needed to distinguish a failed smacks resume and a failed smacks enable later on
                            
                            [self send:resumeNode];
                        }
                        else {
                            [self bindResource];
                        }
                        
                    }
                    
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"enabled"])
                {
                    
                    //save old unAckedStanzas queue before it is cleared
                    NSMutableArray *stanzas = self.unAckedStanzas;
                    
                    //init smacks state (this clears the unAckedStanzas queue)
                    [self initSM3];
                    
                    //save streamID if resume is supported
                    ParseEnabled* enabledNode= [[ParseEnabled alloc]  initWithDictionary:stanzaToParse];
                    if(enabledNode.resume) {
                        self.streamID=enabledNode.streamID;
                        self.streamExpireSeconds=enabledNode.max;
                    }
                    else {
                        self.streamID=nil;
                    }
                    
                    //persist these changes (streamID and initSM3)
                    [self persistState];
                    
                    //init session and query disco, roster etc.
                    [self initSession];
                    
                    //resend unacked stanzas saved above (this happens only if the server provides smacks support without resumption support)
                    [self.networkQueue addOperation:
                     [NSBlockOperation blockOperationWithBlock:^{
                        if(stanzas) {
                            for(NSDictionary *dic in stanzas) {
                                [self send:(MLXMLNode*)[dic objectForKey:kStanza]];
                                
                            }
                        }
                    }]];
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"r"] && self.supportsSM3 && self.accountState>=kStateBound)
                {
                    MLXMLNode *aNode=[[MLXMLNode alloc] initWithElement:@"a"];
                    NSDictionary *dic=@{@"xmlns": @"urn:xmpp:sm:3", @"h": [NSString stringWithFormat:@"%@", self.lastHandledInboundStanza]};
                    aNode.attributes=[dic mutableCopy];
                    [self send:aNode];
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"a"] && self.supportsSM3 && self.accountState>=kStateBound)
                {
                    ParseA* aNode=[[ParseA alloc] initWithDictionary:stanzaToParse];
                    self.lastHandledOutboundStanza=aNode.h;
                    
                    //remove acked messages
                    [self removeUnAckedMessagesLessThan:aNode.h];
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"resumed"])
                {
                    self.resuming=NO;
                    
                    //now we are bound again
                    self->_accountState=kStateBound;
                    [self postConnectNotification];
                    
                    //remove already delivered stanzas and resend the (still) unacked ones
                    ParseResumed* resumeNode= [[ParseResumed alloc]  initWithDictionary:stanzaToParse];
                    [self removeUnAckedMessagesLessThan:resumeNode.h];
                    [self sendUnAckedMessages];
                   
                    //parse features
                    self.usingCarbons2=NO; //ensure its done again 
                    [self parseFeatures];
                    
                    #if TARGET_OS_IPHONE
                    if(self.supportsPush)
                    {
                        [self enablePush];
                    }
                    #endif
                    
                    [self sendInitalPresence];
                    #ifndef DISABLE_OMEMO
                    [self setupSignal];
                    #endif
                    
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"failed"]) // stream resume failed
                {
                    
                    if(self.resuming)   //resume failed
                    {
                        [[DataLayer sharedInstance] resetContactsForAccount:_accountNo];
                        
                        self.resuming=NO;
                        
                        //invalidate stream id
                        self.streamID=nil;
                        [self persistState];
                        
                        //get h value, if server supports smacks revision 1.5.2
                        ParseFailed* failedNode= [[ParseFailed alloc]  initWithDictionary:stanzaToParse];
                        DDLogInfo(@"++++++++++++++++++++++++ failed resume: h=%@", failedNode.h);
                        [self removeUnAckedMessagesLessThan:failedNode.h];
                        
                        //if resume failed. bind like normal
                        [self bindResource];
                        
#if TARGET_OS_IPHONE
                        if(self.supportsPush && !self.pushEnabled)
                        {
                            [self enablePush];
                        }
#endif
                    }
                    else        //smacks enable failed
                    {
                        self.supportsSM3=NO;
                        
                      
                        //init session and query disco, roster etc.
                        [self initSession];
                        
                        //resend stanzas still in the outgoing queue and clear it afterwards
                        //this happens if the server has internal problems and advertises smacks support but ceases to enable it
                        //message duplicates are possible in this scenario, but that's better than dropping messages
                        [self.networkQueue addOperation:
                         [NSBlockOperation blockOperationWithBlock:^{
                            if(self.unAckedStanzas)
                            {
                                for(NSDictionary *dic in self.unAckedStanzas)
                                    [self send:(MLXMLNode*)[dic objectForKey:kStanza]];
                                
                                //clear queue afterwards (we don't want to repeat this)
                                [self.unAckedStanzas removeAllObjects];
                                
                                //persist these changes
                                [self persistState];
                            }
                        }]];
                    }
                    
                }
                
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"features"])
                {
                    
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"proceed"])
                {
                    ParseStream* streamNode= [[ParseStream alloc]  initWithDictionary:stanzaToParse];
                    //perform logic to handle proceed
                    if(!streamNode.error)
                    {
                        if(streamNode.startTLSProceed)
                        {
                            NSMutableDictionary *settings = [[NSMutableDictionary alloc] init];
                            
                            if(self.oAuth) {
                                //we only support oauth on gtalk
                                [settings setObject:[NSNull null] forKey:kCFStreamSSLPeerName];
                            }
                            else  {
                                [settings setObject:self->_domain forKey:kCFStreamSSLPeerName];
                            }
                            
                            if(self->_brokenServerSSL)
                            {
                                DDLogInfo(@"recovering from broken SSL implemtation limit to ss3-tl1");
                                [settings addEntriesFromDictionary:@{@"kCFStreamSSLLevel":@"kCFStreamSocketSecurityLevelTLSv1_0SSLv3"}];
                            }
                            else
                            {
                                [settings addEntriesFromDictionary:@{@"kCFStreamSSLLevel":@"kCFStreamSocketSecurityLevelTLSv1"}];
                            }
                            
                            if(self.selfSigned)
                            {
                                [settings  setObject:@NO forKey:kCFStreamSSLValidatesCertificateChain];
                            }
                            
                            if (CFReadStreamSetProperty((__bridge CFReadStreamRef)self->_iStream,
                                                        kCFStreamPropertySSLSettings, (__bridge CFTypeRef)settings) &&
                                CFWriteStreamSetProperty((__bridge CFWriteStreamRef)self->_oStream,
                                                         kCFStreamPropertySSLSettings, (__bridge CFTypeRef)settings))
                                
                            {
                                DDLogInfo(@"Set TLS properties on streams. Security level %@", [self->_iStream propertyForKey:NSStreamSocketSecurityLevelKey]);
                                
                            }
                            else
                            {
                                DDLogError(@"not sure.. Could not confirm Set TLS properties on streams.");
                                DDLogInfo(@"Set TLS properties on streams.security level %@", [self->_iStream propertyForKey:NSStreamSocketSecurityLevelKey]);
                            }
                            
                            [self startStream];
                            
                            self->_startTLSComplete=YES;
                        }
                    }
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"failure"])
                {
                    
                    ParseFailure* failure = [[ParseFailure alloc] initWithDictionary:stanzaToParse];
                    
                    NSString *message=failure.text;
                    if(failure.notAuthorized)
                    {
                        if(!message) message =@"Not Authorized. Please check your credentials.";
                    }
                    else  {
                        if(!message) message =@"There was a SASL error on the server.";
                    }
                    
                    [[NSNotificationCenter defaultCenter] postNotificationName:kXMPPError object:@[self, message]];
                    
                    
                    if(failure.saslError || failure.notAuthorized)
                    {
                        self->_loginError=YES;
                        [self disconnect];
                        //check for oauth
                        
                        if(self.oAuth) {
                            self.oauthAccount.oauthClient.desiredScope=[NSSet setWithArray:@[@"https://www.googleapis.com/auth/googletalk"]];
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [self.oauthAccount.oauthClient refreshAccessToken];
                            });
                        }
                        
                    }
                    
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"challenge"])
                {
                    ParseChallenge* challengeNode= [[ParseChallenge alloc]  initWithDictionary:stanzaToParse];
                    if(challengeNode.saslChallenge)
                    {
                        MLXMLNode* responseXML= [[MLXMLNode alloc]init];
                        responseXML.element=@"response";
                        [responseXML.attributes setObject: @"urn:ietf:params:xml:ns:xmpp-sasl"  forKey:@"xmlns"];
                        
                        
                        NSString* decoded=[[NSString alloc]  initWithData: (NSData*)[EncodingTools dataWithBase64EncodedString:challengeNode.challengeText] encoding:NSASCIIStringEncoding];
                        DDLogVerbose(@"decoded challenge to %@", decoded);
                        NSArray* parts =[decoded componentsSeparatedByString:@","];
                        
                        if([parts count]<2)
                        {
                            //this is a success message  from challenge
                            
                            NSArray* rspparts= [[parts objectAtIndex:0] componentsSeparatedByString:@"="];
                            if([[rspparts objectAtIndex:0] isEqualToString:@"rspauth"])
                            {
                                DDLogVerbose(@"digest-md5 success");
                                
                            }
                            
                        }
                        else{
                            
                            NSString* realm;
                            NSString* nonce;
                            
                            for(NSString* part in parts)
                            {
                                NSArray* split = [part componentsSeparatedByString:@"="];
                                if([split count]>1)
                                {
                                    if([split[0] isEqualToString:@"realm"]) {
                                        realm=[split[1]  substringWithRange:NSMakeRange(1, [split[1]  length]-2)] ;
                                    }
                                    
                                    if([split[0] isEqualToString:@"nonce"]) {
                                        nonce=[split[1]  substringWithRange:NSMakeRange(1, [split[1]  length]-2)] ;
                                    }
                                    
                                }
                            }
                            
                            if(!realm) realm=@"";
                            
                            NSData* cnonce_Data=[EncodingTools MD5: [NSString stringWithFormat:@"%d",arc4random()%100000]];
                            NSString* cnonce =[EncodingTools hexadecimalString:cnonce_Data];
                            
                            
                            //                if([password length]==0)
                            //                {
                            //                    if(theTempPass!=NULL)
                            //                        password=theTempPass;
                            //
                            //                }
                            
                            //  nonce=@"580F35C1AE408E7DA57DE4DEDC5B9CA7";
                            //    cnonce=@"B9E01AE3-29E5-4FE5-9AA0-72F99742428A";
                            
                            
                            // ****** digest stuff going on here...
                            NSString* X= [NSString stringWithFormat:@"%@:%@:%@", self.username, realm, self.password ];
                            DDLogVerbose(@"X: %@", X);
                            
                            NSData* Y = [EncodingTools MD5:X];
                            
                            // above is correct
                            
                            /*
                             NSString* A1= [NSString stringWithFormat:@"%@:%@:%@:%@@%@/%@",
                             Y,[nonce substringWithRange:NSMakeRange(1, [nonce length]-2)],cononce,account,domain,resource];
                             */
                            
                            //  if you have the authzid  here you need it below too but it wont work on som servers
                            // so best not include it
                            
                            NSString* A1Str=[NSString stringWithFormat:@":%@:%@",
                                             nonce,cnonce];
                            NSData* A1= [A1Str
                                         dataUsingEncoding:NSUTF8StringEncoding];
                            
                            NSMutableData *HA1data = [NSMutableData dataWithCapacity:([Y length] + [A1 length])];
                            [HA1data appendData:Y];
                            [HA1data appendData:A1];
                            DDLogVerbose(@" HA1data : %@",HA1data  );
                            
                            
                            //this hash is wrong..
                            NSData* HA1=[EncodingTools DataMD5:HA1data];
                            
                            //below is correct
                            
                            NSString* A2=[NSString stringWithFormat:@"AUTHENTICATE:xmpp/%@", realm];
                            DDLogVerbose(@"%@", A2);
                            NSData* HA2=[EncodingTools MD5:A2];
                            
                            NSString* KD=[NSString stringWithFormat:@"%@:%@:00000001:%@:auth:%@",
                                          [EncodingTools hexadecimalString:HA1], nonce,
                                          cnonce,
                                          [EncodingTools hexadecimalString:HA2]];
                            
                            // DDLogVerbose(@" ha1: %@", [self hexadecimalString:HA1] );
                            //DDLogVerbose(@" ha2: %@", [self hexadecimalString:HA2] );
                            
                            DDLogVerbose(@" KD: %@", KD );
                            NSData* responseData=[EncodingTools MD5:KD];
                            // above this is ok
                            NSString* response=[NSString stringWithFormat:@"username=\"%@\",realm=\"%@\",nonce=\"%@\",cnonce=\"%@\",nc=00000001,qop=auth,digest-uri=\"xmpp/%@\",response=%@,charset=utf-8",
                                                self.username,realm, nonce, cnonce, realm, [EncodingTools hexadecimalString:responseData]];
                            //,authzid=\"%@@%@/%@\"  ,account,domain, resource
                            
                            DDLogVerbose(@"  response :  %@", response);
                            NSString* encoded=[EncodingTools encodeBase64WithString:response];
                            
                            //                NSString* xmppcmd = [NSString stringWithFormat:@"<response xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>%@</response>", encoded]
                            //                [self talk:xmppcmd];
                            
                            responseXML.data=encoded;
                        }
                        
                        [self send:responseXML];
                        return;
                        
                    }
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"response"])
                {
                    
                }
                else  if([[stanzaToParse objectForKey:@"stanzaType"] isEqualToString:@"success"])
                {
                    ParseStream* streamNode= [[ParseStream alloc]  initWithDictionary:stanzaToParse];
                    //perform logic to handle proceed
                    if(!streamNode.error)
                    {
                        if(streamNode.SASLSuccess)
                        {
                            DDLogInfo(@"Got SASL Success");
                            
                            srand([[NSDate date] timeIntervalSince1970]);
                            
                            [self startStream];
                            self->_accountState=kStateLoggedIn;
                            self.connectedTime=[NSDate date];
                            self->_loggedInOnce=YES;
                            self->_loginStarted=NO;
                            self.loginStartTimeStamp=nil;
                            
                            
                        }
                    }
                }
                
                
            }];
            stanzaToParse=[self nextStanza];
        }
        
    }];
    
}

-(void) postConnectNotification
{
    NSString *accountName =[NSString stringWithFormat:@"%@@%@", self.username, self.domain];
    NSDictionary *dic =@{@"AccountNo":self.accountNo, @"AccountName":accountName};
    [[NSNotificationCenter defaultCenter] postNotificationName:kMLHasConnectedNotice object:dic];
    [[NSNotificationCenter defaultCenter] postNotificationName:kMonalAccountStatusChanged object:nil];
    
}


-(void) send:(MLXMLNode*) stanza
{
    if(!stanza) return;
    
    if(self.accountState>=kStateBound && self.supportsSM3 && self.unAckedStanzas)
    {
        [self.networkQueue addOperation:
         [NSBlockOperation blockOperationWithBlock:^{
            //only count stanzas, not nonzas
            if([stanza.element isEqualToString:@"iq"] || [stanza.element isEqualToString:@"message"] || [stanza.element isEqualToString:@"presence"])
            {
                DDLogVerbose(@"adding to unAckedStanzas %@: %@", self.lastOutboundStanza, stanza.XMLString);
                NSDictionary *dic =@{kStanzaID:[NSNumber numberWithInteger: [self.lastOutboundStanza integerValue]], kStanza:stanza};
                [self.unAckedStanzas addObject:dic];
                self.lastOutboundStanza=[NSNumber numberWithInteger:[self.lastOutboundStanza integerValue]+1];
                
                //persist these changes
                [self persistState];
            }
        }]];
    }
    
    [self.networkQueue addOperation:
     [NSBlockOperation blockOperationWithBlock:^{
        DDLogVerbose(@"adding to send %@", stanza.XMLString);
        [self->_outputQueue addObject:stanza];
        [self writeFromQueue];  // try to send if there is space
    }]];
}


#pragma mark messaging

-(void) sendMessage:(NSString*) message toContact:(NSString*) contact isMUC:(BOOL) isMUC isEncrypted:(BOOL) encrypt isUpload:(BOOL) isUpload andMessageId:(NSString *) messageId 
{
    XMPPMessage* messageNode =[[XMPPMessage alloc] init];
    [messageNode.attributes setObject:contact forKey:@"to"];
    [messageNode setXmppId:messageId ];
#ifndef DISABLE_OMEMO
    if(self.signalContext && !isMUC && encrypt) {
        
        NSArray *devices = [self.monalSignalStore allDeviceIdsForAddressName:contact];
        if(devices.count>0 ){
            
            NSData *messageBytes=[message dataUsingEncoding:NSUTF8StringEncoding];
            //aes encrypt message
            
            EVP_CIPHER_CTX *ctx =EVP_CIPHER_CTX_new();
            int outlen;
            unsigned char outbuf[messageBytes.length];
            unsigned char tag[16];
            
            //genreate key and iv
            
            unsigned char key[16];
            RAND_bytes(key, sizeof(key));
            
            unsigned char iv[16];
            RAND_bytes(iv, sizeof(iv));
            
            NSData *gcmKey = [[NSData alloc] initWithBytes:key length:16];
            
            NSData *gcmiv= [[NSData alloc] initWithBytes:iv length:16];
            ;
            
            NSMutableData *encryptedMessage;
            
            
            ctx = EVP_CIPHER_CTX_new();
            /* Set cipher type and mode */
            EVP_EncryptInit_ex(ctx, EVP_aes_128_gcm(), NULL, NULL, NULL);
            /* Set IV length if default 96 bits is not approp riate */
            EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, gcmiv.length, NULL);
            /* Initialise key and IV */
            EVP_EncryptInit_ex(ctx, NULL, NULL, gcmKey.bytes, gcmiv.bytes);
            EVP_CIPHER_CTX_set_padding(ctx,1);
            /* Encrypt plaintext */
            EVP_EncryptUpdate(ctx, outbuf, &outlen,messageBytes.bytes,messageBytes.length);
            
            encryptedMessage = [NSMutableData dataWithBytes:outbuf length:outlen];
            
            /* Finalise: note get no output for GCM */
            EVP_EncryptFinal_ex(ctx, outbuf, &outlen);
            
            
            /* Get tag */
            EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, 16, tag);
            [encryptedMessage appendBytes:tag length:16];
            
            EVP_CIPHER_CTX_free(ctx);
            
            
            MLXMLNode *encrypted =[[MLXMLNode alloc] initWithElement:@"encrypted"];
            [encrypted.attributes setObject:@"eu.siacs.conversations.axolotl" forKey:@"xmlns"];
            [messageNode.children addObject:encrypted];
            
            MLXMLNode *payload =[[MLXMLNode alloc] initWithElement:@"payload"];
            [payload setData:[EncodingTools encodeBase64WithData:encryptedMessage]];
            [encrypted.children addObject:payload];
            
            
            NSString *deviceid=[NSString stringWithFormat:@"%d",self.monalSignalStore.deviceid];
            MLXMLNode *header =[[MLXMLNode alloc] initWithElement:@"header"];
            [header.attributes setObject:deviceid forKey:@"sid"];
            [encrypted.children addObject:header];
            
            MLXMLNode *ivNode =[[MLXMLNode alloc] initWithElement:@"iv"];
            [ivNode setData:[EncodingTools encodeBase64WithData:gcmiv]];
            [header.children addObject:ivNode];
            
            
            [devices enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                NSNumber *device = (NSNumber *)obj;
                SignalAddress *address = [[SignalAddress alloc] initWithName:contact deviceId:device.integerValue];
                SignalSessionCipher *cipher = [[SignalSessionCipher alloc] initWithAddress:address context:self.signalContext];
                NSError *error;
                SignalCiphertext* deviceEncryptedKey=[cipher encryptData:gcmKey error:&error];
                
                MLXMLNode *keyNode =[[MLXMLNode alloc] initWithElement:@"key"];
                [keyNode.attributes setObject:[NSString stringWithFormat:@"%@",device] forKey:@"rid"];
                if(deviceEncryptedKey.type==SignalCiphertextTypePreKeyMessage)
                {
                    [keyNode.attributes setObject:@"1" forKey:@"prekey"];
                }
                
                [keyNode setData:[EncodingTools encodeBase64WithData:deviceEncryptedKey.data]];
                [header.children addObject:keyNode];
                
            }];
        }
    }
    else  {
#endif
        if(isUpload){
            [messageNode setOobUrl:message];
        } else  {
            [messageNode setBody:message];
        }
        
#ifndef DISABLE_OMEMO
    }
#endif
    
    if(isMUC)
    {
        [messageNode.attributes setObject:kMessageGroupChatType forKey:@"type"];
    } else  {
        [messageNode.attributes setObject:kMessageChatType forKey:@"type"];
        
        MLXMLNode *request =[[MLXMLNode alloc] initWithElement:@"request"];
        [request.attributes setObject:@"urn:xmpp:receipts" forKey:@"xmlns"];
        [messageNode.children addObject:request];
    }
    
    [self send:messageNode];
}


#pragma mark set connection attributes

-(void) cleanEnableCarbons
{
    NSMutableArray *toClean = [self.unAckedStanzas mutableCopy];
     NSMutableArray *toIterate = [self.unAckedStanzas copy];
    for(NSDictionary *dic in toIterate) {
       if([[dic objectForKey:kStanza] isKindOfClass:[XMPPIQ class]])
       {
           XMPPIQ *iq=[dic objectForKey:kStanza] ;
           if([[iq.attributes objectForKey:@"id"] isEqualToString:@"enableCarbons"])
           {
               [toClean removeObject:dic];
           }
       }
        
      }
    
    self.unAckedStanzas= toClean;
}

/**
 cleans out disco requests from unacked stanzas to prevent a loop
 */
-(void) cleanDisco
{
    NSMutableArray *toClean = [self.unAckedStanzas mutableCopy];
    NSMutableArray *toIterate = [self.unAckedStanzas copy];
    for(NSDictionary *dic in toIterate) {
        if([[dic objectForKey:kStanza] isKindOfClass:[XMPPIQ class]])
        {
            XMPPIQ *iq=[dic objectForKey:kStanza] ;
            MLXMLNode *query = [iq.children firstObject];
            
            if([[query.attributes objectForKey:@"xmlns"] isEqualToString:@"http://jabber.org/protocol/disco#info"])
            {
                [toClean removeObject:dic];
            }
        }
        
    }
    
    self.unAckedStanzas= toClean;
}

-(void) persistState
{
    
    //state dictionary
    NSMutableDictionary* values = [[NSMutableDictionary alloc] init];
    
    //collect smacks state
    [values setValue:self.lastHandledInboundStanza forKey:@"lastHandledInboundStanza"];
    [values setValue:self.lastHandledOutboundStanza forKey:@"lastHandledOutboundStanza"];
    [values setValue:self.lastOutboundStanza forKey:@"lastOutboundStanza"];
    [values setValue:[self.unAckedStanzas copy] forKey:@"unAckedStanzas"];
    [values setValue:self.streamID forKey:@"streamID"];
    if(self.streamExpireSeconds ) {
        [values setValue:self.streamExpireSeconds forKey:@"streamExpireSeconds"];
        [values setValue:[NSDate date] forKey:@"streamLastTime"];
    }
    [values setValue:[NSDate date] forKey:@"streamTime"];
    
    [values setValue:[self.serverFeatures copy] forKey:@"serverFeatures"];
    if(self.uploadServer) {
        [values setObject:self.uploadServer forKey:@"uploadServer"];
    }
    if(self.conferenceServer) {
        [values setObject:self.conferenceServer forKey:@"conferenceServer"];
    }
    
    if(self.supportsPush)
    {
        [values setObject:[NSNumber numberWithBool:self.supportsPush] forKey:@"supportsPush"];
    }
    
    if(self.supportsMam2)
    {
        [values setObject:[NSNumber numberWithBool:self.supportsMam2] forKey:@"supportsMAM"];
    }
    
    if(self.discoveredServices)
    {
     [values setObject:[self.discoveredServices copy] forKey:@"discoveredServices"];
    }
    
    //save state dictionary
    NSData *data =[NSKeyedArchiver archivedDataWithRootObject:values];
    [[NSUserDefaults standardUserDefaults] setObject:data forKey:[NSString stringWithFormat:@"stream_state_v1_%@",self.accountNo]];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    //debug output
    DDLogVerbose(@"persistState:\n\tlastHandledInboundStanza=%@,\n\tlastHandledOutboundStanza=%@,\n\tlastOutboundStanza=%@,\n\t#unAckedStanzas=%d%s,\n\tstreamID=%@\nstreaexpire=%@",
              self.lastHandledInboundStanza,
              self.lastHandledOutboundStanza,
              self.lastOutboundStanza,
              self.unAckedStanzas ? [self.unAckedStanzas count] : 0,
              self.unAckedStanzas ? "" : " (NIL)",
              self.streamID,
                 self.streamExpireSeconds
             
              );
}

-(void) readState
{
    NSData *data=[[NSUserDefaults standardUserDefaults] objectForKey:[NSString stringWithFormat:@"stream_state_v1_%@", self.accountNo]];
    if(data)
    {
        NSMutableDictionary* dic=(NSMutableDictionary *) [NSKeyedUnarchiver unarchiveObjectWithData:data];
        
        //collect smacks state
        self.lastHandledInboundStanza=[dic objectForKey:@"lastHandledInboundStanza"];
        self.lastHandledOutboundStanza=[dic objectForKey:@"lastHandledOutboundStanza"];
        self.lastOutboundStanza=[dic objectForKey:@"lastOutboundStanza"];
        NSArray *stanzas= [dic objectForKey:@"unAckedStanzas"];
        self.unAckedStanzas=[stanzas mutableCopy];
        self.streamID=[dic objectForKey:@"streamID"];
        self.streamExpireSeconds=[dic objectForKey:@"streamExpireSeconds"];
        
        NSDate *streamLastTime = [dic objectForKey:@"streamLastTime"];
        if(streamLastTime && self.streamExpireSeconds)
        {
            if([[NSDate date] timeIntervalSinceDate:streamLastTime]>self.streamExpireSeconds.integerValue)
            {
                self.streamID=nil;
                self.streamExpireSeconds=nil;
            }
        }
        
        self.serverFeatures = [dic objectForKey:@"serverFeatures"];
        self.discoveredServices=[dic objectForKey:@"discoveredServices"];
        
        
        self.uploadServer= [dic objectForKey:@"uploadServer"];
        if(self.uploadServer)
        {
            self.supportsHTTPUpload=YES;
        }
        self.conferenceServer = [dic objectForKey:@"conferenceServer"];
        
        if([dic objectForKey:@"supportsPush"])
        {
            NSNumber *pushNumber = [dic objectForKey:@"supportsPush"];
            self.supportsPush = pushNumber.boolValue;
        }
        
        if([dic objectForKey:@"supportsMAM"])
        {
            NSNumber *mamNumber = [dic objectForKey:@"supportsMAM"];
            self.supportsMam2 = mamNumber.boolValue;
        }
        
        //debug output
        DDLogDebug(@"readState:\n\tlastHandledInboundStanza=%@,\n\tlastHandledOutboundStanza=%@,\n\tlastOutboundStanza=%@,\n\t#unAckedStanzas=%d%s,\n\tstreamID=%@",
                   self.lastHandledInboundStanza,
                   self.lastHandledOutboundStanza,
                   self.lastOutboundStanza,
                   self.unAckedStanzas ? [self.unAckedStanzas count] : 0,
                   self.unAckedStanzas ? "" : " (NIL)",
                   self.streamID
                   );
        if(self.unAckedStanzas)
            for(NSDictionary *dic in self.unAckedStanzas)
                DDLogDebug(@"readState unAckedStanza %@: %@", [dic objectForKey:kStanzaID], ((MLXMLNode*)[dic objectForKey:kStanza]).XMLString);
    }
}

-(void) initSM3
{
    //initialize smacks state
    self.lastHandledInboundStanza=[NSNumber numberWithInteger:0];
    self.lastHandledOutboundStanza=[NSNumber numberWithInteger:0];
    self.lastOutboundStanza=[NSNumber numberWithInteger:0];
    self.unAckedStanzas=[[NSMutableArray alloc] init];
    self.streamID=nil;
    self.streamExpireSeconds=nil;
    DDLogDebug(@"initSM3 done");
}

-(void) bindResource
{
    XMPPIQ* iqNode =[[XMPPIQ alloc] initWithType:kiqSetType];
    [iqNode setBindWithResource:_resource];
    [self send:iqNode];
    
    //now the app is initialized and the next smacks resume will have full disco and presence state information
    self.hasDiscoAndRoster=YES;
}

-(void) disconnectToResumeWithCompletion:(void (^)(void))completion
{
    [self closeSocket]; // just closing socket to simulate a unintentional disconnect
    [self.networkQueue addOperationWithBlock:^{
        [self resetValues];
        if(completion) completion();
    }];
}

-(void) queryDisco
{
    if(self.discoveredServices) return;
    
    XMPPIQ* discoItems =[[XMPPIQ alloc] initWithType:kiqGetType];
    [discoItems setiqTo:_domain];
    MLXMLNode* items = [[MLXMLNode alloc] initWithElement:@"query"];
    [items setXMLNS:@"http://jabber.org/protocol/disco#items"];
    [discoItems.children addObject:items];
    [self send:discoItems];
    
    XMPPIQ* discoInfo =[[XMPPIQ alloc] initWithType:kiqGetType];
    [discoInfo setiqTo:_domain];
    [discoInfo setDiscoInfoNode];
    [self send:discoInfo];

}


-(void) sendInitalPresence
{
    XMPPPresence* presence=[[XMPPPresence alloc] initWithHash:_versionHash];
    [presence setPriority:self.priority];
    if(self.statusMessage) [presence setStatus:self.statusMessage];
    if(self.awayState) [presence setAway];
    if(!self.visibleState) [presence setInvisible];
    
    [self send:presence];
}

-(void) fetchRoster
{
    XMPPIQ* roster=[[XMPPIQ alloc] initWithType:kiqGetType];
    NSString *rosterVer;
    if(self.supportsRosterVersion)
    {
        rosterVer=@""; //TODO fetch proper ver from db
    }
    [roster setRosterRequest:rosterVer];
    
    [self send:roster];
}


-(void) initSession
{
    [_contactsVC clearContactsForAccount:_accountNo];
 
    //now we are bound
    _accountState=kStateBound;
    [self postConnectNotification];
    
    XMPPIQ* sessionQuery= [[XMPPIQ alloc] initWithType:kiqSetType];
    MLXMLNode* session = [[MLXMLNode alloc] initWithElement:@"session"];
    [session setXMLNS:@"urn:ietf:params:xml:ns:xmpp-session"];
    [sessionQuery.children addObject:session];
    [self send:sessionQuery];
    
    [self queryDisco];
    [self fetchRoster];
    [self sendInitalPresence];

#ifndef DISABLE_OMEMO
    [self setupSignal];
#endif
    
if(!self.supportsSM3)
    {
        //send out messages still in the queue, even if smacks is not supported this time
        [self sendUnAckedMessages];
        
        //clear queue afterwards (we don't want to repeat this)
        [self.networkQueue addOperation:
         [NSBlockOperation blockOperationWithBlock:^{
            if(self.unAckedStanzas)
            {
                [self.unAckedStanzas removeAllObjects];
                [self persistState];
            }
        }]];
    }
}

-(void) setStatusMessageText:(NSString*) message
{
    if([message length]>0)
        self.statusMessage=message;
    else
        message=nil;
    
    XMPPPresence* node =[[XMPPPresence alloc] initWithHash:self.versionHash];
    if(message)[node setStatus:message];
    
    if(self.awayState) [node setAway];
    
    [self send:node];
}

-(void) setAway:(BOOL) away
{
    self.awayState=away;
    XMPPPresence* node =[[XMPPPresence alloc] initWithHash:self.versionHash];
    if(away) {
        [node setAway];
    }
    else {
        [node setAvailable];
    }
    
    if(self.statusMessage) [node setStatus:self.statusMessage];
    [self send:node];
    

    
}

-(void) setVisible:(BOOL) visible
{
    self.visibleState=visible;
    XMPPPresence* node =[[XMPPPresence alloc] initWithHash:self.versionHash];
    if(!visible)
        [node setInvisible];
    else
    {
        if(self.statusMessage) [node setStatus:self.statusMessage];
        if(self.awayState) [node setAway];
    }
    
    [self send:node];
}

-(void) updatePriority:(NSInteger) priority
{
    self.priority=priority;
    
    XMPPPresence* node =[[XMPPPresence alloc] initWithHash:self.versionHash];
    [node setPriority:priority];
    [self send:node];
    
}

#ifndef DISABLE_OMEMO
#pragma mark OMEMO

-(void) setupSignal
{
    self.monalSignalStore = [[MLSignalStore alloc] initWithAccountId:_accountNo];
    
    //signal store
    SignalStorage *signalStorage = [[SignalStorage alloc] initWithSignalStore:self.monalSignalStore];
    //signal context
    self.signalContext= [[SignalContext alloc] initWithStorage:signalStorage];
    //signal helper
    SignalKeyHelper *signalHelper = [[SignalKeyHelper alloc] initWithContext:self.signalContext];
    
    if(self.monalSignalStore.deviceid==0)
    {
        self.monalSignalStore.deviceid=[signalHelper generateRegistrationId];
        
        self.monalSignalStore.identityKeyPair= [signalHelper generateIdentityKeyPair];
        self.monalSignalStore.signedPreKey= [signalHelper generateSignedPreKeyWithIdentity:self.monalSignalStore.identityKeyPair signedPreKeyId:1];
        self.monalSignalStore.preKeys= [signalHelper generatePreKeysWithStartingPreKeyId:0 count:20];
        
        [self.monalSignalStore saveValues];
    }
    
    [self sendOMEMODevice];
    [self sendOMEMOBundle];
}

-(void) sendOMEMODevice {
    NSString *deviceid=[NSString stringWithFormat:@"%d",self.monalSignalStore.deviceid];
    XMPPIQ *signalDevice = [[XMPPIQ alloc] initWithType:kiqSetType];
    [signalDevice publishDevice:deviceid];
    [self send:signalDevice];
}

-(void) sendOMEMOBundle
{
    NSString *deviceid=[NSString stringWithFormat:@"%d",self.monalSignalStore.deviceid];
    XMPPIQ *signalKeys = [[XMPPIQ alloc] initWithType:kiqSetType];
    [signalKeys publishKeys:@{@"signedPreKeyPublic":self.monalSignalStore.signedPreKey.keyPair.publicKey, @"signedPreKeySignature":self.monalSignalStore.signedPreKey.signature, @"identityKey":self.monalSignalStore.identityKeyPair.publicKey, @"signedPreKeyId": [NSString stringWithFormat:@"%d",self.monalSignalStore.signedPreKey.preKeyId]} andPreKeys:self.monalSignalStore.preKeys withDeviceId:deviceid];
    [signalKeys.attributes setValue:[NSString stringWithFormat:@"%@/%@",_fulluser, _resource ] forKey:@"from"];
    [self send:signalKeys];
}

-(void) queryOMEMOBundleFrom:(NSString *) jid andDevice:(NSString *) deviceid
{
    XMPPIQ* query2 =[[XMPPIQ alloc] initWithId:[[NSUUID UUID] UUIDString] andType:kiqGetType];
    [query2 setiqTo:jid];
    [query2 requestBundles:deviceid]; //[NSString stringWithFormat:@"%@", devicenum]
    [self send:query2];
}

-(void) queryOMEMODevicesFrom:(NSString *) jid
{
    XMPPIQ* query =[[XMPPIQ alloc] initWithId:[[NSUUID UUID] UUIDString] andType:kiqGetType];
    [query setiqTo:jid];
    [query requestDevices];
    [self send:query];

}
#endif

#pragma mark vcard

-(void) getVcards
{
    for (NSDictionary *dic in self.rosterList)
    {
        [[DataLayer sharedInstance] contactForUsername:[dic objectForKey:@"jid"] forAccount:self.accountNo withCompletion:^(NSArray * result) {
            
            NSDictionary *row = result.firstObject;
            if (((NSString *)[row objectForKey:@"raw_full"]).length==0)
            {
                [self getVCard:[dic objectForKey:@"jid"]];
            }
            
        }];
    }
    
}

-(void)getVCard:(NSString *) user
{
    XMPPIQ* iqVCard= [[XMPPIQ alloc] initWithType:kiqGetType];
    [iqVCard getVcardTo:user];
    [self send:iqVCard];
}

#pragma mark query info

-(NSString*)getVersionString
{
    // We may need this later
    NSString* unhashed=[NSString stringWithFormat:@"client/phone//Monal %@<%@", [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"], [XMPPIQ featuresString]];
        
    NSData* hashed;
    //<http://jabber.org/protocol/offline<
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    NSData *stringBytes = [unhashed dataUsingEncoding: NSUTF8StringEncoding]; /* or some other encoding */
    if (CC_SHA1([stringBytes bytes], (UInt32)[stringBytes length], digest)) {
        hashed =[NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
    }
    
    NSString* hashedBase64= [EncodingTools encodeBase64WithData:hashed];
    
    DDLogVerbose(@"ver string: unhashed %@, hashed %@, hashed-64 %@", unhashed, hashed, hashedBase64);
    
    
    return hashedBase64;
    
}


-(void) getServiceDetails
{
    if(_hasRequestedServerInfo)
        return;  // no need to call again on disconnect
    
    if(!_discoveredServices)
    {
        DDLogInfo(@"no discovered services");
        return;
    }
    
    for (NSDictionary *item in _discoveredServices)
    {
        XMPPIQ* discoInfo =[[XMPPIQ alloc] initWithType:kiqGetType];
        NSString* jid =[item objectForKey:@"jid"];
        if(jid)
        {
            [discoInfo setiqTo:jid];
            [discoInfo setDiscoInfoNode];
            [self send:discoInfo];
            
            _hasRequestedServerInfo=YES;
        } else
        {
            DDLogError(@"no jid on info");
        }
    }
    
    
}

-(void) discoverService:(NSString *) node
{
    XMPPIQ* discoInfo =[[XMPPIQ alloc] initWithType:kiqGetType];
    [discoInfo setiqTo:node];
    [discoInfo setDiscoInfoNode];
    [self send:discoInfo];
}


#pragma mark HTTP upload

-(void) requestHTTPSlotWithParams:(NSDictionary *)params andCompletion:(void(^)(NSString *url,  NSError *error)) completion
{
    NSString *uuid = [[NSUUID UUID] UUIDString];
    XMPPIQ* httpSlotRequest =[[XMPPIQ alloc] initWithId:uuid andType:kiqGetType];
    [httpSlotRequest setiqTo:self.uploadServer];
    NSData *data= [params objectForKey:kData];
    NSNumber *size=[NSNumber numberWithInteger: data.length];
    
    NSMutableDictionary *iqParams =[NSMutableDictionary dictionaryWithDictionary:params];
    [iqParams setObject:uuid forKey:kId];
    [iqParams setObject:completion forKey:kCompletion];
    
    if(!self.httpUploadQueue)
    {
        self.httpUploadQueue = [[NSMutableArray alloc] init];
    }
    
    [self.httpUploadQueue addObject:iqParams];
    [httpSlotRequest httpUploadforFile:[params objectForKey:kFileName] ofSize:size andContentType:[params objectForKey:kContentType]];
    [self send:httpSlotRequest];
}

#pragma mark client state
-(void) setClientActive
{
    MLXMLNode *activeNode =[[MLXMLNode alloc] initWithElement:@"active" ];
    [activeNode setXMLNS:@"urn:xmpp:csi:0"];
    [self send:activeNode];
}

-(void) setClientInactive
{
    MLXMLNode *activeNode =[[MLXMLNode alloc] initWithElement:@"inactive" ];
    [activeNode setXMLNS:@"urn:xmpp:csi:0"];
    [self send:activeNode];
}

#pragma mark Message archive


-(void) setMAMPrefs:(NSString *) preference
{
    XMPPIQ* query =[[XMPPIQ alloc] initWithId:[[NSUUID UUID] UUIDString] andType:kiqSetType];
    [query updateMamArchivePrefDefault:preference];
    [self send:query];
}


-(void) getMAMPrefs
{
    XMPPIQ* query =[[XMPPIQ alloc] initWithId:[[NSUUID UUID] UUIDString] andType:kiqGetType];
    [query mamArchivePref];
    [self send:query];
}


-(void) setMAMQueryFromStart:(NSDate *) startDate toDate:(NSDate *) endDate  andJid:(NSString *)jid
{
    XMPPIQ* query =[[XMPPIQ alloc] initWithId:[[NSUUID UUID] UUIDString] andType:kiqSetType];
    [query setMAMQueryFromStart:startDate toDate:endDate andJid:jid];
    [self send:query];
}

-(void) setMAMQueryFromStart:(NSDate *) startDate after:(NSString *) after  andJid:(NSString *)jid
{
    XMPPIQ* query =[[XMPPIQ alloc] initWithId:[[NSUUID UUID] UUIDString] andType:kiqSetType];
    [query setMAMQueryFromStart:startDate after:after andJid:jid];
    [self send:query];
}

#pragma mark  MUC

-(void) getConferenceRooms
{
    if(_conferenceServer && !_roomList)
    {
        [self discoverService:_conferenceServer];
    }
    else
    {
        if(!_conferenceServer) DDLogInfo(@"no conference server discovered");
        if(_roomList){
            [[NSNotificationCenter defaultCenter] postNotificationName: kMLHasRoomsNotice object: self];
        }
    }
}


-(void) joinRoom:(NSString*)room withNick:(NSString*)nick andPassword:(NSString *)password
{
    XMPPPresence* presence =[[XMPPPresence alloc] init];
    NSArray* parts =[room componentsSeparatedByString:@"@"];
    if([parts count]>1)
    {
        [presence joinRoom:[parts objectAtIndex:0] withPassword:password onServer:[parts objectAtIndex:1] withName:nick];
    }
    else{
        [presence joinRoom:room withPassword:password onServer:_conferenceServer withName:nick];
    }
    [self send:presence];
}

-(void) leaveRoom:(NSString*) room
{
    XMPPPresence* presence =[[XMPPPresence alloc] init];
    [presence leaveRoom:room onServer:nil withName:_username];
    [self send:presence];
}


#pragma mark- XMPP add and remove contact
-(void) removeFromRoster:(NSString*) contact
{
    XMPPIQ* iq = [[XMPPIQ alloc] initWithType:kiqSetType];
    [iq setRemoveFromRoster:contact];
    [self send:iq];
    
    XMPPPresence* presence =[[XMPPPresence alloc] init];
    [presence unsubscribeContact:contact];
    [self send:presence];
    
    
    XMPPPresence* presence2 =[[XMPPPresence alloc] init];
    [presence2 unsubscribedContact:contact];
    [self send:presence2];
    
}

-(void) rejectFromRoster:(NSString*) contact
{
    XMPPPresence* presence2 =[[XMPPPresence alloc] init];
    [presence2 unsubscribedContact:contact];
    [self send:presence2];
}


-(void) addToRoster:(NSString*) contact
{
    XMPPPresence* presence =[[XMPPPresence alloc] init];
    [presence subscribeContact:contact];
    [self send:presence];
    
    
}

-(void) approveToRoster:(NSString*) contact
{
    
    XMPPPresence* presence2 =[[XMPPPresence alloc] init];
    [presence2 subscribedContact:contact];
    [self send:presence2];
}

#pragma mark - Jingle calls
-(void)call:(NSDictionary*) contact
{
    if(self.jingle) return;
    self.jingle=[[jingleCall alloc] init];
    self.jingle.me=[NSString stringWithFormat:@"%@/%@", self.fulluser, self.resource];
    
    NSArray* resources= [[DataLayer sharedInstance] resourcesForContact:[contact objectForKey:@"buddy_name"]];
    if([resources count]>0)
    {
        //TODO selct resource action sheet?
        XMPPIQ* jingleiq =[self.jingle initiateJingleTo:[contact objectForKey:@"buddy_name" ] withId:[[NSUUID UUID] UUIDString] andResource:[[resources objectAtIndex:0] objectForKey:@"resource"]];
        [self send:jingleiq];
    }
}

-(void)hangup:(NSDictionary*) contact
{
    XMPPIQ* jingleiq =[self.jingle terminateJinglewithId:[[NSUUID UUID] UUIDString]];
    [self send:jingleiq];
    [self.jingle rtpDisconnect];
    self.jingle=nil;
}

-(void)acceptCall:(NSDictionary*) userInfo
{
    XMPPIQ* node =[self.jingle acceptJingleTo:[userInfo objectForKey:@"user"] withId:[[NSUUID UUID] UUIDString]  andResource:[userInfo objectForKey:@"resource"]];
    [self send:node];
}


-(void)declineCall:(NSDictionary*) userInfo
{
    XMPPIQ* jingleiq =[self.jingle rejectJingleTo:[userInfo objectForKey:@"user"] withId:[[NSUUID UUID] UUIDString] andResource:[userInfo objectForKey:@"resource"]];
    [self send:jingleiq];
    [self.jingle rtpDisconnect];
    self.jingle=nil;
}



#pragma mark - nsstream delegate

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode
{
    DDLogVerbose(@"Stream has event");
    
    if(stream!=_iStream && stream!=_oStream)
    {
        DDLogVerbose(@"event from stale stream. This should not happen. Cleaning up and reconnecting.");
        [self disconnectWithCompletion:^{
            [self reconnect];
        }];
        return;
    }
    
    switch(eventCode)
    {
        case NSStreamEventOpenCompleted:
        {
            DDLogVerbose(@"Stream open completed");
            
        }
            //for writing
        case NSStreamEventHasSpaceAvailable:
        {
            [self.networkQueue addOperationWithBlock: ^{
                self->_streamHasSpace=YES;
                
                DDLogVerbose(@"Stream has space to write");
                [self writeFromQueue];
            }];
            break;
        }
            
            //for reading
        case  NSStreamEventHasBytesAvailable:
        {
            DDLogVerbose(@"Stream has bytes to read");
            [self.networkQueue addOperationWithBlock: ^{
                [self readToBuffer];
            }];
            
            break;
        }
            
        case NSStreamEventErrorOccurred:
        {
            NSError* st_error= [stream streamError];
            DDLogError(@"Stream error code=%ld domain=%@   local desc:%@ ",(long)st_error.code,st_error.domain,  st_error.localizedDescription);
            
            NSString *message =st_error.localizedDescription;
            
//            SecTrustRef trust = (__bridge SecTrustRef)[_iStream propertyForKey:kCFStreamPropertySSLPeerTrust];
//
//            SecCertificateRef cert=SecTrustGetCertificateAtIndex( trust,  0);

            switch(st_error.code)
            {
                case errSSLXCertChainInvalid: {
                    message = @"SSL Error: Certificate chain is invalid";
                    break;
                }
                    
                case errSSLUnknownRootCert: {
                    message = @"SSL Error: Unknown root certificate";
                    break;
                }
                    
                case errSSLCertExpired: {
                    message = @"SSL Error: Certificate expired";
                    break;
                }
                    
                case errSSLHostNameMismatch: {
                    message = @"SSL Error: Host name mismatch";
                    break;
                }
                    
            }
            
            [[NSNotificationCenter defaultCenter] postNotificationName:kXMPPError object:@[self, message, st_error]];
            
            //everythign comes twice. just use the input stream
            if(stream==_oStream){
                return;
            }
            
            if(_loggedInOnce)
            {
                DDLogInfo(@" stream error calling reconnect for account that logged in once before");
                [self disconnectWithCompletion:^{
                    [self reconnect:5];
                }];
                return;
            }
            
            
            if(st_error.code==2 )// operation couldnt be completed // socket not connected
            {
                [self disconnectWithCompletion:^{
                    [self reconnect:5];
                }];
                return;
            }
            
            
            if(st_error.code==60)// could not complete operation
            {
                [self disconnectWithCompletion:^{
                    [self reconnect:5];
                }];
                return;
            }
            
            if(st_error.code==64)// Host is down
            {
                [self disconnectWithCompletion:^{
                    [self reconnect:5];
                }];
                return;
            }
            
            
            
            if(st_error.code==-9807)// Could not complete operation. SSL probably
            {
                [self disconnect];
                return;
            }
            
            if(st_error.code==-9820)// Could not complete operation. SSL broken on server
            {
                DDLogInfo(@"setting broken ssl on server. retrying");
                _brokenServerSSL=YES;
                _loginStarted=NO;
                _accountState=kStateReconnecting;
                [self reconnect:0];
                
                return;
            }
               
               
               DDLogInfo(@"unhandled stream error");
              
            
            break;
            
        }
        case NSStreamEventNone:
        {
            DDLogVerbose(@"Stream event none");
            break;
            
        }
            
            
        case NSStreamEventEndEncountered:
        {
            if(_loggedInOnce)
            {
                DDLogInfo(@"%@ Stream end encoutered.. reconnecting.", [stream class] );
               _loginStarted=NO;
                [self disconnectWithCompletion:^{
                    self->_accountState=kStateReconnecting;
                    [self reconnect:5];
                }];
                
            }
            else  if(self.oauthAccount)
            {
                //allow failure to process an oauth to be refreshed
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5ull * NSEC_PER_SEC), dispatch_get_main_queue(),  ^{
                    DDLogInfo(@"%@ Stream end encoutered.. on oauth acct. Wait for refresh.", [stream class] );
                    if(self->_accountState<kStateHasStream) {
                        [self disconnectWithCompletion:^{
                            [self reconnect:5];
                        }];
                    } else  {
                        DDLogVerbose(@"already connected/connecting .doing nothimg");
                    }
                });
            }
            
            
            break;
            
        }
            
    }
    
}

#pragma mark network I/O
-(void) writeFromQueue
{
    if(!_streamHasSpace)
    {
        DDLogVerbose(@"no space to write. returning. ");
        return;
    }
    
    BOOL requestAck=NO;
    for(MLXMLNode* node in _outputQueue)
    {
        if (!_connectedTime && self.explicitLogout) break;
        DDLogVerbose(@"iterating output ");
        BOOL success=[self writeToStream:node.XMLString];
        if(success) {
            if([node isKindOfClass:[XMPPMessage class]])
            {
                XMPPMessage *messageNode = (XMPPMessage *) node;
                NSDictionary *dic =@{kMessageId:messageNode.xmppId};
                [[NSNotificationCenter defaultCenter] postNotificationName: kMonalSentMessageNotice object:self userInfo:dic];
                
            }
            else if([node isKindOfClass:[XMPPIQ class]])
            {
                XMPPIQ *iq = (XMPPIQ *)node;
                if([iq.children count]>0)
                {
                    MLXMLNode *child =[iq.children objectAtIndex:0];
                    if ([[child element] isEqualToString:@"ping"])
                    {
                        [self setPingTimerForID:[iq.attributes objectForKey:@"id"]];
                    }
                }
            }
        }
        //only react to stanzas, not nonzas
        if(success && ([node.element isEqualToString:@"iq"] || [node.element isEqualToString:@"message"] || [node.element isEqualToString:@"presence"])) {
            requestAck=YES;
        }
    }
    
    DDLogVerbose(@"removing all objs from output ");
    [_outputQueue removeAllObjects];
    
    if(self.accountState>=kStateBound && self.supportsSM3 && requestAck)
    {
        DDLogVerbose(@"requesting smacks ack...");
        MLXMLNode* rNode =[[MLXMLNode alloc] initWithElement:@"r"];
        NSDictionary *dic=@{@"xmlns":@"urn:xmpp:sm:3"};
        rNode.attributes =[dic mutableCopy];
        [self send:rNode];
    } else  {
        DDLogVerbose(@"NOT requesting smacks ack...");
    }
}

-(BOOL) writeToStream:(NSString*) messageOut
{
    if(!messageOut) {
        DDLogVerbose(@" tried to send empty message. returning");
        return NO;
    }
    //_streamHasSpace=NO; // triggers more has space messages
    
    //we probably want to break these into chunks
   // DDLogVerbose(@"sending: %@ ", messageOut);
    const uint8_t * rawstring = (const uint8_t *)[messageOut UTF8String];
    NSInteger len= strlen((char*)rawstring);
   // DDLogVerbose(@"size : %ld",(long)len);
    if([_oStream write:rawstring maxLength:len]!=-1)
    {
       // DDLogVerbose(@"done writing ");
        return YES;
    }
    else
    {
        NSError* error= [_oStream streamError];
        DDLogVerbose(@"sending: failed with error %ld domain %@ message %@",(long)error.code, error.domain, error.userInfo);
    }
    
    return NO;
}

-(void) readToBuffer
{
    
    if(![_iStream hasBytesAvailable])
    {
        DDLogVerbose(@"no bytes  to read");
        return;
    }
    
    uint8_t* buf=malloc(kXMPPReadSize);
    NSInteger len = 0;
    
    len = [_iStream read:buf maxLength:kXMPPReadSize];
    DDLogVerbose(@"done reading %ld", (long)len);
    if(len>0) {
        NSData* data = [NSData dataWithBytes:(const void *)buf length:len];
      //  DDLogVerbose(@" got raw string %s ", buf);
        if(data)
        {
            // DDLogVerbose(@"waiting on net read queue");
            [self.networkQueue addOperation:[NSBlockOperation blockOperationWithBlock:^{
                // DDLogVerbose(@"got net read queue");
                NSString* inputString=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if(inputString) {
                    [self->_inputBuffer appendString:inputString];
                }
                else {
                    DDLogError(@"got data but not string");
                }
            }]];
            
        }
        free(buf);
    }
    else
    {
        free(buf);
        return;
    }
    
    
    [self processInput];
    
}

#pragma mark DNS



-(void) enablePush
{
    if(self.accountState>=kStateBound && [self.pushNode length]>0 && [self.pushSecret length]>0 && self.supportsPush)
        //TODO there is a race condition on how this is called when fisrt logging in.
    {
        DDLogInfo(@"ENABLING PUSH: %@ < %@", self.pushNode, self.pushSecret);
        XMPPIQ* enable =[[XMPPIQ alloc] initWithType:kiqSetType];
        [enable setPushEnableWithNode:self.pushNode andSecret:self.pushSecret];
        [self send:enable];
        self.pushEnabled=YES;
    }
    else
        DDLogInfo(@" NOT enabling push: %@ < %@", self.pushNode, self.pushSecret);
}

@end
