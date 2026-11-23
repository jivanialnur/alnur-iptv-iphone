#import <UIKit/UIKit.h>
#import <VLCKit/VLCKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Video view for VLCKit 4 that also offers Picture in Picture (VLCPictureInPictureDrawable).
/// Written in Objective-C because the protocol's `bounds` / `addSubview:` are satisfied by UIView itself.
@interface PiPVideoView : UIView <VLCDrawable, VLCPictureInPictureDrawable>
@property (nonatomic, weak, nullable) id<VLCPictureInPictureMediaControlling> pipMediaController;
@property (nonatomic, copy, nullable) void (^onPiPReady)(id<VLCPictureInPictureWindowControlling> controller);
@end

NS_ASSUME_NONNULL_END
