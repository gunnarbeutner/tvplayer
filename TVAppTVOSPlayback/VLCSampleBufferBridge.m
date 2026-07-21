#import "VLCSampleBufferBridge.h"
#import <VLCKit/VLCKit.h>
#import <VLCKit/vlc/vlc.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

// VLCKit ships this bridge method with the framework. Keeping the declaration
// here avoids importing its broad Internal header into Swift or app code.
@interface VLCMediaPlayer (TVPlayerLibVLCBridge)
@property (nonatomic, readonly) void *libVLCMediaPlayer;
@end

@interface TVPlayerSampleBufferBridge ()
@property (nonatomic) VLCMediaPlayer *mediaPlayer;
@property (nonatomic) libvlc_media_player_t *player;
@property (nonatomic) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic) CMVideoFormatDescriptionRef formatDescription;
@property (nonatomic, readwrite) BOOL ready;
@property (nonatomic) unsigned width;
@property (nonatomic) unsigned height;
@end

static unsigned TVPlayerVideoFormat(
    void **opaque,
    char *chroma,
    unsigned *width,
    unsigned *height,
    unsigned *pitches,
    unsigned *lines
) {
    TVPlayerSampleBufferBridge *bridge = (__bridge TVPlayerSampleBufferBridge *)(*opaque);
    memcpy(chroma, "RV32", 4);
    bridge.width = *width;
    bridge.height = *height;
    *lines = *height;

    NSDictionary *attributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @(*width),
        (NSString *)kCVPixelBufferHeightKey: @(*height),
        (NSString *)kCVPixelBufferBytesPerRowAlignmentKey: @64,
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferPoolRef pool = NULL;
    if (CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        NULL,
        (__bridge CFDictionaryRef)attributes,
        &pool
    ) != kCVReturnSuccess) {
        return 0;
    }
    bridge.pixelBufferPool = pool;

    // Use the pool's actual stride. It is guaranteed to be suitably aligned
    // and can be wider than width * 4 on some hardware.
    CVPixelBufferRef probe = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault,
        pool,
        &probe
    ) != kCVReturnSuccess) {
        bridge.pixelBufferPool = NULL;
        return 0;
    }
    *pitches = (unsigned)CVPixelBufferGetBytesPerRow(probe);
    CFRelease(probe);

    CMVideoFormatDescriptionRef format = NULL;
    CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault,
        kCVPixelFormatType_32BGRA,
        (int32_t)*width,
        (int32_t)*height,
        NULL,
        &format
    );
    bridge.formatDescription = format;
    dispatch_async(dispatch_get_main_queue(), ^{
        bridge.ready = NO;
        if (bridge.readinessChanged) bridge.readinessChanged(NO);
    });
    return 1;
}

static void TVPlayerVideoCleanup(void *opaque) {
    TVPlayerSampleBufferBridge *bridge = (__bridge TVPlayerSampleBufferBridge *)opaque;
    bridge.pixelBufferPool = NULL;
    bridge.formatDescription = NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
        bridge.ready = NO;
        [bridge.displayLayer.sampleBufferRenderer
            flushWithRemovalOfDisplayedImage:YES
            completionHandler:nil];
        if (bridge.readinessChanged) bridge.readinessChanged(NO);
    });
}

static void *TVPlayerVideoLock(void *opaque, void **planes) {
    TVPlayerSampleBufferBridge *bridge = (__bridge TVPlayerSampleBufferBridge *)opaque;
    if (bridge.pixelBufferPool == NULL) return NULL;
    CVPixelBufferRef buffer = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault,
        bridge.pixelBufferPool,
        &buffer
    ) != kCVReturnSuccess) return NULL;
    CVPixelBufferLockBaseAddress(buffer, 0);
    *planes = CVPixelBufferGetBaseAddress(buffer);
    return buffer;
}

static void TVPlayerVideoUnlock(void *opaque, void *picture, void *const *planes) {
    if (picture != NULL) CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)picture, 0);
}

static void TVPlayerVideoDisplay(void *opaque, void *picture) {
    TVPlayerSampleBufferBridge *bridge = (__bridge TVPlayerSampleBufferBridge *)opaque;
    CVPixelBufferRef buffer = (CVPixelBufferRef)picture;
    if (buffer == NULL || bridge.formatDescription == NULL) {
        if (buffer != NULL) CFRelease(buffer);
        return;
    }

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid,
    };
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        buffer,
        bridge.formatDescription,
        &timing,
        &sample
    );
    CFRelease(buffer);
    if (status != noErr || sample == NULL) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        AVSampleBufferVideoRenderer *renderer = bridge.displayLayer.sampleBufferRenderer;
        if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [renderer flush];
        }
        [renderer enqueueSampleBuffer:sample];
        if (!bridge.ready) {
            bridge.ready = YES;
            if (bridge.readinessChanged) bridge.readinessChanged(YES);
        }
        CFRelease(sample);
    });
}

@implementation TVPlayerSampleBufferBridge

- (instancetype)initWithMediaPlayer:(id)mediaPlayer {
    self = [super init];
    if (self) {
        _mediaPlayer = (VLCMediaPlayer *)mediaPlayer;
        _player = (libvlc_media_player_t *)_mediaPlayer.libVLCMediaPlayer;
        _displayLayer = [AVSampleBufferDisplayLayer layer];
        _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        _displayLayer.backgroundColor = UIColor.blackColor.CGColor;
    }
    return self;
}

- (void)dealloc {
    [self removeVideoCallbacks];
    if (_pixelBufferPool != NULL) CFRelease(_pixelBufferPool);
    if (_formatDescription != NULL) CFRelease(_formatDescription);
}

- (void)setPixelBufferPool:(CVPixelBufferPoolRef)pixelBufferPool {
    if (_pixelBufferPool == pixelBufferPool) return;
    if (_pixelBufferPool != NULL) CFRelease(_pixelBufferPool);
    _pixelBufferPool = pixelBufferPool;
}

- (void)setFormatDescription:(CMVideoFormatDescriptionRef)formatDescription {
    if (_formatDescription == formatDescription) return;
    if (_formatDescription != NULL) CFRelease(_formatDescription);
    _formatDescription = formatDescription;
}

- (BOOL)installVideoCallbacks {
    if (_player == NULL) return NO;
    void *opaque = (__bridge void *)self;
    libvlc_video_set_callbacks(
        _player,
        TVPlayerVideoLock,
        TVPlayerVideoUnlock,
        TVPlayerVideoDisplay,
        opaque
    );
    libvlc_video_set_format_callbacks(_player, TVPlayerVideoFormat, TVPlayerVideoCleanup);
    return YES;
}

- (void)removeVideoCallbacks {
    if (_player == NULL) return;
    libvlc_video_set_callbacks(_player, NULL, NULL, NULL, NULL);
    libvlc_video_set_format_callbacks(_player, NULL, NULL);
}

- (void)flush {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.displayLayer.sampleBufferRenderer
            flushWithRemovalOfDisplayedImage:YES
            completionHandler:nil];
    });
}

@end
