/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBXcodeConfiguration.h"

#import "FBBundleDescriptor.h"
#import "FBFuture+Sync.h"
#import "FBiOSTargetConfiguration.h"
#import "FBProcessBuilder.h"
#import "FBXcodeDirectory.h"

static NSString *InjectedDeveloperDirectory = nil;
static NSString *CachedDeveloperDirectory = nil;
static NSError *CachedDeveloperDirectoryError = nil;
static BOOL HasResolvedDeveloperDirectory = NO;
static NSDecimalNumber *CachedXcodeVersionNumber = nil;
static NSString *CachedIOSSDKVersion = nil;
static NSOperatingSystemVersion CachedXcodeVersion;
static BOOL HasCachedXcodeVersion = NO;

@implementation FBXcodeConfiguration

+ (NSString *)developerDirectory
{
  return [self findXcodeDeveloperDirectoryOrAssert];
}

+ (nullable NSString *)getDeveloperDirectoryIfExists
{
  return [self findXcodeDeveloperDirectory:nil];
}

+ (void)setInjectedDeveloperDirectory:(nullable NSString *)developerDirectory
{
  @synchronized(self) {
    InjectedDeveloperDirectory = [developerDirectory copy];
    CachedDeveloperDirectory = nil;
    CachedDeveloperDirectoryError = nil;
    HasResolvedDeveloperDirectory = NO;
    CachedXcodeVersionNumber = nil;
    CachedIOSSDKVersion = nil;
    HasCachedXcodeVersion = NO;
  }
}

+ (NSString *)contentsDirectory
{
  return [[self developerDirectory] stringByDeletingLastPathComponent];
}

+ (NSDecimalNumber *)xcodeVersionNumber
{
  @synchronized(self) {
    if (!CachedXcodeVersionNumber) {
      NSString *versionNumberString = [FBXcodeConfiguration
        readValueForKey:@"CFBundleShortVersionString"
        fromPlistAtPath:FBXcodeConfiguration.xcodeInfoPlistPath];
      CachedXcodeVersionNumber = [NSDecimalNumber decimalNumberWithString:versionNumberString];
    }
    return CachedXcodeVersionNumber;
  }
}

+ (NSOperatingSystemVersion)xcodeVersion
{
  @synchronized(self) {
    if (!HasCachedXcodeVersion) {
      CachedXcodeVersion = [FBOSVersion operatingSystemVersionFromName:self.xcodeVersionNumber.stringValue];
      HasCachedXcodeVersion = YES;
    }
    return CachedXcodeVersion;
  }
}

+ (NSString *)iosSDKVersion
{
  @synchronized(self) {
    if (!CachedIOSSDKVersion) {
      CachedIOSSDKVersion = [FBXcodeConfiguration
        readValueForKey:@"Version"
        fromPlistAtPath:FBXcodeConfiguration.iPhoneSimulatorPlatformInfoPlistPath];
    }
    return CachedIOSSDKVersion;
  }
}

+ (NSDecimalNumber *)iosSDKVersionNumber
{
  return [NSDecimalNumber decimalNumberWithString:self.iosSDKVersion];
}

+ (NSNumberFormatter *)iosSDKVersionNumberFormatter
{
  static dispatch_once_t onceToken;
  static NSNumberFormatter *formatter;
  dispatch_once(&onceToken, ^{
    formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.minimumFractionDigits = 1;
    formatter.maximumFractionDigits = 3;
  });
  return formatter;
}

+ (BOOL)isXcode12OrGreater
{
  return [FBXcodeConfiguration.xcodeVersionNumber compare:[NSDecimalNumber decimalNumberWithString:@"12.0"]] != NSOrderedAscending;
}

+ (BOOL)isXcode12_5OrGreater
{
  return [FBXcodeConfiguration.xcodeVersionNumber compare:[NSDecimalNumber decimalNumberWithString:@"12.5"]] != NSOrderedAscending;
}

+ (FBBundleDescriptor *)simulatorApp
{
  NSError *error = nil;
  FBBundleDescriptor *application = [FBBundleDescriptor bundleFromPath:self.simulatorApplicationPath error:&error];
  NSAssert(application, @"Expected to be able to build an Application, got an error %@", application);
  return application;
}

+ (NSString *)description
{
  return [NSString stringWithFormat:
    @"Developer Directory %@ | Xcode Version %@ | iOS SDK Version %@",
    self.developerDirectory,
    self.xcodeVersionNumber,
    self.iosSDKVersionNumber
  ];
}

- (NSString *)description
{
  return [FBXcodeConfiguration description];
}

#pragma mark Private

+ (NSString *)simulatorApplicationPath
{
  NSString *simulatorBinaryName =  @"Simulator";
  return [[self.developerDirectory
    stringByAppendingPathComponent:@"Applications"]
    stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.app", simulatorBinaryName]];
}

+ (NSString *)iPhoneSimulatorPlatformInfoPlistPath
{
  return [[self.developerDirectory
    stringByAppendingPathComponent:@"Platforms/iPhoneSimulator.platform"]
    stringByAppendingPathComponent:@"Info.plist"];
}

+ (NSString *)xcodeInfoPlistPath
{
  return [[self.developerDirectory
    stringByDeletingLastPathComponent]
    stringByAppendingPathComponent:@"Info.plist"];
}

+ (NSString *)findXcodeDeveloperDirectoryOrAssert
{
  NSError *error = nil;
  NSString *directory = [self findXcodeDeveloperDirectory:&error];
  NSAssert(directory, @"Failed to get developer directory from xcode-select: %@", error.description);
  return directory;
}

+ (nullable NSString *)findXcodeDeveloperDirectory:(NSError **)error
{
  @synchronized(self) {
    if (InjectedDeveloperDirectory != nil) {
      if (error) {
        *error = nil;
      }
      return InjectedDeveloperDirectory;
    }
    if (!HasResolvedDeveloperDirectory) {
      NSError *innerError = nil;
      CachedDeveloperDirectory = [FBXcodeDirectory symlinkedDeveloperDirectoryWithError:&innerError];
      CachedDeveloperDirectoryError = innerError;
      HasResolvedDeveloperDirectory = YES;
    }
    if (error) {
      *error = CachedDeveloperDirectoryError;
    }
    return CachedDeveloperDirectory;
  }
}

+ (nullable id)readValueForKey:(NSString *)key fromPlistAtPath:(NSString *)plistPath
{
  NSAssert([NSFileManager.defaultManager fileExistsAtPath:plistPath], @"plist does not exist at path '%@'", plistPath);
  NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
  NSAssert(infoPlist, @"Could not read plist at '%@'", plistPath);
  id value = infoPlist[key];
  NSAssert(value, @"'%@' does not exist in plist '%@'", key, infoPlist.allKeys);
  return value;
}

@end
