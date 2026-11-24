#import "PiPVideoView.h"
#import <AVFoundation/AVFoundation.h>

@implementation PiPVideoView

// After rotating, VLC's picture view / layer kept its old size (small, stuck at the left).
// Keep everything VLC put inside this view exactly as big as the view.
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGRect b = self.bounds;
    for (UIView *v in self.subviews) {
        // bounds + center (not frame): stays right while a zoom transform is set
        v.bounds = CGRectMake(0, 0, b.size.width, b.size.height);
        v.center = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    }
    for (CALayer *l in self.layer.sublayers) {
        BOOL isViewLayer = NO;
        for (UIView *v in self.subviews) { if (v.layer == l) { isViewLayer = YES; break; } }
        if (!isViewLayer) { l.frame = self.layer.bounds; }
    }
    [CATransaction commit];
    [self applyFill];
}

- (void)setFillMode:(BOOL)fillMode {
    _fillMode = fillMode;
    [self applyFill];
}

static void collectDisplayLayers(CALayer *layer, NSMutableArray *out) {
    if ([layer isKindOfClass:[AVSampleBufferDisplayLayer class]] || [layer isKindOfClass:[AVPlayerLayer class]]) { [out addObject:layer]; }
    for (CALayer *l in layer.sublayers) { collectDisplayLayers(l, out); }
}

// VLC 4 (with the Picture-in-Picture drawable) shows the video in an AVSampleBufferDisplayLayer;
// VLC's own zoom / crop settings are ignored there, so Fill / Fit is done on that layer (videoGravity).
- (NSString *)applyFill {
    NSMutableArray *layers = [NSMutableArray array];
    collectDisplayLayers(self.layer, layers);
    AVLayerVideoGravity g = self.fillMode ? AVLayerVideoGravityResizeAspectFill : AVLayerVideoGravityResizeAspect;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in layers) {
        if ([l isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
            AVSampleBufferDisplayLayer *d = (AVSampleBufferDisplayLayer *)l;
            if (![d.videoGravity isEqualToString:g]) { d.videoGravity = g; }
        } else {
            AVPlayerLayer *p = (AVPlayerLayer *)l;
            if (![p.videoGravity isEqualToString:g]) { p.videoGravity = g; }
        }
        l.masksToBounds = YES;
        if (l.superlayer && !CGRectEqualToRect(l.frame, l.superlayer.bounds)) { l.frame = l.superlayer.bounds; }
    }
    // other video outputs draw "fit" into their view: zoom the subviews instead
    CGAffineTransform t = CGAffineTransformIdentity;
    if (layers.count == 0 && self.fillMode && self.videoSize.width > 0 && self.videoSize.height > 0) {
        CGSize b = self.bounds.size;
        CGFloat vr = self.videoSize.width / self.videoSize.height, br = b.width / MAX(b.height, 1);
        CGFloat s = vr > br ? vr / br : br / vr;
        t = CGAffineTransformMakeScale(s, s);
    }
    for (UIView *v in self.subviews) { if (!CGAffineTransformEqualToTransform(v.transform, t)) { v.transform = t; } }
    [CATransaction commit];
    self.clipsToBounds = YES;
    NSMutableArray *names = [NSMutableArray array];
    for (CALayer *l in layers) { [names addObject:NSStringFromClass([l class])]; }
    return [NSString stringWithFormat:@"%@ layers=%@ zoom=%.2f", self.fillMode ? @"fill" : @"fit",
            [names componentsJoinedByString:@","], t.a];
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
