#import "TGCallSession.h"

#import <LegacyComponents/LegacyComponents.h>

#import <libkern/OSAtomic.h>

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MTProtoKit/MTProtoKit.h>

#import "TGAppDelegate.h"
#import "TGTelegramNetworking.h"
#import "TGTelegraph.h"
#import "TGDatabase.h"
#import "TGAudioSessionManager.h"

#import "TGCallUtils.h"
#import <LegacyComponents/TGObserverProxy.h>

#import "TGCallSignals.h"
#import "TGCallAudioPlayer.h"
#import "TGCallKitAdapter.h"

#import "VoIPController.h"
#import "VoIPServerConfig.h"
#import "os/darwin/SetupLogging.h"

typedef enum
{
    TGCallToneUndefined,
    TGCallToneRingback,
    TGCallToneBusy,
    TGCallToneConnecting,
    TGCallToneFailed,
    TGCallToneEnded
} TGCallTone;

@interface VoIPControllerHolder : NSObject {
    tgvoip::VoIPController *_controller;
}

@property (nonatomic, assign, readonly) tgvoip::VoIPController *controller;

@end

@implementation VoIPControllerHolder

- (instancetype)initWithController:(tgvoip::VoIPController *)controller {
    self = [super init];
    if (self != nil) {
        _controller = controller;
    }
    return self;
}

- (tgvoip::VoIPController *)controller {
    return _controller;
}

@end

const NSTimeInterval TGCallReceiveTimeout = 20;
const NSTimeInterval TGCallRingTimeout = 90;
const NSTimeInterval TGCallConnectTimeout = 30;
const NSTimeInterval TGCallPacketTimeout = 10;

@interface TGCallAudioContext : NSObject

@property (nonatomic, readonly) NSArray<TGAudioRoute *> *availableRoutes;
@property (nonatomic, readonly) TGAudioRoute *activeRoute;
@property (nonatomic, readonly) bool speaker;

- (instancetype)initWithAvailableRoutes:(NSArray<TGAudioRoute *> *)availableRoutes activeRoute:(TGAudioRoute *)activeRoute speaker:(bool)speaker;

@end


@interface TGCallSessionData : NSObject

@property (nonatomic, readonly) TGCallStateData *stateData;
@property (nonatomic, readonly) TGCallAudioContext *audioContext;

- (instancetype)initWithStateData:(TGCallStateData *)stateData audioContext:(TGCallAudioContext *)audioContext;

@end


@interface TGCallSession ()
{
    SMetaDisposable *_networkDisposable;
    SMetaDisposable *_disposable;
    SMetaDisposable *_timeoutDisposable;

    SVariable *_state;
    SPipe *_statePipe;
    TGCallState _currentState;

    SVariable *_transmissionState;
    SPipe *_transmissionPipe;
    TGCallTransmissionState _previousTransmissionState;
    
    SVariable *_signalBarsState;
    SPipe *_signalBarsPipe;

    SPipe *_audioTogglesPipe;
    SPipe *_audioContextPipe;

    bool _started;
    bool _discarded;
    NSNumber *_internalId;
    SAtomic *_controller;

    TGUser *_peer;

    CFAbsoluteTime _startTime;
    NSTimeInterval _callAcceptedTime;

    NSData *_keySha1;
    NSData *_keySha256;

    bool _playingRingtone;
    TGCallAudioPlayer *_audioPlayer;
    SMetaDisposable *_vibrateDisposable;

    bool _muted;
    bool _speaker;
    NSNumber *_targetSpeaker;
    NSNumber *_delayedSpeaker;
    OSSpinLock _speakerLock;

    TGObserverProxy *_applicationWillResignActiveProxy;
    TGObserverProxy *_applicationDidBecomeActiveProxy;

    UILocalNotification *_notification;
}

@property (nonatomic, copy) void (^hangUpCompletion)(void);

@end

@implementation TGCallSession

- (instancetype)initOutgoing:(bool)outgoing
{
    self = [super init];
    if (self != nil)
    {
        _outgoing = outgoing;

        _statePipe = [[SPipe alloc] init];
        _state = [[SVariable alloc] init];
        [_state set:_statePipe.signalProducer()];

        _transmissionPipe = [[SPipe alloc] init];
        _transmissionState = [[SVariable alloc] init];
        [_transmissionState set:_transmissionPipe.signalProducer()];
        _previousTransmissionState = TGCallTransmissionStateInitializing;
        
        _signalBarsPipe = [[SPipe alloc] init];
        _signalBarsState = [[SVariable alloc] init];
        [_signalBarsState set:_signalBarsPipe.signalProducer()];
        _signalBarsPipe.sink(@4);
        
        _audioTogglesPipe = [[SPipe alloc] init];
        [self _updateAudioToggles];

        _applicationWillResignActiveProxy = [[TGObserverProxy alloc] initWithTarget:self targetSelector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification];
        _applicationDidBecomeActiveProxy = [[TGObserverProxy alloc] initWithTarget:self targetSelector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification];
    }
    return self;
}

- (instancetype)initWithSignal:(SSignal *)signal outgoing:(bool)outgoing
{
    self = [self initOutgoing:outgoing];
    if (self != nil)
    {
        [self startWithSignal:signal];
    }
    return self;
}

- (void)dealloc
{
    [_disposable dispose];
    [_networkDisposable dispose];
    [_timeoutDisposable dispose];
    [_vibrateDisposable dispose];
}

- (void)markCallAcceptedTime
{
    _callAcceptedTime = CFAbsoluteTimeGetCurrent();
}

- (NSTimeInterval)callConnectionDuration
{
    if (_callAcceptedTime > DBL_EPSILON && _startTime > DBL_EPSILON)
        return _startTime - _callAcceptedTime;

    return 0.0;
}

- (void)startWithSignal:(SSignal *)signal
{
    [self _controllerInit];
    [self _setCallSignal:signal];
}

- (void)_setCallSignal:(SSignal *)signal
{
    __weak TGCallSession *weakSelf = self;
    _disposable = [[SMetaDisposable alloc] init];
    [_disposable setDisposable:[[signal deliverOn:[SQueue mainQueue]] startWithNext:^(TGCallStateData *next)
    {
        __strong TGCallSession *strongSelf = weakSelf;
        if (strongSelf != nil)
            [strongSelf updateWithState:next];
    } error:^(__unused id error)
    {
        __strong TGCallSession *strongSelf = weakSelf;
        if (strongSelf == nil)
            return;
    } completed:^
    {
    }]];
}

static void controllerStateCallback(tgvoip::VoIPController *controller, int state)
{
    TGCallSession *session = (__bridge TGCallSession *)controller->implData;
    [session controllerStateChanged:state];
}

static void loggingFunction(NSString *string)
{
    TGLog(string);
}

- (void)_controllerInit
{
    _controller = [[SAtomic alloc] initWithValue:nil recursive:true];
    [_controller modify:^id(VoIPControllerHolder *current) {
        assert(current == nil);

        TGVoipLoggingFunction = &loggingFunction;
        
        tgvoip::VoIPController *controller = new tgvoip::VoIPController();
        controller->implData = (__bridge void *)self;
        
        tgvoip::VoIPController::Callbacks callbacks;
        callbacks.connectionStateChanged = &controllerStateCallback;
        callbacks.signalBarCountChanged = &signalBarsCallback;
        controller->SetCallbacks(callbacks);

        tgvoip::VoIPController::crypto.sha1 = &TGCallSha1;
        tgvoip::VoIPController::crypto.sha256 = &TGCallSha256;
        tgvoip::VoIPController::crypto.rand_bytes = &TGCallRandomBytes;
        tgvoip::VoIPController::crypto.aes_ige_encrypt = &TGCallAesIgeEncryptInplace;
        tgvoip::VoIPController::crypto.aes_ige_decrypt = &TGCallAesIgeDecryptInplace;
        tgvoip::VoIPController::crypto.aes_ctr_encrypt = &TGCallAesCtrEncrypt;

        return [[VoIPControllerHolder alloc] initWithController:controller];
    }];
}

- (void)controllerStateChanged:(int)state
{
    TGCallTransmissionState tranmissionState = TGCallTransmissionStateInitializing;
    switch (state)
    {
        case tgvoip::STATE_ESTABLISHED:
            tranmissionState = TGCallTransmissionStateEstablished;
            break;

        case tgvoip::STATE_FAILED:
            tranmissionState = TGCallTransmissionStateFailed;
            break;
            
        case tgvoip::STATE_RECONNECTING:
            tranmissionState = TGCallTransmissionStateReconnecting;
            break;

        default:
            break;
    }
    
    TGDispatchOnMainThread(^
    {
        if (tranmissionState == _previousTransmissionState)
            return;
        
        if (tranmissionState == TGCallTransmissionStateEstablished && _startTime < DBL_EPSILON)
        {
            [[TGCallSession audioQueue] dispatch:^
            {
                NSError *error;
                [[AVAudioSession sharedInstance] setMode:AVAudioSessionModeVoiceChat error:&error];
            }];
            
            _startTime = CFAbsoluteTimeGetCurrent();
            
            if (self.onConnected != nil)
                self.onConnected();
        }
        
        _transmissionPipe.sink(@(tranmissionState));
        
        if (tranmissionState == TGCallTransmissionStateReconnecting)
        {
            [self playTone:TGCallToneConnecting];
        }
        else if (tranmissionState == TGCallTransmissionStateEstablished)
        {
            [self stopAudio];
        }
        else if (tranmissionState == TGCallTransmissionStateFailed)
        {
            [self playTone:TGCallToneEnded];
            [self _discardCurrentCallWithReason:TGCallDiscardReasonDisconnect];
        }
        
        _previousTransmissionState = tranmissionState;
    });
}

#pragma mark - Signal Bars

static void signalBarsCallback(tgvoip::VoIPController *controller, int bars)
{
    TGCallSession *session = (__bridge TGCallSession *)controller->implData;
    [session signalBarsChanged:bars];
}

- (void)signalBarsChanged:(int)bars
{
    TGDispatchOnMainThread(^
    {
        _signalBarsPipe.sink(@(bars));
    });
}

#pragma mark - Transmission

- (NSString *)callLogsPath
{
    NSString *path = [[TGAppDelegate documentsPath] stringByAppendingPathComponent:@"calls"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:nil])
        [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:true attributes:nil error:nil];
    
    NSMutableArray *logs = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil] mutableCopy];
    if (logs.count > 20)
    {
        NSString *oldestLogPath = [path stringByAppendingPathComponent:logs.firstObject];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:oldestLogPath error:nil];
        NSDate *oldestDate = attributes.fileModificationDate;
        
        for (NSString *log in logs)
        {
            if ([log hasSuffix:@".log"])
            {
                NSString *logPath = [path stringByAppendingPathComponent:log];
                NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:logPath error:nil];
                NSDate *date = attributes.fileModificationDate;
                if ([date compare:oldestDate] == NSOrderedAscending)
                {
                    oldestLogPath = logPath;
                    oldestDate = date;
                }
            }
        }
        
        [[NSFileManager defaultManager] removeItemAtPath:oldestLogPath error:nil];
        [logs removeObject:oldestLogPath.lastPathComponent];
    }
    
    return path;
}

- (void)startTransmissionIfNeeded:(TGCallStateData *)state
{
    if (_started)
        return;

    _started = true;

    void (^block)(void) = ^
    {
        [self playTone:TGCallToneConnecting];

        SSignal *readySignal = [SSignal single:@true];
        if ([TGCallKitAdapter callKitAvailable] && !_outgoing && _audioSessionActivated != nil)
            readySignal = _audioSessionActivated.signal;

        [[[[readySignal filter:^bool(NSNumber *value) {
            return value;
        }] timeout:10.5 onQueue:[SQueue mainQueue] orSignal:[SSignal single:@true]] take:1] startWithNext:^(__unused id next)
        {
            [self startNetworkTypeMonitoring];

            [_controller with:^id(VoIPControllerHolder *controller) {
                std::vector<tgvoip::Endpoint> endpoints;
                NSArray *connections = [@[state.connection.defaultConnection] arrayByAddingObjectsFromArray:state.connection.alternativeConnections];
                for (TGCallConnectionDescription *connection in connections) {
                    struct in_addr addrIpV4;
                    if (!inet_aton(connection.ipv4.UTF8String, &addrIpV4)) {
                        TGLog(@"CallSession: invalid ipv4 address");
                    }
                    
                    struct in6_addr addrIpV6;
                    if (!inet_pton(AF_INET6, connection.ipv6.UTF8String, &addrIpV6)) {
                        TGLog(@"CallSession: invalid ipv6 address");
                    }
                    
                    tgvoip::IPv4Address address(std::string(connection.ipv4.UTF8String));
                    tgvoip::IPv6Address addressv6(std::string(connection.ipv6.UTF8String));
                    unsigned char peerTag[16];
                    [connection.peerTag getBytes:peerTag length:16];
                    endpoints.push_back(tgvoip::Endpoint(connection.identifier, (uint16_t)connection.port, address, addressv6, tgvoip::Endpoint::TYPE_UDP_RELAY, peerTag));
                }

                tgvoip::VoIPController::Config config([TGCallSession callConnectTimeout], [TGCallSession callPacketTimeout], TGAppDelegateInstance.callsDataUsageMode, false, true, true);

                NSString *logPath = [[self callLogsPath] stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld-%lld.log", state.callId, state.accessHash]];
                config.logFilePath = std::string([logPath UTF8String]);
                
                if (TGAppDelegateInstance.callsUseProxy)
                {
                    MTSocksProxySettings *proxySettings = [[TGTelegramNetworking instance] context].apiEnvironment.socksProxySettings;
                    if (proxySettings != nil && proxySettings.secret.length == 0) {
                        std::string username = "";
                        if (proxySettings.username != nil) {
                            username = std::string(proxySettings.username.UTF8String);
                        }
                        std::string password = "";
                        if (proxySettings.password != nil) {
                            password = std::string(proxySettings.password.UTF8String);
                        }
                        
                        controller.controller->SetProxy(tgvoip::PROXY_SOCKS5, std::string(proxySettings.ip.UTF8String), proxySettings.port, username, password);
                    }
                }
                
                NSData *phoneCallsP2PContactsData = [TGDatabaseInstance() customProperty:@"phoneCallsP2PContacts"];
                int32_t phoneCallsP2PContacts = 0;
                if (phoneCallsP2PContactsData.length == 4) {
                    [phoneCallsP2PContactsData getBytes:&phoneCallsP2PContacts];
                }
                
                int32_t defaultMode = phoneCallsP2PContacts ? 3 : 2;
                int32_t p2pMode = TGAppDelegateInstance.callsP2PMode;
                if (p2pMode == 0)
                    p2pMode = defaultMode;
                
                bool allowP2P = false;
                switch (p2pMode)
                {
                    case 0:
                        allowP2P = [TGDatabaseInstance() uidIsRemoteContact:(int32_t)state.peerId];
                        break;
                        
                    case 2:
                        allowP2P = true;
                        break;
                        
                    default:
                        break;
                }
                
                controller.controller->SetConfig(config);

                controller.controller->SetEncryptionKey((char *)state.connection.key.bytes, _outgoing);
                controller.controller->SetRemoteEndpoints(endpoints, allowP2P, TGCallMaxLayer);
                controller.controller->Start();

                controller.controller->Connect();

                return nil;
            }];

            if (self.onStartedConnecting != nil)
                self.onStartedConnecting();
        }];
    };

    if ([TGCallKitAdapter callKitAvailable])
        block();
    else
        [self setupAudioSession:block];
}

- (void)stopTransmission:(bool)sendDebugLog
{
    if (_controller == nil)
        return;

    [_controller modify:^id(VoIPControllerHolder *controller) {
        NSString *debugLog = nil;
        char buffer[controller.controller->GetDebugLogLength()];
        controller.controller->GetDebugLog(buffer);
        debugLog = [[NSString alloc] initWithUTF8String:buffer];

        tgvoip::VoIPController::TrafficStats stats;
        controller.controller->GetStats(&stats);
        controller.controller->Stop();
        delete controller.controller;

        MTNetworkUsageManager *usageManager = [[MTNetworkUsageManager alloc] initWithInfo:[[TGTelegramNetworking instance] mediaUsageInfoForType:TGNetworkMediaTypeTagCall]];
        [usageManager addIncomingBytes:stats.bytesRecvdMobile interface:MTNetworkUsageManagerInterfaceWWAN];
        [usageManager addIncomingBytes:stats.bytesRecvdWifi interface:MTNetworkUsageManagerInterfaceOther];

        [usageManager addOutgoingBytes:stats.bytesSentMobile interface:MTNetworkUsageManagerInterfaceWWAN];
        [usageManager addOutgoingBytes:stats.bytesSentWifi interface:MTNetworkUsageManagerInterfaceOther];

        if (sendDebugLog && self.peerId != 0 && self.accessHash != 0)
            [[TGCallSignals saveCallDebug:self.peerId accessHash:self.accessHash data:debugLog] startWithNext:nil];

        return nil;
    }];
    _controller = nil;
}

- (void)startNetworkTypeMonitoring
{
    __weak TGCallSession *weakSelf = self;
    _networkDisposable = [[SMetaDisposable alloc] init];
    [_networkDisposable setDisposable:[[[[TGTelegraphInstance.networkTypeManager networkTypeSignal] map:^NSNumber *(NSNumber *value)
    {
        switch ((TGNetworkType)value.integerValue)
        {
            case TGNetworkTypeGPRS:
                return @(tgvoip::NET_TYPE_GPRS);

            case TGNetworkTypeEdge:
                return @(tgvoip::NET_TYPE_EDGE);

            case TGNetworkType3G:
                return @(tgvoip::NET_TYPE_3G);

            case TGNetworkTypeLTE:
                return @(tgvoip::NET_TYPE_LTE);

            case TGNetworkTypeWiFi:
                return @(tgvoip::NET_TYPE_WIFI);

            default:
                return @(tgvoip::NET_TYPE_UNKNOWN);
        }
    }] ignoreRepeated] startWithNext:^(NSNumber *next)
    {
        __strong TGCallSession *strongSelf = weakSelf;
        if (strongSelf != nil && strongSelf->_controller != nil) {
            [strongSelf->_controller with:^id(VoIPControllerHolder *controller) {
                controller.controller->SetNetworkType(next.intValue);
                return nil;
            }];
        }
    }]];
}

#pragma mark - Actions

- (void)acceptIncomingCall
{
    if (_internalId != nil)
    {
        [self markCallAcceptedTime];
        [TGTelegraphInstance.callManager acceptCallWithInternalId:_internalId];
    }
}

- (void)hangUpCurrentCallCompletion:(void (^)())completion
{
    self.hangUpCompletion = completion;
    [self hangUpCurrentCall:false];
}

- (void)hangUpCurrentCall
{
    [self hangUpCurrentCall:false];
}

- (void)hangUpCurrentCall:(bool)external
{
    _completed = external;
    [[[_state.signal take:1] timeout:0.5 onQueue:[SQueue mainQueue] orSignal:[SSignal single:nil]] startWithNext:^(TGCallStateData *next)
    {
        TGCallDiscardReason reason = TGCallDiscardReasonHangup;
        if (next.state != TGCallStateOngoing)
            reason = _outgoing ? TGCallDiscardReasonMissed : TGCallDiscardReasonBusy;

        [self _discardCurrentCallWithReason:reason];
    }];
}

- (void)_discardCurrentCallWithReason:(TGCallDiscardReason)reason
{
    if (_internalId == nil || _discarded)
        return;
    
    _discarded = true;
    [TGTelegraphInstance.callManager discardCallWithInternalId:_internalId reason:reason];
}

#pragma mark - Timeout

- (void)startTimeout:(NSTimeInterval)duration discardReason:(TGCallDiscardReason)discardReason
{
    if (_timeoutDisposable == nil)
        _timeoutDisposable = [[SMetaDisposable alloc] init];

    __weak TGCallSession *weakSelf = self;
    [_timeoutDisposable setDisposable:[[[SSignal complete] delay:duration onQueue:[SQueue mainQueue]] startWithNext:nil completed:^
    {
       __strong TGCallSession *strongSelf = weakSelf;
       if (strongSelf != nil)
           [strongSelf _discardCurrentCallWithReason:discardReason];
    }]];
}

- (void)invalidateTimeout
{
    [_timeoutDisposable setDisposable:nil];
}

+ (NSTimeInterval)callReceiveTimeout
{
    int32_t value = (int32_t)TGCallReceiveTimeout;
    NSData *data = [TGDatabaseInstance() customProperty:@"callReceiveTimeout"];
    if (data.length >= 4)
    {
        [data getBytes:&value length:4];
        value /= 1000;
    }
    return value;
}

+ (NSTimeInterval)callRingTimeout
{
    int32_t value = (int32_t)TGCallRingTimeout;
    NSData *data = [TGDatabaseInstance() customProperty:@"callRingTimeout"];
    if (data.length >= 4)
    {
        [data getBytes:&value length:4];
        value /= 1000;
    }
    return value;
}

+ (NSTimeInterval)callConnectTimeout
{
    int32_t value = (int32_t)TGCallConnectTimeout;
    NSData *data = [TGDatabaseInstance() customProperty:@"callConnectTimeout"];
    if (data.length >= 4)
    {
        [data getBytes:&value length:4];
        value /= 1000;
    }
    return value;
}

+ (NSTimeInterval)callPacketTimeout
{
    int32_t value = (int32_t)TGCallPacketTimeout;
    NSData *data = [TGDatabaseInstance() customProperty:@"callPacketTimeout"];
    if (data.length >= 4)
    {
        [data getBytes:&value length:4];
        value /= 1000;
    }
    return value;
}

+ (void)applyCallsConfig:(NSString *)data {
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:[data dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (dict != nil) {
        std::vector<std::string> result;
        //std::map<std::string, std::string> *pResult = &result;
        char **values = (char **)malloc(sizeof(char *) * (int)dict.count * 2);
        memset(values, 0, (int)dict.count * 2);
        __block int index = 0;
        [dict enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, __unused BOOL *stop) {
            NSString *valueText = [NSString stringWithFormat:@"%@", value];
            const char *keyText = [key UTF8String];
            const char *valueTextValue = [valueText UTF8String];
            values[index] = (char *)malloc(strlen(keyText) + 1);
            values[index][strlen(keyText)] = 0;
            memcpy(values[index], keyText, strlen(keyText));
            values[index + 1] = (char *)malloc(strlen(valueTextValue) + 1);
            values[index + 1][strlen(valueTextValue)] = 0;
            memcpy(values[index + 1], valueTextValue, strlen(valueTextValue));
            index += 2;

            //(*pResult)[std::string(key.UTF8String)] = std::string(valueText.UTF8String);
        }];
        tgvoip::ServerConfig::GetSharedInstance()->Update((const char **)values, index);
        for (int i = 0; i < (int)dict.count * 2; i++) {
            free(values[i]);
        }
        free(values);
    }
}

#pragma mark - Notifications

- (bool)_isInBackground
{
    UIApplicationState applicationState = [UIApplication sharedApplication].applicationState;
    if ([UIApplication sharedApplication] == nil)
        applicationState = UIApplicationStateBackground;

    return applicationState != UIApplicationStateActive;
}

- (void)presentCallNotification:(int64_t)peerId
{
    UIApplicationState applicationState = [UIApplication sharedApplication].applicationState;
    if ([UIApplication sharedApplication] == nil)
        applicationState = UIApplicationStateBackground;

    if ([self _isInBackground])
    {
        UILocalNotification *notification = [[UILocalNotification alloc] init];

        TGUser *peer = [TGDatabaseInstance() loadUser:(int)peerId];
        NSString *text = [NSString stringWithFormat:TGLocalized(@"PHONE_CALL_REQUEST"), peer.displayName];

        NSNumber *globalMessageSoundIdVal = nil;
        int globalMessageSoundId = 1;
        bool notFound = false;
        
        [TGDatabaseInstance() loadPeerNotificationSettings:INT_MAX - 1 soundId:&globalMessageSoundIdVal muteUntil:NULL previewText:NULL messagesMuted:NULL notFound:&notFound];
        if (notFound) {
            globalMessageSoundId = 1;
        }
        else {
            globalMessageSoundId = globalMessageSoundIdVal ? globalMessageSoundIdVal.intValue : 1;
        }

        notFound = false;
        
        NSNumber *soundIdVal = nil;
        int soundId = 1;
        [TGDatabaseInstance() loadPeerNotificationSettings:_peer.uid soundId:&soundIdVal muteUntil:NULL previewText:NULL messagesMuted:NULL notFound:&notFound];
        
        if (soundIdVal != nil) {
            soundId = soundIdVal.intValue;
        } else {
            soundId = globalMessageSoundId;
        }

        if (soundId > 0)
            notification.soundName = [[NSString alloc] initWithFormat:@"%d.m4a", soundId];

#ifdef INTERNAL_RELEASE
        text = [@"[L] " stringByAppendingString:text];
#endif
        notification.alertBody = text;
        notification.userInfo = @{@"cid": @(_peer.uid)};

        if (text != nil)
            [[UIApplication sharedApplication] presentLocalNotificationNow:notification];

        _notification = notification;
    }
}

- (void)cancelLocalNotification
{
    if (_notification == nil)
        return;

    [[UIApplication sharedApplication] cancelLocalNotification:_notification];
    _notification = nil;
}

- (void)applicationWillResignActive:(NSNotification *)__unused notification
{
    if ([TGCallKitAdapter callKitAvailable])
        return;

    if (_playingRingtone && _audioPlayer != nil)
        [self stopAudio];
}

- (void)applicationDidBecomeActive:(NSNotification *)__unused notification
{
    if ([TGCallKitAdapter callKitAvailable])
        return;

    if (_playingRingtone && _audioPlayer == nil)
        [self _startRingtonePlayer];
}

#pragma mark - Audio

static id<SDisposable> audioSession;

+ (SQueue *)audioQueue
{
    static dispatch_once_t onceToken;
    static SQueue *queue;
    dispatch_once(&onceToken, ^
    {
        queue = [[SQueue alloc] init];
    });
    return queue;
}

- (void)setupAudioSession
{
    [TGCallSession setupAudioSession:nil];
}

- (void)setupAudioSession:(void (^)(void))completion
{
    [TGCallSession setupAudioSession:completion];
}

- (void)resetAudioSession
{
    [TGCallSession resetAudioSession];
}

- (void)resetAudioSessionIfNeeded
{
    if (![TGCallKitAdapter callKitAvailable])
        [self resetAudioSession];
}

+ (void)setupAudioSession:(void (^)(void))completion
{
    [[self audioQueue] dispatch:^
    {
        if (audioSession != nil)
        {
            TGDispatchOnMainThread(^
            {
                if (completion != nil)
                    completion();
            });
            return;
        }

        audioSession = [[TGAudioSessionManager instance] requestSessionWithType:TGAudioSessionTypeCall interrupted:^{}];

        AVAudioSession *session = [AVAudioSession sharedInstance];
		[session setPreferredIOBufferDuration:0.005 error:NULL];

        TGDispatchOnMainThread(^
        {
            if (completion != nil)
                completion();
        });
    }];
}

+ (void)resetAudioSession
{
    [[self audioQueue] dispatch:^
    {
        if (audioSession == nil)
            return;

        [audioSession dispose];
        audioSession = nil;
        
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setPreferredIOBufferDuration:0.0 error:NULL];
    } synchronous:true];
}

+ (bool)hasMicrophoneAccess
{
    if (iosMajorVersion() < 7)
        return true;
    
    return [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusAuthorized;
}

- (void)toggleMute
{
    [self setMuted:!_muted];
}

- (void)setMuted:(bool)muted
{
    _muted = muted;
    if (_controller != nil) {
        [_controller with:^id(VoIPControllerHolder *controller) {
            controller.controller->SetMicMute(_muted);
            return nil;
        }];
    }

    [self _updateAudioToggles];
}

- (void)toggleSpeaker
{
    bool newValue = !_speaker;
    
    OSSpinLockLock(&_speakerLock);
    _targetSpeaker = @(newValue);
    _delayedSpeaker = _targetSpeaker;
    OSSpinLockUnlock(&_speakerLock);
    
    [[TGCallSession audioQueue] dispatch:^
    {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        AVAudioSessionPortOverride value = newValue ? AVAudioSessionPortOverrideSpeaker : AVAudioSessionPortOverrideNone;
        NSError *error;
        BOOL success = [session overrideOutputAudioPort:value error:&error];
        if (!success)
            TGLog(@"CallSession: failed to override output audio port: %@", error.localizedDescription);

        TGDispatchOnMainThread(^
        {
            OSSpinLockLock(&_speakerLock);
            _targetSpeaker = nil;
            OSSpinLockUnlock(&_speakerLock);
        });
    }];

    [self _updateAudioToggles];
}

- (void)applyAudioRoute:(TGAudioRoute *)audioRoute
{
    [[TGCallSession audioQueue] dispatch:^
    {
        [[TGAudioSessionManager instance] applyRoute:audioRoute];
        if (!audioRoute.isLoudspeaker)
        {
            OSSpinLockLock(&_speakerLock);
            _speaker = false;
            OSSpinLockUnlock(&_speakerLock);
        }
        
        [self _updateAudioToggles];
    }];
}

- (void)_updateAudioToggles
{
    _audioTogglesPipe.sink(@true);
}

- (void)_startRingtonePlayer
{
    _audioPlayer = [TGCallAudioPlayer playFileURL:[NSURL URLWithString:@"/Library/Ringtones/Opening.m4r"] loops:-1 completion:nil];

    _vibrateDisposable = [[SMetaDisposable alloc] init];
    [_vibrateDisposable setDisposable:[[[[SSignal single:nil] then:[[SSignal complete] delay:1.6 onQueue:[SQueue mainQueue]]] restart] startWithNext:^(__unused id next)
    {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
    }]];
}

- (void)playRingtone
{
    if ([TGCallKitAdapter callKitAvailable] || _audioPlayer != nil)
        return;

    _playingRingtone = true;
    if (![self _isInBackground])
        [self _startRingtonePlayer];
}

- (void)playTone:(TGCallTone)tone
{
    [self playTone:tone completion:nil];
}

- (void)playTone:(TGCallTone)tone completion:(void (^)(void))completion
{
    [self _playTone:[self _pathForTone:tone] loops:[self _loopsForTone:tone] completion:completion];
}

- (NSString *)_pathForTone:(TGCallTone)tone
{
    switch (tone)
    {
        case TGCallToneBusy:
            return [[NSBundle mainBundle] pathForResource:@"voip_busy" ofType:@"caf"];

        case TGCallToneRingback:
            return [[NSBundle mainBundle] pathForResource:@"voip_ringback" ofType:@"caf"];

        case TGCallToneConnecting:
            return [[NSBundle mainBundle] pathForResource:@"voip_connecting" ofType:@"mp3"];

        case TGCallToneFailed:
            return [[NSBundle mainBundle] pathForResource:@"voip_fail" ofType:@"caf"];

        case TGCallToneEnded:
            return [[NSBundle mainBundle] pathForResource:@"voip_end" ofType:@"caf"];

        default:
            return nil;
    }
}

- (NSInteger)_loopsForTone:(TGCallTone)tone
{
    switch (tone)
    {
        case TGCallToneBusy:
            return 3;

        case TGCallToneRingback:
            return -1;

        case TGCallToneConnecting:
            return -1;

        case TGCallToneFailed:
            return 1;

        case TGCallToneEnded:
            return 1;

        default:
            return 0;
    }
}

- (void)_playTone:(NSString *)path loops:(NSInteger)loops completion:(void (^)(void))completion
{
    if (_audioPlayer != nil || path == nil)
        return;

    [self setupAudioSession];

    _audioPlayer = [TGCallAudioPlayer playFileURL:[NSURL URLWithString:path] loops:loops completion:completion];
}

- (void)stopAudio
{
    _playingRingtone = false;

    [_audioPlayer stop];
    _audioPlayer = nil;

    [_vibrateDisposable setDisposable:nil];
    _vibrateDisposable = nil;
}

#pragma mark - State

- (void)updateWithState:(TGCallStateData *)state
{
    _internalId = state.internalId;
    if (_peer == nil && state.peerId != 0)
        _peer = [TGDatabaseInstance() loadUser:(int32_t)state.peerId];

    if (_callId == 0 && state.callId != 0)
        _callId = state.callId;

    if (_accessHash == 0 && state.accessHash != 0)
        _accessHash = state.accessHash;

    if (_keySha256 == nil && state.connection.keyHash != nil)
        _keySha256 = state.connection.keyHash;

    TGCallState previousState = _currentState;
    _currentState = state.state;

    switch (state.state)
    {
        case TGCallStateWaiting:
        {
            [self startTimeout:[TGCallSession callReceiveTimeout] discardReason:TGCallDiscardReasonMissedTimeout];
        }
            break;

        case TGCallStateWaitingReceived:
            [self startTimeout:[TGCallSession callRingTimeout] discardReason:TGCallDiscardReasonMissedTimeout];
            [self playTone:TGCallToneRingback];
            break;

        case TGCallStateHandshake:
        {
            [self startTimeout:[TGCallSession callRingTimeout] discardReason:TGCallDiscardReasonMissedTimeout];
            [self playRingtone];
        }
            break;

        case TGCallStateReady:
        {
            [self startTimeout:[TGCallSession callRingTimeout] discardReason:TGCallDiscardReasonMissedTimeout];
            [self playRingtone];
        }
            break;

        case TGCallStateAccepting:
        {
            [self invalidateTimeout];
            [self stopAudio];
        }
            break;

        case TGCallStateOngoing:
        {
            [self invalidateTimeout];
            [self stopAudio];
            [self startTransmissionIfNeeded:state];
        }
            break;

        case TGCallStateEnded:
        case TGCallStateEnding:
        case TGCallStateBusy:
        case TGCallStateNoAnswer:
        case TGCallStateMissed:
        {
            if (!_hungUpOutside)
                _hungUpOutside = state.hungUpOutside;

            [self invalidateTimeout];
            [self stopAudio];
            [self stopTransmission:state.needsDebug];

            [self cancelLocalNotification];
            
            void (^completeHangup)(void) = ^
            {
                if (self.hangUpCompletion == nil || state.state != TGCallStateEnded)
                    return;
                
                SSignal *readySignal = [SSignal single:@true];
                if ([TGCallKitAdapter callKitAvailable])
                    readySignal = _audioSessionDeactivated.signal;
                
                [[[[readySignal filter:^bool(NSNumber *value) {
                    return value;
                }] timeout:1.5 onQueue:[SQueue mainQueue] orSignal:[SSignal single:@true]] take:1] startWithNext:^(__unused id next)
                {
                    void (^completion)(void) = [self.hangUpCompletion copy];
                    self.hangUpCompletion = nil;
                    completion();
                }];
            };

            if (_outgoing && (state.state == TGCallStateBusy || state.state == TGCallStateNoAnswer))
            {
                [self playTone:TGCallToneBusy];
                TGDispatchAfter(2.0, dispatch_get_main_queue(), ^
                {
                    [self resetAudioSessionIfNeeded];
                });
            }
            else
            {
                TGCallTone tone = TGCallToneEnded;
                if (state.error != nil)
                    tone = TGCallToneFailed;

                if (!_outgoing && (previousState == TGCallStateHandshake || previousState == TGCallStateReady || previousState == TGCallStateMissed || previousState == TGCallStateEnding))
                    tone = TGCallToneUndefined;

                if (state.state == TGCallStateEnded || state.state == TGCallStateEnding)
                {
                    [self playTone:tone];
                    TGDispatchAfter(2.0, dispatch_get_main_queue(), ^
                    {
                        [self resetAudioSessionIfNeeded];
                    });
                }
                else
                {
                    [self resetAudioSessionIfNeeded];
                }
                
                completeHangup();
            }
        }
            break;

        default:
            break;
    }
    
    if (state.error != nil)
        TGLog(@"Call Session: failed with error: %@", state.error);
    
    _statePipe.sink(state);
}

- (NSTimeInterval)duration
{
    if (_startTime > DBL_EPSILON)
        return CFAbsoluteTimeGetCurrent() - _startTime;
    return 0.0;
}

- (SSignal *)stateSignal
{
    __weak TGCallSession *weakSelf = self;

    SSignal *combinedSignal = [SSignal combineSignals:@[_state.signal, _signalBarsState.signal, [self audioContextSignal], _transmissionState.signal, _audioTogglesPipe.signalProducer()] withInitialStates:@[ [NSNull null], @0, [NSNull null], @0, @0 ]];

    return [[combinedSignal deliverOn:[SQueue mainQueue]] map:^id(NSArray *values)
    {
        __strong TGCallSession *strongSelf = weakSelf;
        if (strongSelf == nil)
            return nil;

        TGCallStateData *stateData = [values[0] isKindOfClass:[NSNull class]] ? nil : (TGCallStateData *)values[0];
        NSInteger signalBars = [values[1] integerValue];
        TGCallAudioContext *audioContext = [values[2] isKindOfClass:[NSNull class]] ? nil : (TGCallAudioContext *)values[2];
        TGCallTransmissionState transmissionState = (TGCallTransmissionState)[values[3] integerValue];
        
        bool muted = strongSelf->_muted;
        bool speaker = strongSelf->_targetSpeaker ? strongSelf->_targetSpeaker.boolValue : audioContext.speaker;
        
        return [[TGCallSessionState alloc] initWithOutgoing:strongSelf->_outgoing callStateData:stateData transmissionState:transmissionState peer:strongSelf->_peer keySha256:strongSelf->_keySha256 startTime:strongSelf->_startTime signalBars:signalBars mute:muted speaker:speaker audioRoutes:audioContext.availableRoutes activeAudioRoute:audioContext.activeRoute];
    }];
}

- (SSignal *)audioContextSignal
{
    __weak TGCallSession *weakSelf = self;
    return [[[SSignal combineSignals:@[_state.signal, _transmissionState.signal, [TGAudioSessionManager routeChange], _audioTogglesPipe.signalProducer(), [[[SSignal single:@true] delay:1.0 onQueue:[SQueue concurrentDefaultQueue]] restart]] withInitialStates:@[ [NSNull null], @0, @0, @0, @0 ]] deliverOn:[TGCallSession audioQueue]] map:^id(__unused NSArray *values)
    {
        __strong TGCallSession *strongSelf = weakSelf;
        
        TGCallStateData *stateData = [values[0] isKindOfClass:[NSNull class]] ? nil : (TGCallStateData *)values[0];
        TGCallState currentState = stateData.state;
        
        OSSpinLockLock(&_speakerLock);
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        NSArray *inputs = iosMajorVersion() >= 7 ? audioSession.availableInputs : nil;
        NSArray *outputs = audioSession.currentRoute.outputs;
        
        NSMutableArray *audioRoutes = [[NSMutableArray alloc] init];
        TGAudioRoute *activeRoute = nil;
        bool hasHeadphones = false;
        
        bool speaker = strongSelf->_speaker;
        NSNumber *targetSpeaker = strongSelf->_targetSpeaker;
        NSNumber *delayedSpeaker = strongSelf->_delayedSpeaker;
        if (targetSpeaker != nil)
        {
            speaker = targetSpeaker.boolValue;
        }
        else if (currentState == TGCallStateWaitingReceived || currentState == TGCallStateOngoing)
        {
            strongSelf->_delayedSpeaker = nil;
            speaker = false;
            for (AVAudioSessionPortDescription *output in outputs)
            {
                if ([output.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker])
                {
                    speaker = true;
                    break;
                }
            }
        }
        else if (delayedSpeaker != nil)
        {
            speaker = delayedSpeaker.boolValue;
        }
        
        for (AVAudioSessionPortDescription *input in inputs)
        {
            if ([input.portType isEqualToString:AVAudioSessionPortBuiltInMic])
                continue;
            
            if ([input.portType isEqualToString:AVAudioSessionPortHeadsetMic])
            {
                hasHeadphones = true;
                continue;
            }
            
            TGAudioRoute *route = [TGAudioRoute routeWithDescription:input];
            [audioRoutes addObject:route];
            
            for (AVAudioSessionPortDescription *currentInput in audioSession.currentRoute.inputs)
            {
                if ([currentInput.UID isEqualToString:input.UID])
                    activeRoute = route;
            }
        }
        OSSpinLockUnlock(&_speakerLock);
        
        TGAudioRoute *builtInRoute = [TGAudioRoute routeForBuiltIn:hasHeadphones];
        [audioRoutes addObject:builtInRoute];
        TGAudioRoute *speakerRoute = [TGAudioRoute routeForSpeaker];
        if (speakerRoute != nil)
        {
            [audioRoutes addObject:speakerRoute];
            if (speaker)
                activeRoute = speakerRoute;
        }
        
        if (activeRoute == nil)
            activeRoute = builtInRoute;
        
        OSSpinLockLock(&_speakerLock);
        strongSelf->_speaker = speaker;
        OSSpinLockUnlock(&_speakerLock);
        
        return [[TGCallAudioContext alloc] initWithAvailableRoutes:audioRoutes activeRoute:activeRoute speaker:speaker];
    }];
}

- (SSignal *)debugSignal
{
    __weak TGCallSession *weakSelf = self;
    return [[[SSignal defer:^SSignal *{
        __strong TGCallSession *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_controller == nil)
            return [SSignal complete];

        NSArray *debugValues = [strongSelf->_controller with:^id(VoIPControllerHolder *controller) {
            NSString *versionString = [NSString stringWithUTF8String:controller.controller->GetVersion()];
            auto rawDebugString = controller.controller->GetDebugString();
            NSString *debugString = [NSString stringWithUTF8String:rawDebugString.c_str()];
            return @[debugString, versionString];
        }];
        return [SSignal single:[NSString stringWithFormat:@"libtgvoip v%@\n%@", debugValues[1], debugValues[0]]];
    }] then:[[SSignal complete] delay:0.5 onQueue:[SQueue mainQueue]]] restart];
}

- (SSignal *)levelSignal
{
    __weak TGCallSession *weakSelf = self;
    return [[[SSignal defer:^SSignal *{
        __strong TGCallSession *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_controller == nil)
            return [SSignal complete];

        NSNumber *level = [strongSelf->_controller with:^id(VoIPControllerHolder *controller) {
            CGFloat value = MIN(1.0f, MAX(0.0f, controller.controller->GetOutputLevel()));
            return @(value);
        }];
        return [SSignal single:level];
    }] then:[[SSignal complete] delay:0.1 onQueue:[SQueue mainQueue]]] restart];
}

- (int64_t)peerId
{
    return _peer.uid;
}

#pragma mark - Debug

- (void)setDebugBitrate:(NSInteger)bitrate
{
    if (_controller == nil)
        return;

    [_controller with:^id(VoIPControllerHolder *controller) {
        controller.controller->DebugCtl(1, (int)bitrate);
        return nil;
    }];
}

- (void)setDebugPacketLoss:(NSInteger)packetLossPercent
{
    if (_controller == nil)
        return;

    [_controller with:^id(VoIPControllerHolder *controller) {
        controller.controller->DebugCtl(2, (int)packetLossPercent);
        return nil;
    }];
}

- (void)setDebugP2PEnabled:(bool)enabled
{
    if (_controller == nil)
        return;

    [_controller with:^id(VoIPControllerHolder *controller) {
        controller.controller->DebugCtl(3, enabled);
        return nil;
    }];
}

@end


@implementation TGCallSessionState

- (instancetype)initWithOutgoing:(bool)outgoing callStateData:(TGCallStateData *)stateData transmissionState:(TGCallTransmissionState)transmissionState peer:(TGUser *)peer keySha256:(NSData *)keySha256 startTime:(CFAbsoluteTime)startTime signalBars:(NSInteger)signalBars mute:(bool)mute speaker:(bool)speaker audioRoutes:(NSArray *)audioRoutes activeAudioRoute:(TGAudioRoute *)activeAudioRoute
{
    self = [super init];
    if (self != nil)
    {
        _outgoing = outgoing;
        _stateData = stateData;
        _state = stateData.state;
        _transmissionState = transmissionState;
        _peer = peer;
        _keySha256 = keySha256;
        _startTime = startTime;
        _signalBars = signalBars;
        _mute = mute;
        _speaker = speaker;
        _audioRoutes = audioRoutes;
        _activeAudioRoute = activeAudioRoute;
    }
    return self;
}

@end


@implementation TGCallAudioContext

- (instancetype)initWithAvailableRoutes:(NSArray<TGAudioRoute *> *)availableRoutes activeRoute:(TGAudioRoute *)activeRoute speaker:(bool)speaker
{
    self = [super init];
    if (self != nil)
    {
        _availableRoutes = availableRoutes;
        _activeRoute = activeRoute;
        _speaker = speaker;
    }
    return self;
}

@end


@implementation TGCallSessionData

- (instancetype)initWithStateData:(TGCallStateData *)stateData audioContext:(TGCallAudioContext *)audioContext
{
    self = [super init];
    if (self != nil)
    {
        _stateData = stateData;
        _audioContext = audioContext;
    }
    return self;
}

@end
