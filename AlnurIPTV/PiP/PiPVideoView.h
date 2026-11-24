#import <UIKit/UIKit.h>
#import <VLCKit/VLCKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Video view for VLCKit 4 that also offers Picture in Picture (VLCPictureInPictureDrawable).
/// Written in Objective-C because the protocol's `bounds` / `addSubview:` are satisfied by UIView itself.
@interface PiPVideoView : UIView <VLCDrawable, VLCPictureInPictureDrawable>
@property (nonatomic, weak, nullable) id<VLCPictureInPictureMediaControlling> pipMediaController;
@property (nonatomic, copy, nullable) void (^onPiPReady)(id<VLCPictureInPictureWindowControlling> controller);
/// YES = picture covers the whole view (edges cut off), NO = whole picture visible (black bars)
@property (nonatomic) BOOL fillMode;
/// picture size (pixels) – only used when VLC does not draw through an AVSampleBufferDisplayLayer
@property (nonatomic) CGSize videoSize;
/// applies fillMode to what VLC draws; returns a short description for the log
- (NSString *)applyFill;
@end

NS_ASSUME_NONNULL_END
