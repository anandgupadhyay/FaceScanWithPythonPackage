#import "FaceVerifyObjCDemo.h"
#import "FaceScan-Swift.h" // Xcode generates this: "<YourAppName>-Swift.h"

@implementation FaceVerifyObjCDemo

+ (void)runFrom:(UIViewController *)presenter
       userName:(NSString *)userName
       imageURL:(NSString *)imageURL
     completion:(void (^)(NSString *result))completion {
    [FaceVerification presentFrom:presenter
                         userName:userName
                         imageURL:imageURL
                       themeColor:UIColor.systemOrangeColor
                        onSuccess:^(float confidence) {
        NSLog(@"[ObjC] Verification successful (%.0f%% match)", confidence * 100);
        completion([NSString stringWithFormat:@"Verified as %@ (%.0f%%)", userName, confidence * 100]);
    }
                         onCancel:^{
        NSLog(@"[ObjC] User cancelled verification");
        completion(@"Cancelled by user");
    }];
}

@end
