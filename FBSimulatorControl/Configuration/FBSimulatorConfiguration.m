/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSimulatorConfiguration.h"

#import <objc/runtime.h>

#import <FBControlCore/FBControlCoreGlobalConfiguration.h>

#import <CoreSimulator/SimDeviceType.h>

#import "FBSimulatorConfiguration+CoreSimulator.h"
#import "FBSimulatorControl+PrincipalClass.h"
#import "FBSimulatorControlFrameworkLoader.h"
#import "FBSimulatorServiceContext.h"

@implementation FBSimulatorConfiguration

#pragma mark Device Selection

static NSInteger FBDeviceModelGenerationFromName(NSString *name)
{
  NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"iPhone\\s+(\\d+)" options:0 error:nil];
  NSTextCheckingResult *match = [regex firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
  if (!match || match.numberOfRanges < 2) {
    return -1;
  }
  NSString *numberString = [name substringWithRange:[match rangeAtIndex:1]];
  return numberString.integerValue;
}

static NSInteger FBDeviceModelProRankFromName(NSString *name)
{
  if ([name containsString:@"Pro Max"]) {
    return 2;
  }
  if ([name containsString:@"Pro"]) {
    return 1;
  }
  return 0;
}

static NSComparisonResult FBCompareDeviceNames(NSString *left, NSString *right)
{
  NSInteger leftGeneration = FBDeviceModelGenerationFromName(left);
  NSInteger rightGeneration = FBDeviceModelGenerationFromName(right);
  if (leftGeneration != rightGeneration) {
    if (leftGeneration == -1) {
      return NSOrderedAscending;
    }
    if (rightGeneration == -1) {
      return NSOrderedDescending;
    }
    return leftGeneration < rightGeneration ? NSOrderedAscending : NSOrderedDescending;
  }

  NSInteger leftRank = FBDeviceModelProRankFromName(left);
  NSInteger rightRank = FBDeviceModelProRankFromName(right);
  if (leftRank != rightRank) {
    return leftRank < rightRank ? NSOrderedAscending : NSOrderedDescending;
  }

  return [left compare:right options:NSNumericSearch];
}

+ (nullable FBDeviceType *)newestAvailableDeviceMatching:(BOOL (^)(NSString *name))predicate
{
  NSMutableArray<FBDeviceType *> *devices = [NSMutableArray array];
  for (SimDeviceType *deviceType in [FBSimulatorServiceContext.sharedServiceContext supportedDeviceTypes]) {
    if (!predicate(deviceType.name)) {
      continue;
    }
    FBDeviceType *device = FBiOSTargetConfiguration.nameToDevice[deviceType.name];
    if (device) {
      [devices addObject:device];
    }
  }
  if (devices.count == 0) {
    return nil;
  }
  return [[devices sortedArrayUsingComparator:^NSComparisonResult(FBDeviceType *left, FBDeviceType *right) {
    return FBCompareDeviceNames(left.model, right.model);
  }] lastObject];
}

+ (nullable FBDeviceType *)newestAvailableiPhoneProDevice
{
  return [self newestAvailableDeviceMatching:^BOOL(NSString *name) {
    return [name containsString:@"iPhone"] && [name containsString:@"Pro"];
  }];
}

+ (nullable FBDeviceType *)newestAvailableiPhoneDevice
{
  return [self newestAvailableDeviceMatching:^BOOL(NSString *name) {
    return [name containsString:@"iPhone"];
  }];
}

+ (nullable FBDeviceType *)newestAvailableDevice
{
  return [self newestAvailableDeviceMatching:^BOOL(NSString *name) {
    return name.length > 0;
  }];
}

+ (void)initialize
{
  [FBSimulatorControlFrameworkLoader.essentialFrameworks loadPrivateFrameworksOrAbort];
}

#pragma mark Initializers

- (instancetype)initWithNamedDevice:(FBDeviceType *)device os:(FBOSVersion *)os
{
  NSParameterAssert(device);
  NSParameterAssert(os);

  self = [super init];
  if (!self) {
    return nil;
  }

  _device = device;
  _os = os;

  return self;
}

+ (instancetype)defaultConfiguration
{
  static dispatch_once_t onceToken;
  static FBSimulatorConfiguration *configuration;
  dispatch_once(&onceToken, ^{
    configuration = [self makeDefaultConfiguration];
  });
  return configuration;
}

+ (instancetype)makeDefaultConfiguration
{
  FBDeviceType *device = [self newestAvailableiPhoneProDevice] ?: [self newestAvailableiPhoneDevice] ?: [self newestAvailableDevice];
  NSAssert(device, @"Could not obtain an available device type. Available Device Types %@", [FBSimulatorServiceContext.sharedServiceContext supportedDeviceTypes]);
  FBOSVersion *os = [FBSimulatorConfiguration newestAvailableOSForDevice:device];
  NSAssert(
    os,
    @"Could not obtain OS for model '%@'. Supported OS Versions for Model %@. All Available OS Versions %@",
    device.model,
    [FBCollectionInformation oneLineDescriptionFromArray:[FBSimulatorConfiguration supportedOSVersionsForDevice:device]],
    [FBCollectionInformation oneLineDescriptionFromArray:[FBSimulatorConfiguration supportedOSVersions]]
  );
  return [[FBSimulatorConfiguration alloc] initWithNamedDevice:device os:os];
}

#pragma mark NSCopying

- (instancetype)copyWithZone:(NSZone *)zone
{
  return [[self.class alloc] initWithNamedDevice:self.device os:self.os];
}

#pragma mark NSObject

- (NSUInteger)hash
{
  return self.deviceModel.hash ^ self.osVersionString.hash;
}

- (BOOL)isEqual:(FBSimulatorConfiguration *)object
{
  if (![object isKindOfClass:self.class]) {
    return NO;
  }

  return [self.deviceModel isEqualToString:object.deviceModel] &&
         [self.osVersionString isEqualToString:object.osVersionString];

}

- (NSString *)description
{
  return [NSString stringWithFormat:
    @"Device '%@' | OS Version '%@'",
    self.deviceModel,
    self.osVersionString
  ];
}

#pragma mark Models

- (instancetype)withDeviceModel:(FBDeviceModel)model
{
  FBDeviceType *device = FBiOSTargetConfiguration.nameToDevice[model];
  device = device ?: [FBDeviceType genericWithName:model];
  return [self withDevice:device];
}

#pragma mark OS Versions

- (instancetype)withOSNamed:(FBOSVersionName)osName
{
  FBOSVersion *os = FBiOSTargetConfiguration.nameToOSVersion[osName];
  os = os ?: [FBOSVersion genericWithName:osName];
  return [self withOS:os];
}

#pragma mark Private

- (instancetype)withOS:(FBOSVersion *)os
{
  NSParameterAssert(os);
  return [[FBSimulatorConfiguration alloc] initWithNamedDevice:self.device os:os ];
}

- (instancetype)withDevice:(FBDeviceType *)device
{
  NSParameterAssert(device);
  // Use the current os if compatible.
  // If os.families is empty, it was probably created via [FBOSVersion +genericWithName:]
  // which has no information about families; in that case we assume it is compatible.
  FBOSVersion *os = self.os;
  if (!os.families.count || [os.families containsObject:@(device.family)]) {
    return [[FBSimulatorConfiguration alloc] initWithNamedDevice:device os:os];
  }
  // Attempt to find the newest OS for this device, otherwise use what we had before.
  os = [FBSimulatorConfiguration newestAvailableOSForDevice:device] ?: os;
  return [[FBSimulatorConfiguration alloc] initWithNamedDevice:device os:os];
}

#pragma mark Private

- (FBDeviceModel)deviceModel
{
  return self.device.model;
}

- (FBOSVersionName)osVersionString
{
  return self.os.name;
}

@end
