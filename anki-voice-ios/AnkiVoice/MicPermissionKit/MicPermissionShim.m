#import "MicPermissionShim.h"
@import AVFoundation;

@implementation MicPermissionShim
+ (AVAudioRecordPermissionShim)recordPermission {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return (AVAudioRecordPermissionShim)[[AVAudioSession sharedInstance] recordPermission];
#pragma clang diagnostic pop
}
+ (void)requestRecordPermission:(void(^)(BOOL))completion {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted){
        if (completion) { dispatch_async(dispatch_get_main_queue(), ^{ completion(granted); }); }
    }];
#pragma clang diagnostic pop
}
@end
