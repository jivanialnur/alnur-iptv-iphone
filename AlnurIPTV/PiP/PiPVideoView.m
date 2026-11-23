#import "PiPVideoView.h"

@implementation PiPVideoView

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
