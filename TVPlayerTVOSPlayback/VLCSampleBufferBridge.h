#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TVPlayerSampleBufferBridge : NSObject

@property (nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, readonly, getter=isReady) BOOL ready;
@property (nonatomic, copy, nullable) void (^readinessChanged)(BOOL ready);

- (instancetype)initWithMediaPlayer:(id)mediaPlayer;
- (BOOL)installVideoCallbacks;
- (void)removeVideoCallbacks;
- (void)flush;

@end

NS_ASSUME_NONNULL_END
