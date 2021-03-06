//
//  OPMQTTThread.m
//  OwnTracksGW
//
//  Created by Christoph Krey on 18.09.14.
//  Copyright © 2014-2016 christophkrey. All rights reserved.
//

#import "StatelessThread.h"
#import "AppDelegate.h"
#import "Vehicle.h"

#import <CocoaLumberjack/CocoaLumberjack.h>

@interface StatelessThread()
@property (strong, nonatomic) MQTTSession *mqttSession;
@property (nonatomic, strong, readwrite) NSString *connectedTo;
@property (nonatomic, strong, readwrite) NSError *error;

@end

@implementation StatelessThread

static const DDLogLevel ddLogLevel = DDLogLevelVerbose;

- (void)main {
    DDLogVerbose(@"StatelessThread");
    
    self.mqttSession = [[MQTTSession alloc] initWithClientId:self.clientid
                                                    userName:self.user
                                                    password:self.passwd
                                                   keepAlive:60
                                                cleanSession:TRUE
                                                        will:NO
                                                   willTopic:nil
                                                     willMsg:nil
                                                     willQoS:0
                                              willRetainFlag:NO
                                               protocolLevel:4
                                                     runLoop:[NSRunLoop currentRunLoop]
                                                     forMode:NSDefaultRunLoopMode];
    
    self.mqttSession.delegate = self;
    if ([self.mqttSession connectAndWaitToHost:self.host
                                          port:self.port
                                      usingSSL:self.tls]) {
        self.connectedTo = self.host;
        
        NSMutableDictionary *subscriptions = [[NSMutableDictionary alloc] init];
        NSArray *topicFilters = [self.base componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        for (NSString *topicFilter in topicFilters) {
            if (topicFilter.length) {
                [subscriptions setObject:@(MQTTQosLevelAtMostOnce) forKey:topicFilter];
            }
        }
        
        [self.mqttSession subscribeToTopics:subscriptions];
        
        while (!self.terminate) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
        }
        
        [self.mqttSession unsubscribeTopics:topicFilters];
        [self.mqttSession close];
    } else {
        AppDelegate *delegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
        [delegate connectError:self];
    }
}

- (void)newMessage:(MQTTSession *)session data:(NSData *)data onTopic:(NSString *)topic qos:(MQTTQosLevel)qos retained:(BOOL)retained mid:(unsigned int)mid {
    DDLogVerbose(@"PUBLISH %@ %@", topic, data);
    AppDelegate *appDelegate = (AppDelegate *)[UIApplication sharedApplication].delegate;
    [appDelegate performSelector:@selector(processMessage:)
                                  withObject:@{@"topic": topic, @"data": data}];
}

- (void)handleEvent:(MQTTSession *)session event:(MQTTSessionEvent)eventCode error:(NSError *)error {
    switch (eventCode) {
        case MQTTSessionEventConnectionClosed:
        case MQTTSessionEventConnectionClosedByBroker:
            self.connectedTo = nil;
            break;
        case MQTTSessionEventConnected:
            break;
        default:
            self.error = error;
            break;
    }
}

@end
