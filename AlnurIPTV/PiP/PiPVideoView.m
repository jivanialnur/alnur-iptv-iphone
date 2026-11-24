#import "PiPVideoView.h"

@implementation PiPVideoView

// After rotating, VLC's picture view / layer kept its old size (small, stuck at the left).
// Keep everything VLC put inside this view exactly as big as the view.
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIView *v in self.subviews) { v.frame = self.bounds; }
    for (CALayer *l in self.layer.sublayers) { l.frame = self.layer.bounds; }
    [CATransaction commit];
}

- (id<VLCPictureInPictureMediaControlling>)mediaController {
    return self.pipMediaController;
}

- (void (^)(id<VLCPictureInPictureWindowControlling>))pictureInPictureReady {
    __weak typeof(self) weakSelf = self;
    return ^(id<VLCPictureInPictureWindowControlling> controller) {
        void (^ready)(id<VLCPictureInPictureWindowControlling>) = weakSelf.onPiPReady;
        if (ready) { ready(controller); }
    };
}

@end
