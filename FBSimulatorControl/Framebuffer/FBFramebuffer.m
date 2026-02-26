/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBFramebuffer.h"

#import <CoreSimulator/SimDeviceIOProtocol-Protocol.h>

#import <xpc/xpc.h>

#import <IOSurface/IOSurface.h>

#import <FBControlCore/FBControlCore.h>

#import <CoreSimulator/SimDevice.h>

#import <SimulatorKit/SimDeviceIOPortConsumer-Protocol.h>
#import <SimulatorKit/SimDeviceIOPortDescriptorState-Protocol.h>
#import <SimulatorKit/SimDeviceIOPortInterface-Protocol.h>
#import <SimulatorKit/SimDisplayDescriptorState-Protocol.h>
#import <SimulatorKit/SimDisplayIOSurfaceRenderable-Protocol.h>
#import <SimulatorKit/SimDisplayRenderable-Protocol.h>

#import <IOSurface/IOSurfaceObjC.h>

#import "FBSimulator+Private.h"
#import "FBSimulatorError.h"

static NSString *const SimDeviceScreenClassName = @"_TtC12SimulatorKit15SimDeviceScreen";

@interface FBFramebuffer ()

@property (nonatomic, strong, readonly) NSMapTable<id<FBFramebufferConsumer>, NSUUID *> *consumers;
@property (nonatomic, strong, readonly) id<FBControlCoreLogger> logger;

@end

@interface FBFramebuffer_Legacy : FBFramebuffer

@property (nonatomic, strong, readonly) id<SimDisplayIOSurfaceRenderable, SimDisplayRenderable> surface;

- (instancetype)initWithSurface:(id<SimDisplayIOSurfaceRenderable, SimDisplayRenderable>)surface logger:(id<FBControlCoreLogger>)logger;

@end

@implementation FBFramebuffer

#pragma mark Initializers

+ (instancetype)mainScreenSurfaceForSimulator:(FBSimulator *)simulator logger:(id<FBControlCoreLogger>)logger error:(NSError **)error;
{
  // Path 1: Legacy ioPorts-based discovery (works on Xcode <= 26.2)
  id<SimDeviceIOProtocol> ioClient = simulator.device.io;
  NSArray *ports = ioClient.ioPorts;
  [logger logFormat:@"[FBFramebuffer] ioPorts returned %lu port(s)", (unsigned long)ports.count];

  for (id<SimDeviceIOPortInterface> port in ports) {
    if (![port conformsToProtocol:@protocol(SimDeviceIOPortInterface)]) {
      [logger logFormat:@"[FBFramebuffer] Port %@ does not conform to SimDeviceIOPortInterface, skipping", port];
      continue;
    }
    id descriptor = [port descriptor];
    [logger logFormat:@"[FBFramebuffer] Port descriptor: %@, class: %@", descriptor, NSStringFromClass([descriptor class])];

    if (![descriptor conformsToProtocol:@protocol(SimDisplayRenderable)]) {
      [logger logFormat:@"[FBFramebuffer] Descriptor does not conform to SimDisplayRenderable, skipping"];
      continue;
    }
    if (![descriptor conformsToProtocol:@protocol(SimDisplayIOSurfaceRenderable)]) {
      [logger logFormat:@"[FBFramebuffer] Descriptor does not conform to SimDisplayIOSurfaceRenderable, skipping"];
      continue;
    }
    if (![descriptor respondsToSelector:@selector(state)]) {
      [logger logFormat:@"[FBFramebuffer] SimDisplay %@ does not have a state, cannot determine if it is the main display", descriptor];
      continue;
    }
    id<SimDisplayDescriptorState> descriptorState = [descriptor performSelector:@selector(state)];
    unsigned short displayClass = descriptorState.displayClass;
    if (displayClass != 0) {
      [logger logFormat:@"[FBFramebuffer] SimDisplay Class is '%d' which is not the main display '0'", displayClass];
      continue;
    }
    [logger logFormat:@"[FBFramebuffer] Found main display via ioPorts path"];
    return [[FBFramebuffer_Legacy alloc] initWithSurface:(id<SimDisplayIOSurfaceRenderable, SimDisplayRenderable>)descriptor logger:logger];
  }

  [logger logFormat:@"[FBFramebuffer] ioPorts path failed, trying SimDeviceScreen fallback (Xcode 26.3+)"];

  // Path 2: SimDeviceScreen-based discovery (Xcode 26.3+)
  Class screenClass = NSClassFromString(SimDeviceScreenClassName);
  if (screenClass) {
    for (uint32_t screenID = 0; screenID < 8; screenID++) {
      SEL initSel = @selector(initWithDevice:screenID:);
      NSMethodSignature *initSig = [screenClass instanceMethodSignatureForSelector:initSel];
      if (!initSig) { continue; }
      NSInvocation *initInv = [NSInvocation invocationWithMethodSignature:initSig];
      [initInv setTarget:[screenClass alloc]];
      [initInv setSelector:initSel];
      SimDevice *device = simulator.device;
      [initInv setArgument:&device atIndex:2];
      [initInv setArgument:&screenID atIndex:3];
      [initInv invoke];
      __unsafe_unretained id deviceScreen = nil;
      [initInv getReturnValue:&deviceScreen];
      if (!deviceScreen) {
        continue;
      }

      [logger logFormat:@"[FBFramebuffer] SimDeviceScreen created for screenID=%u, isDefault=%d",
       screenID, [[deviceScreen valueForKey:@"isDefault"] boolValue]];

      id simScreen = [deviceScreen performSelector:@selector(screen)];
      if (!simScreen) {
        [logger logFormat:@"[FBFramebuffer] SimDeviceScreen screenID=%u has nil screen proxy", screenID];
        continue;
      }

      [logger logFormat:@"[FBFramebuffer] SimScreen proxy: %@, class: %@", simScreen, NSStringFromClass([simScreen class])];

      BOOL hasRenderable = [simScreen conformsToProtocol:@protocol(SimDisplayIOSurfaceRenderable)];
      BOOL hasNewCallbacks = [simScreen respondsToSelector:@selector(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)];
      [logger logFormat:@"[FBFramebuffer] SimScreen hasRenderable=%d, hasNewCallbacks=%d", hasRenderable, hasNewCallbacks];

      if (hasRenderable) {
        [logger logFormat:@"[FBFramebuffer] Using SimDeviceScreen screenID=%u via legacy renderable interface", screenID];
        return [[FBFramebuffer_Legacy alloc] initWithSurface:(id<SimDisplayIOSurfaceRenderable, SimDisplayRenderable>)simScreen logger:logger];
      }

      if (hasNewCallbacks) {
        [logger logFormat:@"[FBFramebuffer] Using SimDeviceScreen screenID=%u via new screen callbacks", screenID];
        return [[FBFramebuffer_Legacy alloc] initWithSurface:(id<SimDisplayIOSurfaceRenderable, SimDisplayRenderable>)simScreen logger:logger];
      }
    }
  } else {
    [logger logFormat:@"[FBFramebuffer] SimDeviceScreen class not available (pre-Xcode 26.3)"];
  }

  return [[FBSimulatorError
    describeFormat:@"Could not find the Main Screen Surface for Clients %@ in %@", [FBCollectionInformation oneLineDescriptionFromArray:ioClient.ioPorts], ioClient]
    fail:error];
}

- (instancetype)initWithLogger:(id<FBControlCoreLogger>)logger
{
  if (!self) {
    return nil;
  }

  _consumers = [NSMapTable
    mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
    valueOptions:NSPointerFunctionsCopyIn];
  _logger = logger;

  return self;
}

#pragma mark Public Methods

- (nullable IOSurface *)attachConsumer:(id<FBFramebufferConsumer>)consumer onQueue:(dispatch_queue_t)queue
{
  // Don't attach the same consumer twice
  NSAssert(![self isConsumerAttached:consumer], @"Cannot re-attach the same consumer %@", consumer);
  NSUUID *consumerUUID = NSUUID.UUID;

  // Attempt to return the surface synchronously (if supported).
  IOSurface *surface = [self extractImmediatelyAvailableSurface];

  // Register the consumer.
  [self.consumers setObject:consumerUUID forKey:consumer];
  [self registerConsumer:consumer uuid:consumerUUID queue:queue];

  return surface;
}

- (void)detachConsumer:(id<FBFramebufferConsumer>)consumer
{
  NSUUID *uuid = [self.consumers objectForKey:consumer];
  if (!uuid) {
    return;;
  }
  [self.consumers removeObjectForKey:consumer];
  [self unregisterConsumer:consumer uuid:uuid];
}

- (BOOL)isConsumerAttached:(id<FBFramebufferConsumer>)consumer
{
  for (id<FBFramebufferConsumer> existing_consumer in self.consumers.keyEnumerator) {
    if (existing_consumer == consumer) {
      return true;
    }
  }
  return false;
}

#pragma mark Private

- (IOSurface *)extractImmediatelyAvailableSurface
{
  return nil;
}

- (void)registerConsumer:(id<FBFramebufferConsumer>)consumer uuid:(NSUUID *)uuid queue:(dispatch_queue_t)queue
{
  NSAssert(NO, @"-[%@ %@] is abstract and should be overridden", NSStringFromClass(self.class), NSStringFromSelector(_cmd));
}

- (void)unregisterConsumer:(id<FBFramebufferConsumer>)consumer uuid:(NSUUID *)uuid
{
  NSAssert(NO, @"-[%@ %@] is abstract and should be overridden", NSStringFromClass(self.class), NSStringFromSelector(_cmd));
}

@end

@implementation FBFramebuffer_Legacy

- (instancetype)initWithSurface:(id<SimDisplayIOSurfaceRenderable, SimDisplayRenderable>)surface logger:(id<FBControlCoreLogger>)logger
{
  self = [super initWithLogger:logger];
  if (!self) {
    return nil;
  }

  _surface = surface;

  return self;
}

- (IOSurface *)extractImmediatelyAvailableSurface
{
  IOSurface *framebufferSurface = self.surface.framebufferSurface;
  if (framebufferSurface) {
    return framebufferSurface;
  }
  return self.surface.ioSurface;
}

- (void)registerConsumer:(id<FBFramebufferConsumer>)consumer uuid:(NSUUID *)uuid queue:(dispatch_queue_t)queue
{
  id surface = self.surface;

  // Xcode 26.3+: use registerScreenCallbacksWithUUID: for reliable surface delivery
  SEL newCallbackSel = @selector(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:);
  if ([surface respondsToSelector:newCallbackSel]) {
    NSLog(@"[FBFramebuffer] Using NEW registerScreenCallbacksWithUUID: for surface %@", surface);

    void (^frameBlock)(void) = ^{
      [consumer didReceiveDamageRect:CGRectZero];
    };
    void (^surfacesBlock)(IOSurface *, IOSurface *) = ^(IOSurface *unmasked, IOSurface *masked) {
      IOSurface *chosen = unmasked ?: masked;
      NSLog(@"[FBFramebuffer] surfacesChanged: unmasked=%@, masked=%@, using=%@", unmasked, masked, chosen);
      if (chosen) {
        [consumer didChangeIOSurface:chosen];
      }
    };
    void (^propsBlock)(id) = ^(id props) {};

    NSMethodSignature *sig = [surface methodSignatureForSelector:newCallbackSel];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
    [invocation setSelector:newCallbackSel];
    [invocation setTarget:surface];
    [invocation setArgument:&uuid atIndex:2];
    [invocation setArgument:&queue atIndex:3];
    [invocation setArgument:&frameBlock atIndex:4];
    [invocation setArgument:&surfacesBlock atIndex:5];
    [invocation setArgument:&propsBlock atIndex:6];
    [invocation invoke];
    return;
  }

  NSLog(@"[FBFramebuffer] Using LEGACY ioSurfacesChangeCallback for surface %@", surface);

  // Legacy path (Xcode <= 26.2)
  void (^ioSurfaceChanged)(IOSurface *) = ^void(IOSurface *ioSurface) {
    dispatch_async(queue, ^{
      [consumer didChangeIOSurface:ioSurface];
    });
  };

  [self.surface registerCallbackWithUUID:uuid ioSurfacesChangeCallback:ioSurfaceChanged];

  [self.surface registerCallbackWithUUID:uuid damageRectanglesCallback:^(NSArray<NSValue *> *frames) {
    dispatch_async(queue, ^{
      for (NSValue *value in frames) {
        [consumer didReceiveDamageRect:value.rectValue];
      }
    });
  }];
}

- (void)unregisterConsumer:(id<FBFramebufferConsumer>)consumer uuid:(NSUUID *)uuid
{
  id surface = self.surface;

  SEL unregisterSel = @selector(unregisterScreenCallbacksWithUUID:);
  if ([surface respondsToSelector:unregisterSel]) {
    NSMethodSignature *sig = [surface methodSignatureForSelector:unregisterSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:unregisterSel];
    [inv setTarget:surface];
    [inv setArgument:&uuid atIndex:2];
    [inv invoke];
    return;
  }

  [self.surface unregisterIOSurfacesChangeCallbackWithUUID:uuid];
  [self.surface unregisterDamageRectanglesCallbackWithUUID:uuid];
}

@end
