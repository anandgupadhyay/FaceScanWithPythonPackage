#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Sample Objective-C caller for the FaceVerification wrapper. Copy the call in the .m file into your own code.
@interface FaceVerifyObjCDemo : NSObject

+ (void)runFrom:(UIViewController *)presenter
       userName:(NSString *)userName
       imageURL:(NSString *)imageURL
     completion:(void (^)(NSString *result))completion;

@end

NS_ASSUME_NONNULL_END
