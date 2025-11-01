#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, AVAudioRecordPermissionShim) {
    AVAudioRecordPermissionShimUndetermined = 1970168944,
    AVAudioRecordPermissionShimDenied       = 1684369017,
    AVAudioRecordPermissionShimGranted      = 1735552628
};

NS_SWIFT_NAME(MicPermissionShim)
@interface MicPermissionShim : NSObject
+ (AVAudioRecordPermissionShim)recordPermission;
+ (void)requestRecordPermission:(void(^)(BOOL granted))completion;
@end
