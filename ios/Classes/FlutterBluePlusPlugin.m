// Copyright 2017, Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#import "FlutterBluePlusPlugin.h"

@interface ServicePair : NSObject
@property (strong, nonatomic) CBService *primary;
@property (strong, nonatomic) CBService *secondary;
@end

@implementation ServicePair
@end

@interface CBUUID (CBUUIDAdditionsFlutterBluePlus)
- (NSString *)fullUUIDString;
@end

@implementation CBUUID (CBUUIDAdditionsFlutterBluePlus)
- (NSString *)fullUUIDString
{
    if (self.UUIDString.length == 4)
    {
        return [[NSString stringWithFormat:@"0000%@-0000-1000-8000-00805F9B34FB", self.UUIDString] lowercaseString];
    }
    return [self.UUIDString lowercaseString];
}
@end

typedef NS_ENUM(NSUInteger, LogLevel) {
    none = 0,
    error = 1,
    warning = 2,
    info = 3,
    debug = 4,
    verbose = 5,
};

@interface FlutterBluePlusPlugin ()
@property(nonatomic, retain) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, retain) FlutterMethodChannel *methodChannel;
@property(nonatomic, retain) CBCentralManager *centralManager;
@property(nonatomic) NSMutableDictionary *scannedPeripherals;
@property(nonatomic) NSMutableArray *servicesThatNeedDiscovered;
@property(nonatomic) NSMutableArray *characteristicsThatNeedDiscovered;
@property(nonatomic) NSMutableDictionary *dataWaitingToWriteWithoutResponse;
@property(nonatomic) LogLevel logLevel;
@end

@implementation FlutterBluePlusPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar
{
    FlutterMethodChannel *methodChannel = [FlutterMethodChannel methodChannelWithName:NAMESPACE @"/methods"
                                                                binaryMessenger:[registrar messenger]];
    FlutterBluePlusPlugin *instance = [[FlutterBluePlusPlugin alloc] init];
    instance.methodChannel = methodChannel;
    instance.scannedPeripherals = [NSMutableDictionary new];
    instance.servicesThatNeedDiscovered = [NSMutableArray new];
    instance.characteristicsThatNeedDiscovered = [NSMutableArray new];
    instance.dataWaitingToWriteWithoutResponse = [NSMutableDictionary new];
    instance.logLevel = debug;

    [registrar addMethodCallDelegate:instance channel:methodChannel];
}

////////////////////////////////////////////////////////////
// ██   ██   █████   ███    ██  ██████   ██       ███████    
// ██   ██  ██   ██  ████   ██  ██   ██  ██       ██         
// ███████  ███████  ██ ██  ██  ██   ██  ██       █████      
// ██   ██  ██   ██  ██  ██ ██  ██   ██  ██       ██         
// ██   ██  ██   ██  ██   ████  ██████   ███████  ███████                                                       
//                                                      
// ███    ███  ███████  ████████  ██   ██   ██████   ██████  
// ████  ████  ██          ██     ██   ██  ██    ██  ██   ██ 
// ██ ████ ██  █████       ██     ███████  ██    ██  ██   ██ 
// ██  ██  ██  ██          ██     ██   ██  ██    ██  ██   ██ 
// ██      ██  ███████     ██     ██   ██   ██████   ██████                                              
//                                                      
//  ██████   █████   ██       ██                           
// ██       ██   ██  ██       ██                           
// ██       ███████  ██       ██                           
// ██       ██   ██  ██       ██                           
//  ██████  ██   ██  ███████  ███████                     

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result
{
    @try
    {
        if (_logLevel >= debug) {
            NSLog(@"[FBP-iOS] handleMethodCall: %@", call.method);
        }
        // initialize adapter
        if (self.centralManager == nil)
        {
            NSDictionary *options = @{
                CBCentralManagerOptionShowPowerAlertKey: @(YES)
            };

            self.centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil options:options];
        }
        // check that we have an adapter
        if (self.centralManager == nil && [@"getAdapterState" isEqualToString:call.method] == false) {
            NSString* s = @"the device does not have bluetooth";
            result([FlutterError errorWithCode:@"bluetooth_unavailable" message:s details:NULL]);
            return;
        }
        
        if ([@"setLogLevel" isEqualToString:call.method])
        {
            NSNumber *logLevelIndex = [call arguments];
            _logLevel = (LogLevel)[logLevelIndex integerValue];
            result(@(true));
            return;
        }
        if ([@"getAdapterState" isEqualToString:call.method])
        {
            // get state
            int adapterState = 0; // BmAdapterStateEnum.unknown
            if (self->_centralManager) {
                adapterState = [self toAdapterStateInt:self->_centralManager.state];    
            }

            // See BmBluetoothAdapterState
            NSDictionary* response = @{
                @"adapter_state" : @(adapterState),
            };

            result(response);
        }
        else if ([@"isAvailable" isEqualToString:call.method])
        {
            if (self.centralManager &&
                self.centralManager.state != CBManagerStateUnsupported &&
                self.centralManager.state != CBManagerStateUnknown)
            {
                result(@(YES));
            }
            else
            {
                result(@(NO));
            }
        }
        else if ([@"isOn" isEqualToString:call.method])
        {
            if (self.centralManager.state == CBManagerStatePoweredOn)
            {
                result(@(YES));
            }
            else
            {
                result(@(NO));
            }
        }
        else if ([@"getAdapterName" isEqualToString:call.method])
        {
    #if TARGET_OS_IOS
            result([[UIDevice currentDevice] name]);
    #else // MacOS
            // TODO: support this via hostname?
            result(@"Mac Bluetooth Adapter");
    #endif
        }
        else if ([@"startScan" isEqualToString:call.method])
        {
            // See BmScanSettings
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSArray   *serviceUuids    = args[@"service_uuids"];
            NSNumber  *allowDuplicates = args[@"allow_duplicates"];

            // UUID Service filter
            NSArray *uuids = [NSArray array];
            for (int i = 0; i < [serviceUuids count]; i++) {
                NSString *u = serviceUuids[i];
                uuids = [uuids arrayByAddingObject:[CBUUID UUIDWithString:u]];
            }

            // Allow duplicates?
            NSMutableDictionary<NSString *, id> *scanOpts = [NSMutableDictionary new];
            if ([allowDuplicates boolValue]) {
                [scanOpts setObject:[NSNumber numberWithBool:YES] forKey:CBCentralManagerScanOptionAllowDuplicatesKey];
            }

            // Start scanning
            [self->_centralManager scanForPeripheralsWithServices:uuids options:scanOpts];

            result(@(true));
        }
        else if ([@"stopScan" isEqualToString:call.method])
        {
            [self->_centralManager stopScan];
            result(@(true));
        }
        else if ([@"getConnectedDevices" isEqualToString:call.method])
        {
            // Generic Access service 0x1800
            CBUUID* gasUuid = [CBUUID UUIDWithString:@"1800"];

            // Cannot pass blank UUID list for security reasons.
            // Assume all devices have the Generic Access service
            NSArray *periphs = [self->_centralManager retrieveConnectedPeripheralsWithServices:@[gasUuid]];

            // Devices
            NSMutableArray *deviceProtos = [NSMutableArray new];
            for (CBPeripheral *p in periphs) {
                [deviceProtos addObject:[self toDeviceProto:p]];
            }

            // See BmConnectedDevicesResponse
            NSDictionary* response = @{
                @"devices": deviceProtos,
            };

            result(response);
        }
        else if ([@"connect" isEqualToString:call.method])
        {
            // See BmConnectRequest
            NSDictionary* args = (NSDictionary*)call.arguments;
            NSString  *remoteId = args[@"remote_id"];
            bool autoConnect    = args[@"auto_connect"] != 0;

            CBPeripheral *peripheral = nil; 
            if (peripheral == nil)
            {
                peripheral = [self findPeripheral:remoteId];
            }
            if (peripheral == nil)
            {
                peripheral = [_scannedPeripherals objectForKey:remoteId];
            }
            if (peripheral == nil)
            {
                // Generic Access service 0x1800
                CBUUID* gasUuid = [CBUUID UUIDWithString:@"1800"];

                NSArray *periphs = [self->_centralManager retrieveConnectedPeripheralsWithServices:@[gasUuid]];

                for (CBPeripheral *p in periphs) {
                    p.delegate = self;
                    NSString *uuid = [[p identifier] UUIDString];
                    [_scannedPeripherals setObject:p forKey:uuid];
                }

                peripheral = [_scannedPeripherals objectForKey:remoteId];
            }
            if (peripheral == nil)
            {
                result([FlutterError errorWithCode:@"connect" message:@"Peripheral not found" details:nil]);
                return;
            }

            // options
            NSMutableDictionary *options = [[NSMutableDictionary alloc] init];
            if (@available(iOS 17, *)) {
                // note: use CBConnectPeripheralOptionEnableAutoReconnect constant
                // when iOS 17 is more widely available
                [options setObject:@(autoConnect) forKey:@"kCBConnectOptionEnableAutoReconnect"];
            } 

            [_centralManager connectPeripheral:peripheral options:options];
            
            result(@(true));
        }
        else if ([@"disconnect" isEqualToString:call.method])
        {
            // remoteId is passed raw, not in a NSDictionary
            NSString *remoteId = [call arguments];

            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"peripheral not found.";
                result([FlutterError errorWithCode:@"disconnect" message:s details:NULL]);
                return;
            }

            [_centralManager cancelPeripheralConnection:peripheral];
            
            result(@(true));
        }
        else if ([@"getConnectionState" isEqualToString:call.method])
        {
            // remoteId is passed raw, not in a NSDictionary
            NSString *remoteId = [call arguments];
 
            // get the connection state
            // note: if the peripheral is not found it is considered disconnected
            CBPeripheralState connectionState = CBPeripheralStateDisconnected;
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            if (peripheral) {
                connectionState = peripheral.state;
            }

            // See BmConnectionStateResponse
            NSDictionary* response = @{
                @"remote_id":        remoteId,
                @"connection_state": @([self connectionStateInt:connectionState]),
            };

            result(response);
        }
        else if ([@"discoverServices" isEqualToString:call.method])
        {
            // remoteId is passed raw, not in a NSDictionary
            NSString *remoteId = [call arguments];

            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"peripheral not found. try reconnecting.";
                result([FlutterError errorWithCode:@"discoverServices" message:s details:NULL]);
                return;
            }

            // check connected
            if (peripheral.state != CBPeripheralStateConnected) {
                NSString* s = @"device is not connected";
                result([FlutterError errorWithCode:@"discoverServices" message:s details:NULL]);
                return;
            }

            // Clear helper arrays
            [_servicesThatNeedDiscovered removeAllObjects];
            [_characteristicsThatNeedDiscovered removeAllObjects];

            // start discovery
            [peripheral discoverServices:nil];

            result(@(true));
        }
        else if ([@"services" isEqualToString:call.method])
        {
            // remoteId is passed raw, not in a NSDictionary
            NSString *remoteId = [call arguments];

            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"peripheral not found. try reconnecting.";
                result([FlutterError errorWithCode:@"services" message:s details:NULL]);
                return;
            }

            // Services
            NSMutableArray *services = [NSMutableArray new];
            for (CBService *s in [peripheral services])
            {
                [services addObject:[self toServiceProto:peripheral service:s]];
            }

            // See BmDiscoverServicesResult
            NSDictionary* response = @{
                @"remote_id":       [peripheral.identifier UUIDString],
                @"services":        services,
                @"success":         @(1),
                @"error_string":    [NSNull null],
                @"error_code":      [NSNull null],
            };

            result(response);
        }
        else if ([@"readCharacteristic" isEqualToString:call.method])
        {
            // See BmReadCharacteristicRequest
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSString  *remoteId             = args[@"remote_id"];
            NSString  *characteristicUuid   = args[@"characteristic_uuid"];
            NSString  *serviceUuid          = args[@"service_uuid"];
            NSString  *secondaryServiceUuid = args[@"secondary_service_uuid"];

            // Find peripheral
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"peripheral not found. try reconnecting.";
                result([FlutterError errorWithCode:@"readCharacteristic" message:s details:NULL]);
                return;
            }

            // check connected
            if (peripheral.state != CBPeripheralStateConnected) {
                NSString* s = @"device is not connected";
                result([FlutterError errorWithCode:@"readCharacteristic" message:s details:NULL]);
                return;
            }

            // Find characteristic
            NSError *error = nil;
            CBCharacteristic *characteristic = [self locateCharacteristic:characteristicUuid
                                                               peripheral:peripheral
                                                                serviceId:serviceUuid
                                                       secondaryServiceId:secondaryServiceUuid
                                                                    error:&error];
            if (characteristic == nil) {
                result([FlutterError errorWithCode:@"readCharacteristic" message:error.localizedDescription details:NULL]);
                return;
            }

            // Trigger a read
            [peripheral readValueForCharacteristic:characteristic];

            result(@(true));
        }
        else if ([@"readDescriptor" isEqualToString:call.method])
        {
            // See BmReadDescriptorRequest
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSString  *remoteId             = args[@"remote_id"];
            NSString  *descriptorUuid       = args[@"descriptor_uuid"];
            NSString  *serviceUuid          = args[@"service_uuid"];
            NSString  *secondaryServiceUuid = args[@"secondary_service_uuid"];
            NSString  *characteristicUuid   = args[@"characteristic_uuid"];

            // Find peripheral
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"peripheral not found. try reconnecting.";
                result([FlutterError errorWithCode:@"readDescriptor" message:s details:NULL]);
                return;
            }

            // check connected
            if (peripheral.state != CBPeripheralStateConnected) {
                NSString* s = @"device is not connected";
                result([FlutterError errorWithCode:@"readDescriptor" message:s details:NULL]);
                return;
            }

            // Find characteristic
            NSError *error = nil;
            CBCharacteristic *characteristic = [self locateCharacteristic:characteristicUuid
                                                               peripheral:peripheral
                                                                serviceId:serviceUuid
                                                       secondaryServiceId:secondaryServiceUuid
                                                                    error:&error];
            if (characteristic == nil) {
                result([FlutterError errorWithCode:@"readDescriptor" message:error.localizedDescription details:NULL]);
                return;
            }

            // Find descriptor
            CBDescriptor *descriptor = [self locateDescriptor:descriptorUuid characteristic:characteristic error:&error];
            if (descriptor == nil) {
                result([FlutterError errorWithCode:@"readDescriptor" message:error.localizedDescription details:NULL]);
                return;
            }

            [peripheral readValueForDescriptor:descriptor];

            result(@(true));
        }
        else if ([@"writeCharacteristic" isEqualToString:call.method])
        {
            // See BmWriteCharacteristicRequest
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSString  *remoteId             = args[@"remote_id"];
            NSString  *characteristicUuid   = args[@"characteristic_uuid"];
            NSString  *serviceUuid          = args[@"service_uuid"];
            NSString  *secondaryServiceUuid = args[@"secondary_service_uuid"];
            NSNumber  *writeType            = args[@"write_type"];
            NSString  *value                = args[@"value"];
            
            // Find peripheral
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"peripheral not found. try reconnecting.";
                result([FlutterError errorWithCode:@"writeCharacteristic" message:s details:NULL]);
                return;
            }

            // check connected
            if (peripheral.state != CBPeripheralStateConnected) {
                NSString* s = @"device is not connected";
                result([FlutterError errorWithCode:@"writeCharacteristic" message:s details:NULL]);
                return;
            }

            // Get correct write type
            CBCharacteristicWriteType type =
                ([writeType intValue] == 0
                    ? CBCharacteristicWriteWithResponse
                    : CBCharacteristicWriteWithoutResponse);

            // check mtu
            int mtu = (int) [peripheral maximumWriteValueLengthForType:type];
            int dataLen = (int) [self convertHexToData:value].length;
            if (mtu < dataLen) {
                NSString* f = @"data is longer than MTU allows. dataLen: %d > maxDataLen: %d";
                NSString* s = [NSString stringWithFormat:f, dataLen, mtu];
                result([FlutterError errorWithCode:@"writeCharacteristic" message:s details:NULL]);
                return;
            }

            // device not ready?
            if (type == CBCharacteristicWriteWithoutResponse && !peripheral.canSendWriteWithoutResponse) {
                // canSendWriteWithoutResponse is the current readiness of the peripheral to accept
                // more write requests. If the peripheral isn't ready, we queue the request for later.
                [_dataWaitingToWriteWithoutResponse setObject:args forKey:remoteId];
                result(@(true));
                return;
            } 

            // Find characteristic
            NSError *error = nil;
            CBCharacteristic *characteristic = [self locateCharacteristic:characteristicUuid
                                                               peripheral:peripheral
                                                                serviceId:serviceUuid
                                                       secondaryServiceId:secondaryServiceUuid
                                                                    error:&error];
            if (characteristic == nil) {
                result([FlutterError errorWithCode:@"writeCharacteristic" message:error.localizedDescription details:NULL]);
                return;
            }
                  
            // Write to characteristic
            [peripheral writeValue:[self convertHexToData:value] forCharacteristic:characteristic type:type];

            result(@(YES));
        }
        else if ([@"writeDescriptor" isEqualToString:call.method])
        {
            // See BmWriteDescriptorRequest
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSString  *remoteId             = args[@"remote_id"];
            NSString  *descriptorUuid       = args[@"descriptor_uuid"];
            NSString  *serviceUuid          = args[@"service_uuid"];
            NSString  *secondaryServiceUuid = args[@"secondary_service_uuid"];
            NSString  *characteristicUuid   = args[@"characteristic_uuid"];
            NSString  *value                = args[@"value"];

            // Find peripheral
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"peripheral not found. try reconnecting.";
                result([FlutterError errorWithCode:@"writeDescriptor" message:s details:NULL]);
                return;
            }

            // check connected
            if (peripheral.state != CBPeripheralStateConnected) {
                NSString* s = @"device is not connected";
                result([FlutterError errorWithCode:@"writeDescriptor" message:s details:NULL]);
                return;
            }

            // check mtu
            int mtu = (int) [self getMtu:peripheral];
            int dataLen = (int) [self convertHexToData:value].length;
            if (mtu < dataLen) {
                NSString* f = @"data is longer than MTU allows. dataLen: %d > maxDataLen: %d";
                NSString* s = [NSString stringWithFormat:f, dataLen, mtu];
                result([FlutterError errorWithCode:@"writeDescriptor" message:s details:NULL]);
                return;
            }

            // Find characteristic
            NSError *error = nil;
            CBCharacteristic *characteristic = [self locateCharacteristic:characteristicUuid
                                                               peripheral:peripheral
                                                                serviceId:serviceUuid
                                                       secondaryServiceId:secondaryServiceUuid
                                                                    error:&error];
            if (characteristic == nil) {
                result([FlutterError errorWithCode:@"writeDescriptor" message:error.localizedDescription details:NULL]);
                return;
            }

            // Find descriptor
            CBDescriptor *descriptor = [self locateDescriptor:descriptorUuid characteristic:characteristic error:&error];
            if (descriptor == nil) {
                result([FlutterError errorWithCode:@"writeDescriptor" message:error.localizedDescription details:NULL]);
                return;
            }

            // Write descriptor
            [peripheral writeValue:[self convertHexToData:value] forDescriptor:descriptor];

            result(@(true));
        }
        else if ([@"setNotification" isEqualToString:call.method])
        {
            // See BmSetNotificationRequest
            NSDictionary *args = (NSDictionary*)call.arguments;
            NSString   *remoteId              = args[@"remote_id"];
            NSString   *serviceUuid           = args[@"service_uuid"];
            NSString   *secondaryServiceUuid  = args[@"secondary_service_uuid"];
            NSString   *characteristicUuid    = args[@"characteristic_uuid"];
            NSNumber   *enable                = args[@"enable"];

            // Find peripheral
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"peripheral not found. try reconnecting.";
                result([FlutterError errorWithCode:@"setNotification" message:s details:NULL]);
                return;
            }

            // check connected
            if (peripheral.state != CBPeripheralStateConnected) {
                NSString* s = @"device is not connected";
                result([FlutterError errorWithCode:@"setNotification" message:s details:NULL]);
                return;
            }

            // Find characteristic
            NSError *error = nil;
            CBCharacteristic *characteristic = [self locateCharacteristic:characteristicUuid
                                                               peripheral:peripheral
                                                                serviceId:serviceUuid
                                                       secondaryServiceId:secondaryServiceUuid
                                                                    error:&error];
            if (characteristic == nil) {
                result([FlutterError errorWithCode:@"setNotification" message:error.localizedDescription details:NULL]);
                return;
            }

            // Set notification value
            [peripheral setNotifyValue:[enable boolValue] forCharacteristic:characteristic];
            
            result(@(true));
        }
        else if ([@"mtu" isEqualToString:call.method])
        {
            // remoteId is passed raw, not in a NSDictionary
            NSString *remoteId = [call arguments];

            // get peripheral
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"peripheral not found. try reconnecting.";
                result([FlutterError errorWithCode:@"mtu" message:s details:NULL]);
                return;
            }

            // get mtu
            uint32_t mtu = [self getMtu:peripheral];

            // See: BmMtuSizeResponse
            NSDictionary* response = @{
                @"remote_id" : [[peripheral identifier] UUIDString],
                @"mtu" : @(mtu),
                @"success" : @(1),
            };
            
            result(response);
        }
        else if ([@"requestMtu" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"requestMtu"
                                    message:@"iOS does not allow mtu requests to the peripheral"
                                    details:NULL]);
        }
        else if ([@"readRssi" isEqualToString:call.method])
        {
            // remoteId is passed raw, not in a NSDictionary
            NSString *remoteId = [call arguments];

            // get peripheral
            CBPeripheral *peripheral = [self findPeripheral:remoteId];
            if (peripheral == nil) {
                NSString* s = @"peripheral not found. try reconnecting.";
                result([FlutterError errorWithCode:@"readRssi" message:s details:NULL]);
                return;
            }

            // check connected
            if (peripheral.state != CBPeripheralStateConnected) {
                NSString* s = @"device is not connected";
                result([FlutterError errorWithCode:@"readRssi" message:s details:NULL]);
                return;
            }

            [peripheral readRSSI];

            result(@(true));
        }
        else if([@"requestConnectionPriority" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"requestConnectionPriority" 
                                    message:@"iOS does not support connection priority requests"
                                    details:NULL]);
        }
        else if([@"setPreferredPhy" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"setPreferredPhy" 
                                    message:@"iOS does not support set preferred phy requests"
                                    details:NULL]);
        }
        else if([@"removeBond" isEqualToString:call.method])
        {
            result([FlutterError errorWithCode:@"removeBond" 
                                    message:@"plugin does not support removeBond function on iOS"
                                    details:NULL]);
        }
        else
        {
            result(FlutterMethodNotImplemented);
        }
    }
    @catch (NSException *e)
    {
        NSString *stackTrace = [[e callStackSymbols] componentsJoinedByString:@"\n"];
        NSDictionary *details = @{@"stackTrace": stackTrace};
        result([FlutterError errorWithCode:@"iosException" message:[e reason] details:details]);
    }
}

//////////////////////////////////////////////////////////////////////
// ██████   ██████   ██  ██    ██   █████   ████████  ███████ 
// ██   ██  ██   ██  ██  ██    ██  ██   ██     ██     ██      
// ██████   ██████   ██  ██    ██  ███████     ██     █████   
// ██       ██   ██  ██   ██  ██   ██   ██     ██     ██      
// ██       ██   ██  ██    ████    ██   ██     ██     ███████
//
// ██    ██  ████████  ██  ██       ███████ 
// ██    ██     ██     ██  ██       ██      
// ██    ██     ██     ██  ██       ███████ 
// ██    ██     ██     ██  ██            ██ 
//  ██████      ██     ██  ███████  ███████ 

- (NSData *)convertHexToData:(NSString *)hexString
{
    if (hexString.length % 2 != 0) {
        return nil;
    }

    NSMutableData *data = [NSMutableData new];

    for (NSInteger i = 0; i < hexString.length; i += 2) {
        unsigned int byte = 0;
        NSRange range = NSMakeRange(i, 2);
        [[NSScanner scannerWithString:[hexString substringWithRange:range]] scanHexInt:&byte];
        [data appendBytes:&byte length:1];
    }

    return [data copy];
}

- (CBPeripheral *)findPeripheral:(NSString *)remoteId
{
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:remoteId];

    NSArray<CBPeripheral *> *peripherals = [_centralManager retrievePeripheralsWithIdentifiers:@[uuid]];

    CBPeripheral *peripheral;
    for (CBPeripheral *p in peripherals)
    {
        if ([[p.identifier UUIDString] isEqualToString:remoteId])
        {
            peripheral = p;
            break;
        }
    }
    return peripheral;
}

- (CBCharacteristic *)locateCharacteristic:(NSString *)characteristicId
                                peripheral:(CBPeripheral *)peripheral
                                 serviceId:(NSString *)serviceId
                        secondaryServiceId:(NSString *)secondaryServiceId
                                     error:(NSError **)error
{
    CBService *primaryService = [self getServiceFromArray:serviceId array:[peripheral services]];
    if (primaryService == nil || [primaryService isPrimary] == false)
    {
        NSDictionary* d = @{NSLocalizedDescriptionKey : @"service could not be located on the device"};
        *error = [NSError errorWithDomain:@"flutterBluePlus" code:1000 userInfo:d];
        return nil;
    }

    CBService *secondaryService;
    if (secondaryServiceId && (NSNull*) secondaryServiceId != [NSNull null] && secondaryServiceId.length)
    {
        secondaryService = [self getServiceFromArray:secondaryServiceId array:[primaryService includedServices]];
        if (error && !secondaryService) {
            NSString* s = [NSString stringWithFormat:@"secondary service '%@' could not be located on the device", secondaryServiceId];
            NSDictionary* d = @{NSLocalizedDescriptionKey : s};
            *error = [NSError errorWithDomain:@"flutterBluePlus" code:1001 userInfo:d];
            return nil;
        }
    }

    CBService *service = (secondaryService != nil) ? secondaryService : primaryService;

    CBCharacteristic *characteristic = [self getCharacteristicFromArray:characteristicId array:[service characteristics]];
    if (characteristic == nil)
    {
        NSDictionary* d = @{NSLocalizedDescriptionKey : @"characteristic could not be located on the device"};
        *error = [NSError errorWithDomain:@"flutterBluePlus" code:1002 userInfo:d];
        return nil;
    }
    return characteristic;
}


- (CBDescriptor *)locateDescriptor:(NSString *)descriptorId characteristic:(CBCharacteristic *)characteristic error:(NSError**)error
{
    CBDescriptor *descriptor = [self getDescriptorFromArray:descriptorId array:[characteristic descriptors]];
    if (descriptor == nil)
    {
        NSDictionary* d = @{NSLocalizedDescriptionKey : @"descriptor could not be located on the device"};
        *error = [NSError errorWithDomain:@"flutterBluePlus" code:1002 userInfo:d];
        return nil;
    }
    return descriptor;
}

- (CBService *)getServiceFromArray:(NSString *)uuidString array:(NSArray<CBService *> *)array
{
    for (CBService *s in array)
    {
        if ([[s UUID] isEqual:[CBUUID UUIDWithString:uuidString]])
        {
            return s;
        }
    }
    return nil;
}

- (CBCharacteristic *)getCharacteristicFromArray:(NSString *)uuidString array:(NSArray<CBCharacteristic *> *)array
{
    for (CBCharacteristic *c in array)
    {
        if ([[c UUID] isEqual:[CBUUID UUIDWithString:uuidString]])
        {
            return c;
        }
    }
    return nil;
}

- (CBDescriptor *)getDescriptorFromArray:(NSString *)uuidString array:(NSArray<CBDescriptor *> *)array
{
    for (CBDescriptor *d in array)
    {
        if ([[d UUID] isEqual:[CBUUID UUIDWithString:uuidString]])
        {
            return d;
        }
    }
    return nil;
}


/////////////////////////////////////////////////////////////////////////////////////
//  ██████  ██████    ██████  ███████  ███    ██  ████████  ██████    █████  ██      
// ██       ██   ██  ██       ██       ████   ██     ██     ██   ██  ██   ██ ██      
// ██       ██████   ██       █████    ██ ██  ██     ██     ██████   ███████ ██      
// ██       ██   ██  ██       ██       ██  ██ ██     ██     ██   ██  ██   ██ ██      
//  ██████  ██████    ██████  ███████  ██   ████     ██     ██   ██  ██   ██ ███████ 
//                                                                                                                                          
// ███    ███   █████   ███    ██   █████    ██████   ███████  ██████               
// ████  ████  ██   ██  ████   ██  ██   ██  ██        ██       ██   ██              
// ██ ████ ██  ███████  ██ ██  ██  ███████  ██   ███  █████    ██████               
// ██  ██  ██  ██   ██  ██  ██ ██  ██   ██  ██    ██  ██       ██   ██              
// ██      ██  ██   ██  ██   ████  ██   ██   ██████   ███████  ██   ██              
//                                                                                                                                                   
// ██████   ███████  ██       ███████   ██████    █████   ████████  ███████          
// ██   ██  ██       ██       ██       ██        ██   ██     ██     ██               
// ██   ██  █████    ██       █████    ██   ███  ███████     ██     █████            
// ██   ██  ██       ██       ██       ██    ██  ██   ██     ██     ██               
// ██████   ███████  ███████  ███████   ██████   ██   ██     ██     ███████ 

- (void)centralManagerDidUpdateState:(nonnull CBCentralManager *)central
{
    if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] centralManagerDidUpdateState %li", self->_centralManager.state);
    }

    int adapterState = [self toAdapterStateInt:self->_centralManager.state];

    // See BmBluetoothAdapterState
    NSDictionary* response = @{
        @"adapter_state" : @(adapterState),
    };

    [_methodChannel invokeMethod:@"adapterStateChanged" arguments:response];
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
        advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                     RSSI:(NSNumber *)RSSI
{
    if (_logLevel >= verbose) {
        NSLog(@"[FBP-iOS] centralManager didDiscoverPeripheral");
    }
    
    [self.scannedPeripherals setObject:peripheral forKey:[[peripheral identifier] UUIDString]];

    // See BmScanResult
    NSDictionary *result = [self toScanResultProto:peripheral advertisementData:advertisementData RSSI:RSSI];

    // See BmScanResponse
    NSDictionary *response = @{
        @"result": result,
    };

    [_methodChannel invokeMethod:@"ScanResponse" arguments:response];
}

- (void)centralManager:(CBCentralManager *)central
  didConnectPeripheral:(CBPeripheral *)peripheral
{
    if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didConnectPeripheral");
    }

    // Register self as delegate for peripheral
    peripheral.delegate = self;

    // See BmConnectionStateResponse
    NSDictionary *result = @{
        @"remote_id":        [[peripheral identifier] UUIDString],
        @"connection_state": @([self connectionStateInt:peripheral.state]),
    };

    // Send connection state
    [_methodChannel invokeMethod:@"connectionStateChanged" arguments:result];
}

- (void)centralManager:(CBCentralManager *)central
    didDisconnectPeripheral:(CBPeripheral *)peripheral
                      error:(NSError *)error
{
    if (error) {
        // error contains the reason for the unexpected disconnection
        NSLog(@"[FBP-iOS] didDisconnectPeripheral: [Error] %@", [error localizedDescription]);
    } else if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didDisconnectPeripheral");
    }

    // Unregister self as delegate for peripheral, not working #42
    peripheral.delegate = nil;

    // See BmConnectionStateResponse
    NSDictionary *result = @{
        @"remote_id":        [[peripheral identifier] UUIDString],
        @"connection_state": @([self connectionStateInt:peripheral.state]),
    };

    // Send connection state
    [_methodChannel invokeMethod:@"connectionStateChanged" arguments:result];
}

- (void)centralManager:(CBCentralManager *)central
    didFailToConnectPeripheral:(CBPeripheral *)peripheral
                         error:(NSError *)error
{
    if (error) {
        // error contains the reason for the connection failure
        NSLog(@"[FBP-iOS] didFailToConnectPeripheral: [Error] %@", [error localizedDescription]);
    } else if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didFailToConnectPeripheral");
    }

    // See BmConnectionStateResponse
    NSDictionary *result = @{
        @"remote_id":        [[peripheral identifier] UUIDString],
        @"connection_state": @([self connectionStateInt:peripheral.state]),
    };

    // Send connection state
    [_methodChannel invokeMethod:@"connectionStateChanged" arguments:result];
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////
//  ██████  ██████   ██████   ███████  ██████   ██  ██████   ██   ██  ███████  ██████    █████   ██      
// ██       ██   ██  ██   ██  ██       ██   ██  ██  ██   ██  ██   ██  ██       ██   ██  ██   ██  ██      
// ██       ██████   ██████   █████    ██████   ██  ██████   ███████  █████    ██████   ███████  ██      
// ██       ██   ██  ██       ██       ██   ██  ██  ██       ██   ██  ██       ██   ██  ██   ██  ██      
//  ██████  ██████   ██       ███████  ██   ██  ██  ██       ██   ██  ███████  ██   ██  ██   ██  ███████
//
// ██████   ███████  ██       ███████   ██████    █████   ████████  ███████          
// ██   ██  ██       ██       ██       ██        ██   ██     ██     ██               
// ██   ██  █████    ██       █████    ██   ███  ███████     ██     █████            
// ██   ██  ██       ██       ██       ██    ██  ██   ██     ██     ██               
// ██████   ███████  ███████  ███████   ██████   ██   ██     ██     ███████ 

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
    if (error) {
        NSLog(@"[FBP-iOS] didDiscoverServices: [Error] %@", [error localizedDescription]);
    } else if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didDiscoverServices");
    }

    // See: BmMtuSizeResponse
    NSDictionary* response = @{
        @"remote_id" : [[peripheral identifier] UUIDString],
        @"mtu" : @([self getMtu:peripheral]),
        @"success" : @(1),
    };

    [_methodChannel invokeMethod:@"MtuSize" arguments:response];

    // discover characteristics and secondary services
    [_servicesThatNeedDiscovered addObjectsFromArray:peripheral.services];
    for (CBService *s in [peripheral services]) {
        NSLog(@"[FBP-iOS] Found service: %@", [s.UUID UUIDString]);
        [peripheral discoverCharacteristics:nil forService:s];
        // [peripheral discoverIncludedServices:nil forService:s]; // Secondary services in the future (#8)
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverCharacteristicsForService:(CBService *)service
                                   error:(NSError *)error
{
    if (error) {
        NSLog(@"[FBP-iOS] didDiscoverCharacteristicsForService: [Error] %@", [error localizedDescription]);
    } else if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didDiscoverCharacteristicsForService");
    }

    // Loop through and discover descriptors for characteristics
    [_servicesThatNeedDiscovered removeObject:service];
    [_characteristicsThatNeedDiscovered addObjectsFromArray:service.characteristics];
    for (CBCharacteristic *c in [service characteristics])
    {
        [peripheral discoverDescriptorsForCharacteristic:c];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverDescriptorsForCharacteristic:(CBCharacteristic *)characteristic
                                      error:(NSError *)error
{
    if (error) {
        NSLog(@"[FBP-iOS] didDiscoverDescriptorsForCharacteristic: [Error] %@", [error localizedDescription]);
    } else if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didDiscoverDescriptorsForCharacteristic");
    }

    [_characteristicsThatNeedDiscovered removeObject:characteristic];
    if (_servicesThatNeedDiscovered.count > 0 || _characteristicsThatNeedDiscovered.count > 0)
    {
        // Still discovering
        return;
    }

    // Services
    NSMutableArray *services = [NSMutableArray new];
    for (CBService *s in [peripheral services])
    {
        [services addObject:[self toServiceProto:peripheral service:s]];
    }

    // See BmDiscoverServicesResult
    NSDictionary* response = @{
        @"remote_id":       [peripheral.identifier UUIDString],
        @"services":        services,
        @"success":         error == nil ? @(1) : @(0),
        @"error_string":    error ? [error localizedDescription] : [NSNull null],
        @"error_code":      error ? @(error.code) : [NSNull null],
    };

    // Send updated tree
    [_methodChannel invokeMethod:@"DiscoverServicesResult" arguments:response];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverIncludedServicesForService:(CBService *)service
                                    error:(NSError *)error
{
    if (error) {
        NSLog(@"[FBP-iOS] didDiscoverIncludedServicesForService: [Error] %@", [error localizedDescription]);
    } else if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didDiscoverIncludedServicesForService");
    }

    // Loop through and discover characteristics for secondary services
    for (CBService *ss in [service includedServices])
    {
        [peripheral discoverCharacteristics:nil forService:ss];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
                              error:(NSError *)error
{
    // this callback is called for notifications as well as manual reads
    if (error) {
        NSLog(@"[FBP-iOS] didUpdateValueForCharacteristic: [Error] %@", [error localizedDescription]);
    } else if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didUpdateValueForCharacteristic %@", [peripheral.identifier UUIDString]);
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:characteristic];

    // See BmOnCharacteristicReceived
    NSDictionary* result = @{
        @"remote_id":               [peripheral.identifier UUIDString],
        @"service_uuid":            [pair.primary.UUID fullUUIDString],
        @"secondary_service_uuid":  pair.secondary ? [pair.secondary.UUID fullUUIDString] : [NSNull null],
        @"characteristic_uuid":     [characteristic.UUID fullUUIDString],
        @"value":                   [self convertDataToHex:characteristic.value],
        @"success":                 error == nil ? @(1) : @(0),
        @"error_string":            error ? [error localizedDescription] : [NSNull null],
        @"error_code":              error ? @(error.code) : [NSNull null],
    };

    [_methodChannel invokeMethod:@"OnCharacteristicReceived" arguments:result];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
                             error:(NSError *)error
{
    // this callback is called after write() is explicitly called
    if (error) {
        NSLog(@"[FBP-iOS] didWriteValueForCharacteristic: [Error] %@", [error localizedDescription]);
    } else if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didWriteValueForCharacteristic");
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:characteristic];

    // See BmOnCharacteristicWritten
    NSDictionary* result = @{
        @"remote_id":               [peripheral.identifier UUIDString],
        @"service_uuid":            [pair.primary.UUID fullUUIDString],
        @"secondary_service_uuid":  pair.secondary ? [pair.secondary.UUID fullUUIDString] : [NSNull null],
        @"characteristic_uuid":     [characteristic.UUID fullUUIDString],
        @"success":                 @(error == nil),
        @"error_string":            error ? [error localizedDescription] : [NSNull null],
        @"error_code":              error ? @(error.code) : [NSNull null],
    };

    [_methodChannel invokeMethod:@"OnCharacteristicWritten" arguments:result];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
                                          error:(NSError *)error
{
    if (error) {
        NSLog(@"[FBP-iOS] didUpdateNotificationStateForCharacteristic: [Error] %@", [error localizedDescription]);
    } else if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didUpdateNotificationStateForCharacteristic");
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:characteristic];

    // Oddly iOS does not update the CCCD descriptors when didUpdateNotificationState is called. 
    // So instead of using characteristic.descriptors we have to manually recreate the
    // CCCD descriptor using isNotifying & characteristic.properties
    int value = 0;
    if(characteristic.isNotifying) {
        // in iOS, if a characteristic supports both indications and notifications, 
        // then CoreBluetooth will default to indications
        bool supportsNotify = (characteristic.properties & CBCharacteristicPropertyNotify) != 0;
        bool supportsIndicate = (characteristic.properties & CBCharacteristicPropertyIndicate) != 0;
        if (characteristic.isNotifying && supportsIndicate) {value = 2;} // '2' comes from the CCCD BLE spec
        if (characteristic.isNotifying && supportsNotify) {value = 1;} // '1' comes from the CCCD BLE spec
    }
    
    // See BmOnDescriptorResponse
    NSDictionary* result = @{
        @"type":                   @(1), // type: write
        @"remote_id":              [peripheral.identifier UUIDString],
        @"service_uuid":           [pair.primary.UUID fullUUIDString],
        @"secondary_service_uuid": pair.secondary ? [pair.secondary.UUID fullUUIDString] : [NSNull null],
        @"characteristic_uuid":    [characteristic.UUID fullUUIDString],
        @"descriptor_uuid":        @"00002902-0000-1000-8000-00805f9b34fb", // uuid of CCCD
        @"value":                  [self convertDataToHex:[NSData dataWithBytes:&value length:sizeof(value)]],
        @"success":                @(error == nil),
        @"error_string":           error ? [error localizedDescription] : [NSNull null],
        @"error_code":             error ? @(error.code) : [NSNull null],
    };

    [_methodChannel invokeMethod:@"OnDescriptorResponse" arguments:result];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateValueForDescriptor:(CBDescriptor *)descriptor
                          error:(NSError *)error
{
    if (error) {
        NSLog(@"[FBP-iOS] didUpdateValueForDescriptor: [Error] %@", [error localizedDescription]);
    } else if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didUpdateValueForDescriptor");
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:descriptor.characteristic];

    NSData* data = nil;
    if (descriptor.value) {
        int value = [descriptor.value intValue];
        data = [NSData dataWithBytes:&value length:sizeof(value)];
    }
    
    // See BmOnDescriptorResponse
    NSDictionary* result = @{
        @"type":                   @(0), // type: read
        @"remote_id":              [peripheral.identifier UUIDString],
        @"service_uuid":           [pair.primary.UUID fullUUIDString],
        @"secondary_service_uuid": pair.secondary ? [pair.secondary.UUID fullUUIDString] : [NSNull null],
        @"characteristic_uuid":    [descriptor.characteristic.UUID fullUUIDString],
        @"descriptor_uuid":        [descriptor.UUID fullUUIDString],
        @"value":                  [self convertDataToHex:data],
        @"success":                @(error == nil),
        @"error_string":           error ? [error localizedDescription] : [NSNull null],
        @"error_code":             error ? @(error.code) : [NSNull null],
    };

    [_methodChannel invokeMethod:@"OnDescriptorResponse" arguments:result];
}

- (void)peripheral:(CBPeripheral *)peripheral
    didWriteValueForDescriptor:(CBDescriptor *)descriptor
                         error:(NSError *)error
{
    if (error) {
        NSLog(@"[FBP-iOS] didWriteValueForDescriptor: [Error] %@", [error localizedDescription]);
    } else if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didWriteValueForDescriptor");
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:descriptor.characteristic];

    int value = [descriptor.value intValue];
    
    // See BmOnDescriptorResponse
    NSDictionary* result = @{
        @"type":                   @(1), // type: write
        @"remote_id":              [peripheral.identifier UUIDString],
        @"service_uuid":           [pair.primary.UUID fullUUIDString],
        @"secondary_service_uuid": pair.secondary ? [pair.secondary.UUID fullUUIDString] : [NSNull null],
        @"characteristic_uuid":    [descriptor.characteristic.UUID fullUUIDString],
        @"descriptor_uuid":        [descriptor.UUID fullUUIDString],
        @"value":                  [self convertDataToHex:[NSData dataWithBytes:&value length:sizeof(value)]],
        @"success":                @(error == nil),
        @"error_string":           error ? [error localizedDescription] : [NSNull null],
        @"error_code":             error ? @(error.code) : [NSNull null],
    };

    [_methodChannel invokeMethod:@"OnDescriptorResponse" arguments:result];
}

- (void)peripheral:(CBPeripheral *)peripheral didReadRSSI:(NSNumber *)rssi error:(NSError *)error
{
    if (error) {
        NSLog(@"[FBP-iOS] didReadRSSI: [Error] %@", [error localizedDescription]);
    } else if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] didReadRSSI");
    }

    // See BmReadRssiResult
    NSDictionary* result = @{
        @"remote_id":       [peripheral.identifier UUIDString],
        @"rssi":            rssi,
        @"success":         @(error == nil),
        @"error_string":    error ? [error localizedDescription] : [NSNull null],
        @"error_code":      error ? @(error.code) : [NSNull null],
    };

    [_methodChannel invokeMethod:@"ReadRssiResult" arguments:result];
}

- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral
{
    if (_logLevel >= debug) {
        NSLog(@"[FBP-iOS] peripheralIsReadyToSendWriteWithoutResponse");
    }
    
    NSDictionary *request = [_dataWaitingToWriteWithoutResponse objectForKey:[[peripheral identifier] UUIDString]];
    if (request == nil) {
        return;
    }
    
    // See BmWriteCharacteristicRequest
    NSString  *characteristicUuid   = request[@"characteristic_uuid"];
    NSString  *serviceUuid          = request[@"service_uuid"];
    NSString  *secondaryServiceUuid = request[@"secondary_service_uuid"];
    NSString  *value                = request[@"value"];

    // Find characteristic
    NSError *error = nil;
    CBCharacteristic *characteristic = [self locateCharacteristic:characteristicUuid
                                                       peripheral:peripheral
                                                        serviceId:serviceUuid
                                               secondaryServiceId:secondaryServiceUuid
                                                            error:&error];
    if (characteristic == nil) {
        NSLog(@"Error: peripheralIsReadyToSendWriteWithoutResponse: %@", [error localizedDescription]);
        return;
    }

    // Write to characteristic
    [peripheral writeValue:[self convertHexToData:value]
            forCharacteristic:characteristic
                        type:CBCharacteristicWriteWithoutResponse];

    [_dataWaitingToWriteWithoutResponse removeObjectForKey:[[peripheral identifier] UUIDString]];
}

//////////////////////////////////////////////////////////////////////
// ███    ███  ███████   ██████      
// ████  ████  ██       ██           
// ██ ████ ██  ███████  ██   ███     
// ██  ██  ██       ██  ██    ██     
// ██      ██  ███████   ██████ 
//     
// ██   ██  ███████  ██       ██████   ███████  ██████   ███████ 
// ██   ██  ██       ██       ██   ██  ██       ██   ██  ██      
// ███████  █████    ██       ██████   █████    ██████   ███████ 
// ██   ██  ██       ██       ██       ██       ██   ██       ██ 
// ██   ██  ███████  ███████  ██       ███████  ██   ██  ███████ 


- (NSString *)convertDataToHex:(NSData *)data 
{
    if (data == nil) {
        return @"";
    }

    const unsigned char *bytes = (const unsigned char *)[data bytes];
    NSMutableString *hexString = [NSMutableString new];

    for (NSInteger i = 0; i < data.length; i++) {
        [hexString appendFormat:@"%02x", bytes[i]];
    }

    return [hexString copy];
}

- (int)toAdapterStateInt:(CBManagerState)adapterState
{
    switch (adapterState)
    {
        case CBManagerStateUnknown:      return 0; // BmAdapterStateEnum.unknown
        case CBManagerStateUnsupported:  return 1; // BmAdapterStateEnum.unavailable
        case CBManagerStateUnauthorized: return 2; // BmAdapterStateEnum.unauthorized
        case CBManagerStateResetting:    return 3; // BmAdapterStateEnum.turningOn
        case CBManagerStatePoweredOn:    return 4; // BmAdapterStateEnum.on
        case CBManagerStatePoweredOff:   return 6; // BmAdapterStateEnum.off
        default:                         return 0; // BmAdapterStateEnum.unknown
    }
    return 0;
}

- (NSDictionary *)toScanResultProto:(CBPeripheral *)peripheral
                  advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                               RSSI:(NSNumber *)RSSI
{
    NSString     *localName      = advertisementData[CBAdvertisementDataLocalNameKey];
    NSNumber     *connectable    = advertisementData[CBAdvertisementDataIsConnectable];
    NSData       *manufData      = advertisementData[CBAdvertisementDataManufacturerDataKey];
    NSNumber     *txPower        = advertisementData[CBAdvertisementDataTxPowerLevelKey];
    NSArray      *serviceUuids   = advertisementData[CBAdvertisementDataServiceUUIDsKey];
    NSDictionary *serviceData    = advertisementData[CBAdvertisementDataServiceDataKey];

    // Manufacturer Data
    NSDictionary* manufDataB = nil;
    if (manufData != nil && manufData.length > 2) {
        
        // first 2 bytes are manufacturerId
        unsigned short manufId = 0;
        [manufData getBytes:&manufId length:2];

        // trim off first 2 bytes
        NSData* trimmed = [manufData subdataWithRange:NSMakeRange(2, manufData.length - 2)];
        NSString* hex = [self convertDataToHex:trimmed];
        
        manufDataB = @{
            @(manufId): hex,
        };
    }
    
    // Service Uuids - convert from CBUUID's to UUID strings
    NSArray *serviceUuidsB = nil;
    if (serviceUuids != nil) {
        NSMutableArray *mutable = [[NSMutableArray alloc] init];
        for (CBUUID *uuid in serviceUuids) {
            [mutable addObject:uuid.UUIDString];
        }
        serviceUuidsB = [mutable copy];
    }
    
    // Service Data - convert from CBUUID's to UUID strings
    NSDictionary *serviceDataB = nil;
    if (serviceData != nil)
    {
        NSMutableDictionary *mutable = [[NSMutableDictionary alloc] init];
        for (CBUUID *uuid in serviceData) {
            NSString* hex = [self convertDataToHex:serviceData[uuid]];
            [mutable setObject:hex forKey:uuid.UUIDString];
        }
        serviceDataB = [mutable copy];
    }

    // See BmAdvertisementData
    NSDictionary* ad = @{
        @"local_name":         localName     ? localName     : [NSNull null],
        @"tx_power_level":     txPower       ? txPower       : [NSNull null],
        @"connectable":        connectable   ? connectable   : @(0),
        @"manufacturer_data":  manufDataB    ? manufDataB    : [NSNull null],
        @"service_uuids":      serviceUuidsB ? serviceUuidsB : [NSNull null],
        @"service_data":       serviceDataB  ? serviceDataB  : [NSNull null],
    };
  
    // See BmScanResult
    return @{
        @"device":             [self toDeviceProto:peripheral],
        @"advertisement_data": ad,
        @"rssi":               RSSI ? RSSI : [NSNull null],
    };
}

- (NSDictionary *)toDeviceProto:(CBPeripheral *)peripheral
{
    // See BmBluetoothDevice
    return @{
        @"remote_id":   [[peripheral identifier] UUIDString],
        @"local_name":  [peripheral name] ? [peripheral name] : [NSNull null],
        @"type":        @(2), // hardcode to BLE. Does iOS differentiate?
    };
}

- (int)connectionStateInt:(CBPeripheralState)connectionState
{
    switch (connectionState)
    {
        case CBPeripheralStateDisconnected:  return 0; // BmConnectionStateEnum.disconnected
        case CBPeripheralStateConnecting:    return 1; // BmConnectionStateEnum.connecting
        case CBPeripheralStateConnected:     return 2; // BmConnectionStateEnum.connected
        case CBPeripheralStateDisconnecting: return 3; // BmConnectionStateEnum.disconnecting
    }
    return 0;
}

- (NSDictionary *)toServiceProto:(CBPeripheral *)peripheral service:(CBService *)service
{
    // Characteristics
    NSMutableArray *characteristicProtos = [NSMutableArray new];
    for (CBCharacteristic *c in [service characteristics])
    {
        [characteristicProtos addObject:[self toCharacteristicProto:peripheral characteristic:c]];
    }

    // Included Services
    NSMutableArray *includedServicesProtos = [NSMutableArray new];
    for (CBService *s in [service includedServices])
    {
        [includedServicesProtos addObject:[self toServiceProto:peripheral service:s]];
    }

    // See BmBluetoothService
    return @{
        @"remote_id":           [peripheral.identifier UUIDString],
        @"service_uuid":        [service.UUID fullUUIDString],
        @"characteristics":     characteristicProtos,
        @"is_primary":          @([service isPrimary]),
        @"included_services":   includedServicesProtos,
    };
}

- (NSDictionary*)toCharacteristicProto:(CBPeripheral *)peripheral
                        characteristic:(CBCharacteristic *)characteristic
{
    // descriptors
    NSMutableArray *descriptorProtos = [NSMutableArray new];
    for (CBDescriptor *d in [characteristic descriptors])
    {
        NSData* data = nil;
        if (d.value) {
            int value = [d.value intValue];
            data = [NSData dataWithBytes:&value length:sizeof(value)];
        }
    
        // See: BmBluetoothDescriptor
        NSDictionary* desc = @{
            @"remote_id":              [peripheral.identifier UUIDString],
            @"service_uuid":           [d.characteristic.service.UUID fullUUIDString],
            @"secondary_service_uuid": [NSNull null],
            @"characteristic_uuid":    [d.characteristic.UUID fullUUIDString],
            @"descriptor_uuid":        [d.UUID fullUUIDString],
            @"value":                  [self convertDataToHex:data],
        };

        [descriptorProtos addObject:desc];
    }

    ServicePair *pair = [self getServicePair:peripheral characteristic:characteristic];

    CBCharacteristicProperties props = characteristic.properties;

    // See: BmCharacteristicProperties
    NSDictionary* propsMap = @{
        @"broadcast":                    @((props & CBCharacteristicPropertyBroadcast) != 0),
        @"read":                         @((props & CBCharacteristicPropertyRead) != 0),
        @"write_without_response":       @((props & CBCharacteristicPropertyWriteWithoutResponse) != 0),
        @"write":                        @((props & CBCharacteristicPropertyWrite) != 0),
        @"notify":                       @((props & CBCharacteristicPropertyNotify) != 0),
        @"indicate":                     @((props & CBCharacteristicPropertyIndicate) != 0),
        @"authenticated_signed_writes":  @((props & CBCharacteristicPropertyAuthenticatedSignedWrites) != 0),
        @"extended_properties":          @((props & CBCharacteristicPropertyExtendedProperties) != 0),
        @"notify_encryption_required":   @((props & CBCharacteristicPropertyNotifyEncryptionRequired) != 0),
        @"indicate_encryption_required": @((props & CBCharacteristicPropertyIndicateEncryptionRequired) != 0),
    };

    // See BmBluetoothCharacteristic
    return @{
        @"remote_id":              [peripheral.identifier UUIDString],
        @"service_uuid":           [pair.primary.UUID fullUUIDString],
        @"secondary_service_uuid": pair.secondary ? [pair.secondary.UUID fullUUIDString] : [NSNull null],
        @"characteristic_uuid":    [characteristic.UUID fullUUIDString],
        @"descriptors":            descriptorProtos,
        @"properties":             propsMap,
        @"value":                  [self convertDataToHex:characteristic.value],
    };
}

//////////////////////////////////////////
// ██    ██ ████████  ██  ██       ███████ 
// ██    ██    ██     ██  ██       ██      
// ██    ██    ██     ██  ██       ███████ 
// ██    ██    ██     ██  ██            ██ 
//  ██████     ██     ██  ███████  ███████ 

- (void)log:(LogLevel)level
     format:(NSString *)format, ...
{
    if (level <= _logLevel)
    {
        va_list args;
        va_start(args, format);
        //    NSString* formattedMessage = [[NSString alloc] initWithFormat:format arguments:args];
        NSLog(format, args);
        va_end(args);
    }
}

- (uint32_t)getMtu:(CBPeripheral *)peripheral
{
    return (uint32_t)[peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse];
}

- (ServicePair *)getServicePair:(CBPeripheral *)peripheral
                 characteristic:(CBCharacteristic *)characteristic
{
    ServicePair* result = [[ServicePair alloc] init];

    CBService *service = characteristic.service;

    // is this a primary service?
    if ([service isPrimary]) {
        result.primary = service;
        result.secondary = NULL;
        return result;
    } 

    // Otherwise, iterate all services until we find the primary service
    for (CBService *primary in [peripheral services])
    {
        for (CBService *secondary in [primary includedServices])
        {
            if ([[secondary.UUID UUIDString] isEqualToString:[service.UUID UUIDString]])
            {
                result.primary = primary;
                result.secondary = secondary;
                return result;
            }
        }
    }

    return result;
}
@end