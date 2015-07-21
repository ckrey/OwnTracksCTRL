//
//  OPAppDelegate.m
//  OwnTracksCTRL
//
//  Created by Christoph Krey on 29.05.14.
//  Copyright (c) 2014-2015 christophkrey. All rights reserved.
//

#import "AppDelegate.h"
#import "StatelessThread.h"
#import "StatefullThread.h"
#import "Vehicle+Create.h"
#import "MapVC.h"
#import "LoginVC.h"

#import <CocoaLumberjack/CocoaLumberjack.h>
#import <Fabric/Fabric.h>
#import <Crashlytics/Crashlytics.h>

#undef BACKGROUND_CONNECT // if enabled, background capability has to be setup again
#undef EVENT_REPORTING
#undef ALARM_REPORTING

@interface AppDelegate()

#ifdef BACKGROUND_CONNECT
@property (strong, nonatomic) NSTimer *disconnectTimer;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@property (strong, nonatomic) void (^completionHandler)(UIBackgroundFetchResult);
#endif

@property (strong, nonatomic) StatefullThread *mqttPlusThread;
@property (strong, nonatomic) StatelessThread *mqttThread;
@property (strong, nonatomic) NSManagedObjectContext *queueManagedObjectContext;
@property (readwrite, strong, nonatomic) NSString *connectedTo;
@property (readwrite, strong, nonatomic) NSString *token;
@property (nonatomic) BOOL registered;

@end

#define RECONNECT_TIMER 1.0
#define RECONNECT_TIMER_MAX 64.0
#define BACKGROUND_DISCONNECT_AFTER 8.0

@implementation AppDelegate

@synthesize managedObjectContext = _managedObjectContext;
@synthesize managedObjectModel = _managedObjectModel;
@synthesize persistentStoreCoordinator = _persistentStoreCoordinator;

static const DDLogLevel ddLogLevel = DDLogLevelVerbose;

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
#ifdef BACKGROUND_CONNECT
    self.backgroundTask = UIBackgroundTaskInvalid;
    self.completionHandler = nil;
#endif
    self.kiosk = @(false);
    DDLogVerbose(@"ddLogLevel %lu", (unsigned long)ddLogLevel);
    return YES;
}


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    [Fabric with:@[CrashlyticsKit]];
    [DDLog addLogger:[DDTTYLogger sharedInstance]];
    
    NSDictionary *appDefaults = [NSDictionary
                                 dictionaryWithObject:@"https://demo.owntracks.de/ctrld/conf" forKey:@"ctrldurl"];
    [[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    self.confD = [ConfD confDInManagedObjectContext:self.managedObjectContext];
    self.broker = [Broker brokerInManagedObjectContext:self.managedObjectContext];

#ifdef BACKGROUND_CONNECT
    [application setMinimumBackgroundFetchInterval:UIApplicationBackgroundFetchIntervalMinimum];
#endif
    
    UIUserNotificationSettings *userNotificationSettings = [UIUserNotificationSettings
                                                            settingsForTypes:
                                                            UIUserNotificationTypeAlert |
                                                            UIUserNotificationTypeSound |
                                                            UIUserNotificationTypeBadge
                                                            categories:nil];
    [application registerUserNotificationSettings:userNotificationSettings];
    
    [application registerForRemoteNotifications];
    
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    [self saveContext];
    [self disconnect];
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    if ([self.window.rootViewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigationController = (UINavigationController *)self.window.rootViewController;
        //[navigationController popToRootViewControllerAnimated:false];
        if ([navigationController.topViewController respondsToSelector:@selector(automaticStart)]) {
            //[navigationController.topViewController performSelector:@selector(automaticStart) withObject:nil];
        }
    }
    [self connect];
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    [self saveContext];
    [self disconnect];
}

- (void)connect {
    [self disconnect];
    
    self.mqttThread = [[StatelessThread alloc] init];
    self.mqttThread.host = self.broker.host;
    self.mqttThread.port = [self.broker.port intValue];
    self.mqttThread.tls = [self.broker.tls boolValue];
    
    if ([self.broker.auth boolValue]) {
        if (self.broker.user && self.broker.user.length > 0) {
            self.mqttThread.user = self.broker.user;
            if (self.broker.passwd && self.broker.passwd.length > 0) {
                self.mqttThread.passwd = self.broker.passwd;
            }
        } else {
            self.broker.user = nil;
            self.broker.passwd = nil;
        }
    } else {
        self.mqttThread.user = nil;
        self.mqttThread.passwd = nil;
    }
    
    self.mqttThread.base = self.broker.base;
    self.mqttThread.clientid = self.broker.clientid;
    
    [self.mqttThread addObserver:self forKeyPath:@"connectedTo"
                         options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
                         context:nil];
    self.registered = true;
    [self.mqttThread start];
    
    self.mqttPlusThread = [[StatefullThread alloc] init];
    self.mqttPlusThread.host = self.broker.host;
    self.mqttPlusThread.port = [self.broker.port intValue];
    self.mqttPlusThread.tls = [self.broker.tls boolValue];

    if ([self.broker.auth boolValue]) {
        if (self.broker.user && self.broker.user.length > 0) {
            self.mqttPlusThread.user = self.broker.user;
            if (self.broker.passwd && self.broker.passwd.length > 0) {
                self.mqttPlusThread.passwd = self.broker.passwd;
            }
        } else {
            self.broker.user = nil;
            self.broker.passwd = nil;
        }
    } else {
        self.mqttPlusThread.user = nil;
        self.mqttPlusThread.passwd = nil;
    }
    
    self.mqttPlusThread.base = self.broker.base;
    self.mqttPlusThread.clientid = self.broker.clientid;
    [self.mqttPlusThread start];
}

- (void)disconnect {
    if (self.registered) {
        [self.mqttThread removeObserver:self forKeyPath:@"connectedTo" context:nil];
        self.registered = false;
    }
    [self.mqttThread setTerminate:TRUE];
    [self.mqttPlusThread setTerminate:TRUE];
    self.connectedTo = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"connectedTo"]) {
        self.connectedTo = (NSString *)[object valueForKey:keyPath];
    }
}

- (void)application:(UIApplication *)application didRegisterUserNotificationSettings:(UIUserNotificationSettings *)notificationSettings {
    DDLogVerbose(@"didRegisterUserNotificationSettings");
}

- (void)application:(UIApplication *)application didReceiveLocalNotification:(UILocalNotification *)notification {
    NSString *loadButtonTitle = notification.userInfo[@"tid"] ? notification.userInfo[@"tid"] : nil;

    UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:notification.userInfo[@"title"]
                                                        message:notification.alertBody
                                                       delegate:self
                                              cancelButtonTitle:nil
                                              otherButtonTitles:@"OK", loadButtonTitle, nil];
    [alertView show];
}

- (void)didPresentAlertView:(UIAlertView *)alertView {
    [self performSelector:@selector(alertViewTimedOut:) withObject:alertView afterDelay:5];
}

- (void)alertView:(UIAlertView *)alertView willDismissWithButtonIndex:(NSInteger)buttonIndex {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(alertViewTimedOut:) object:alertView];
    if (buttonIndex > 0) {
        NSString *tid = [alertView buttonTitleAtIndex:buttonIndex];
        Vehicle *vehicle = [Vehicle existsVehicleWithTid:tid inManagedObjectContext:self.managedObjectContext];
        [MapVC centerOn:vehicle];
    }
}

- (void)alertViewTimedOut:(id)object {
    UIAlertView *alertView = (UIAlertView *)object;
    [alertView dismissWithClickedButtonIndex:0 animated:true];
    
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
    UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"didFailToRegisterForRemoteNotificationsWithError"
                                                        message:[error description]
                                                       delegate:nil
                                              cancelButtonTitle:nil
                                              otherButtonTitles:@"OK", nil];
    [alertView show];
    self.token = @"";
}

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    DDLogVerbose(@"didRegisterForRemoteNotificationsWithDeviceToken %@", deviceToken.description);
    NSString *token = [deviceToken description];
    token = [token stringByReplacingOccurrencesOfString:@" " withString:@""];
    token = [token substringFromIndex:1];
    token = [token substringToIndex:token.length - 1];
    DDLogVerbose(@"didRegisterForRemoteNotificationsWithDeviceToken %@", token);
    self.token = token;
}

- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
    UILocalNotification *localNotification = [[UILocalNotification alloc] init];
    NSDictionary *aps = userInfo[@"aps"];
    localNotification.alertBody = aps[@"alert"];
    localNotification.userInfo = userInfo;
    [[UIApplication sharedApplication] presentLocalNotificationNow:localNotification];
    [UIApplication sharedApplication].applicationIconBadgeNumber--;
    completionHandler(UIBackgroundFetchResultNoData);
}


- (NSManagedObjectContext *)queueManagedObjectContext
{
    if (!_queueManagedObjectContext) {
        _queueManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        [_queueManagedObjectContext setParentContext:self.managedObjectContext];
    }
    return _queueManagedObjectContext;
}

- (void)processMessage:(id)object {
    DDLogVerbose(@"processMessage %@", object);
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = (NSDictionary *)object;
        NSData *data = dictionary[@"data"];
        NSString *topic = dictionary[@"topic"];
        
        NSArray *topicComponents = [topic componentsSeparatedByCharactersInSet:
                                    [NSCharacterSet characterSetWithCharactersInString:@"/"]];
        
        NSArray *topicFilters = [self.broker.base componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSArray *baseComponents = [topicFilters[0] componentsSeparatedByCharactersInSet:
                                   [NSCharacterSet characterSetWithCharactersInString:@"/"]];
        
        if (topicComponents.count < baseComponents.count) {
            NSString *message = [NSString stringWithFormat:@"topic=%@, baseTopic=%@", topic, topicFilters[0]];

            UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"unexpected message received"
                                                                message:message
                                                               delegate:self
                                                      cancelButtonTitle:nil
                                                      otherButtonTitles:@"OK", nil];
            [alertView show];
            return;
        }
        
        NSString *baseTopic = @"";
        
        for (int i = 0; i < [baseComponents count]; i++) {
            if (baseTopic.length) {
                baseTopic = [baseTopic stringByAppendingString:@"/"];
            }
            baseTopic = [baseTopic stringByAppendingString:topicComponents[i]];
        }
        
        NSString *subTopic = @"";
        
        for (unsigned long i = [baseComponents count]; i < [topicComponents count]; i++) {
            if (subTopic.length) {
                subTopic = [subTopic stringByAppendingString:@"/"];
            }
            subTopic = [subTopic stringByAppendingString:topicComponents[i]];
        }
        
        [self.queueManagedObjectContext performBlock:^{
            
            DDLogVerbose(@"processing %@", topic);
            
            Vehicle *vehicle = [Vehicle vehicleNamed:baseTopic
                              inManagedObjectContext:self.queueManagedObjectContext];
            if (!vehicle.tid) {
                vehicle.tid = [baseTopic substringFromIndex:MAX(0, baseTopic.length - 2)];
            }
            
            NSDictionary *dictionary = nil;
            if (data.length) {
                NSError *error;
                dictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                
                if (!dictionary) {
                    NSString *payload = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    NSArray *values = [payload componentsSeparatedByString:@","];
                    if ([values count] == 10) {
                        dictionary = [[NSMutableDictionary alloc] initWithCapacity:9];
                        [dictionary setValue:values[0] forKey:@"tid"];
                        
                        NSScanner *scanner = [NSScanner scannerWithString:values[1]];
                        unsigned int tst = 0;
                        [scanner scanHexInt:&tst];
                        [dictionary setValue:[NSString stringWithFormat:@"%u", tst] forKey:@"tst"];
                        
                        [dictionary setValue:values[2] forKey:@"t"];

                        double lat = [values[3] doubleValue] / 1000000.0;
                        [dictionary setValue:[NSString stringWithFormat:@"%.6f", lat] forKey:@"lat"];
                        
                        double lon = [values[4] doubleValue] / 1000000.0;
                        [dictionary setValue:[NSString stringWithFormat:@"%.6f", lon] forKey:@"lon"];
                        
                        int cog = [values[5] intValue] * 10;
                        [dictionary setValue:@(cog) forKey:@"cog"];
                        
                        int vel = [values[6] intValue];
                        [dictionary setValue:@(vel) forKey:@"vel"];
                        
                        int alt = [values[7] intValue] * 10;
                        [dictionary setValue:@(alt) forKey:@"alt"];
                        
                        int dist = [values[8] intValue];
                        [dictionary setValue:@(dist) forKey:@"dist"];
                        
                        int trip = [values[9] intValue] * 1000;
                        [dictionary setValue:@(trip) forKey:@"trip"];
                    }
                }
            }
            
            if ([topicComponents count] == [baseComponents count]) {
                if (dictionary) {
                    vehicle.acc = @([dictionary[@"acc"] doubleValue]);
                    vehicle.alt = dictionary[@"alt"];
                    vehicle.cog = dictionary[@"cog"];
                    vehicle.dist= dictionary[@"dist"];
                    vehicle.lat= @([dictionary[@"lat"] doubleValue]);
                    vehicle.lon= @([dictionary[@"lon"] doubleValue]);
                    
                    if (dictionary[@"tid"]) {
                        vehicle.tid = dictionary[@"tid"];
                    } else {
                        vehicle.tid = [baseTopic substringFromIndex:MAX(0, baseTopic.length - 2)];
                    }
                    
                    vehicle.trigger= dictionary[@"t"];
                    vehicle.trip=dictionary[@"trip"];
                    vehicle.tst=[NSDate dateWithTimeIntervalSince1970:[dictionary[@"tst"] doubleValue]];
                    vehicle.vacc=dictionary[@"vacc"];
                    vehicle.vel=dictionary[@"vel"];
#ifdef EVENT_REPORTING
                    [self processEventMessage:dictionary forVehicle:vehicle];
#endif
                }
            } else {
                if ([subTopic isEqualToString:@"status"]) {
                    NSString *status = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    vehicle.status = @([status intValue]);

                } else if ([subTopic isEqualToString:@"info"]) {
                    NSString *info = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    vehicle.info= info;
                    
                } else if ([subTopic isEqualToString:@"start"]) {
                    NSString *start = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    NSArray *fields = [start componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (fields.count == 3) {
                        NSDateFormatter * dateFormatter = [[NSDateFormatter alloc]init];
                        [dateFormatter setDateFormat:@"yyyyMMdd'T'HHmmss'Z'"];
                        [dateFormatter setTimeZone:[[NSTimeZone alloc] initWithName:@"UTC"]];
                        NSDate *startDate = [dateFormatter dateFromString:fields[2]];
                        vehicle.start = startDate;
                        vehicle.version = fields[1];
                        vehicle.imei = fields[0];
                    }
                    
                } else if ([subTopic isEqualToString:@"gpio/1"]) {
                    NSString *gpio = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    vehicle.gpio1= @([gpio intValue]);
                } else if ([subTopic isEqualToString:@"gpio/3"]) {
                    NSString *gpio = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    vehicle.gpio3= @([gpio intValue]);
                } else if ([subTopic isEqualToString:@"gpio/2"]) {
                    NSString *gpio = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    vehicle.gpio2= @([gpio intValue]);
                } else if ([subTopic isEqualToString:@"gpio/5"]) {
                    NSString *gpio = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    vehicle.gpio5= @([gpio intValue]);
                } else if ([subTopic isEqualToString:@"gpio/7"]) {
                    NSString *gpio = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    vehicle.gpio7= @([gpio intValue]);
                    
                } else if ([subTopic isEqualToString:@"voltage/batt"]) {
                    NSString *voltage = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    vehicle.vbatt = @([voltage doubleValue]);
                } else if ([subTopic isEqualToString:@"voltage/ext"]) {
                    NSString *voltage = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    vehicle.vext = @([voltage doubleValue]);
                    
                } else if ([subTopic isEqualToString:@"temperature/0"]) {
                    NSString *temperature = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    vehicle.temp0 = @([temperature doubleValue]);
                } else if ([subTopic isEqualToString:@"temperature/1"]) {
                    NSString *temperature = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    vehicle.temp1 = @([temperature doubleValue]);
                    
#ifdef ALARM_REPORTING
                } else if ([subTopic isEqualToString:@"alarm"]) {
                    if (dictionary) {
                        NSDate *alarmAt = [NSDate dateWithTimeIntervalSince1970:[dictionary[@"tst"] doubleValue]];
                        NSString *alarm = [NSString stringWithFormat:@"Alarm sent by %@ @ %@",
                                           vehicle.tid,
                                           [NSDateFormatter localizedStringFromDate:alarmAt
                                                                          dateStyle:NSDateFormatterShortStyle
                                                                          timeStyle:NSDateFormatterShortStyle]];
                        DDLogVerbose(@"new alarm %@, existing alarm %@", alarm, vehicle.alarm);
                        if (!vehicle.alarm || ![alarm isEqualToString:vehicle.alarm]) {
                            vehicle.alarm = alarm;
                            UILocalNotification *localNotification = [[UILocalNotification alloc] init];
                            localNotification.alertBody = vehicle.alarm;
                            localNotification.userInfo = @{@"tid": vehicle.tid, @"title": @"Alarm"};
                            [[UIApplication sharedApplication] presentLocalNotificationNow:localNotification];
                        }
                    }
#endif
                    
#ifdef EVENT_REPORTING
                } else if ([subTopic isEqualToString:@"event"]) {
                    if (dictionary) {
                        [self processEventMessage:dictionary forVehicle:vehicle];
                    }
#endif
                    
                } else {
                    //
                }
            }
            
            NSError *error;
            if ([self.queueManagedObjectContext hasChanges] && ![self.queueManagedObjectContext save:&error]) {
                DDLogError(@"queueManagedObjectContext save:%@", error);
            }
            DDLogVerbose(@"processing %@ finished", topic);
            
        }];
    }
}

#ifdef EVENT_REPORTING
- (void)processEventMessage:(NSDictionary *)dictionary forVehicle:(Vehicle *)vehicle {
    NSString *event = dictionary[@"event"];
    if (event) {
        NSString *eventString= [NSString stringWithFormat:@"Event %@ %@ %@ @ %@",
                                vehicle.tid,
                                event,
                                dictionary[@"desc"],
                                [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:
                                                                          [dictionary[@"tst"] doubleValue]]
                                                               dateStyle:NSDateFormatterShortStyle
                                                               timeStyle:NSDateFormatterShortStyle]];
        if (!vehicle.event || ![eventString isEqualToString:vehicle.event]) {
            vehicle.event = eventString;
            UILocalNotification *localNotification = [[UILocalNotification alloc] init];
            localNotification.alertBody = vehicle.event;
            localNotification.userInfo = @{@"tid": vehicle.tid, @"title": @"Event"};
            [[UIApplication sharedApplication] presentLocalNotificationNow:localNotification];
        }
    }

}
#endif

- (void)saveContext
{
    NSError *error = nil;
    NSManagedObjectContext *managedObjectContext = self.managedObjectContext;
    if (managedObjectContext != nil) {
        if ([managedObjectContext hasChanges] && ![managedObjectContext save:&error]) {
            DDLogError(@"managedObjectContext save: %@", error);
            abort();
        }
    }
}

#pragma mark - Core Data stack

- (NSManagedObjectContext *)managedObjectContext
{
    if (_managedObjectContext != nil) {
        return _managedObjectContext;
    }
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    if (coordinator != nil) {
        _managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        [_managedObjectContext setPersistentStoreCoordinator:coordinator];
    }
    return _managedObjectContext;
}

- (NSManagedObjectModel *)managedObjectModel
{
    if (_managedObjectModel != nil) {
        return _managedObjectModel;
    }
    NSURL *modelURL = [[NSBundle mainBundle] URLForResource:@"Model" withExtension:@"momd"];
    _managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    return _managedObjectModel;
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (_persistentStoreCoordinator != nil) {
        return _persistentStoreCoordinator;
    }
    
    NSURL *storeURL = [[self applicationDocumentsDirectory] URLByAppendingPathComponent:@"OwnTracksGW.sqlite"];
    
    NSError *error = nil;
    _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
    NSDictionary *options = @{NSMigratePersistentStoresAutomaticallyOption: @YES,
                              NSInferMappingModelAutomaticallyOption: @YES};

    if (![_persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                   configuration:nil
                                                             URL:storeURL
                                                         options:options
                                                           error:&error]) {
        DDLogError(@"managedObjectContext save: %@", error);
        abort();
    }
    
    return _persistentStoreCoordinator;
}

#pragma mark - Application's Documents directory

- (NSURL *)applicationDocumentsDirectory
{
    return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
}

#ifdef BACKGROUND_CONNECT
- (void)applicationDidEnterBackground:(UIApplication *)application
{
    self.backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        if (self.backgroundTask) {
            [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
            self.backgroundTask = UIBackgroundTaskInvalid;
        }
    }];
}

- (void)application:(UIApplication *)application performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
    self.completionHandler = completionHandler;
    [self connect];
    [self startBackgroundTimer];
}

- (void)startBackgroundTimer
{
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        if (self.disconnectTimer && self.disconnectTimer.isValid) {
        } else {
            self.disconnectTimer = [NSTimer timerWithTimeInterval:BACKGROUND_DISCONNECT_AFTER
                                                           target:self
                                                         selector:@selector(disconnectInBackground)
                                                         userInfo:Nil repeats:FALSE];
            NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
            [runLoop addTimer:self.disconnectTimer
                      forMode:NSDefaultRunLoopMode];
        }
    }
}

- (void)disconnectInBackground
{
    self.disconnectTimer = nil;
    [self disconnect];
    if (self.completionHandler) {
        self.completionHandler(UIBackgroundFetchResultNewData);
        self.completionHandler = nil;
    }
}
#endif

@end
