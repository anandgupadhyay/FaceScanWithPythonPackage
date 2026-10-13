import SwiftUI
import UIKit

/// Objective-C entry point for face verification. Shows a popup over the given view controller.
///
///     #import "YourApp-Swift.h"
///
///     [FaceVerification presentFrom:self
///                          userName:@"Anand"
///                          imageURL:@"https://drive.google.com/file/d/1dx2ddSCBvSz_eFUbTsFOZ-C-gY-U1KK_/view?usp=drive_link"
///                        themeColor:UIColor.systemOrangeColor
///                         onSuccess:^(float confidence) { /* verified */ }
///                          onCancel:^{ /* user cancelled */ }];
///
/// Both blocks are called on the main thread, after the popup has been dismissed.
@objc(FaceVerification)
public final class FaceVerification: NSObject {

    /// - Parameters:
    ///   - presenter: the view controller to show the popup over.
    ///   - userName: shown in the title, "Verify yourself as <userName>".
    ///   - imageURL: https link to the photo to compare the live face with (Google Drive share links work).
    ///   - themeColor: used for the camera border, check mark and Cancel button.
    ///   - onSuccess: called when the face matches; `confidence` is 0…1 (0.95 = 95%).
    ///   - onCancel: called when the user taps Cancel.
    @objc(presentFrom:userName:imageURL:themeColor:onSuccess:onCancel:)
    public static func present(from presenter: UIViewController,
                               userName: String,
                               imageURL: String,
                               themeColor: UIColor,
                               onSuccess: @escaping (Float) -> Void,
                               onCancel: @escaping () -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                present(from: presenter, userName: userName, imageURL: imageURL,
                        themeColor: themeColor, onSuccess: onSuccess, onCancel: onCancel)
            }
            return
        }

        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(FaceVerifyView(
            userName: userName,
            imageURL: imageURL,
            themeColor: Color(themeColor),
            onSuccess: { [weak host] confidence in
                host?.dismiss(animated: true) { onSuccess(confidence) }
            },
            onCancel: { [weak host] in
                host?.dismiss(animated: true) { onCancel() }
            }
        ))
        // Popup look: the card floats over the dimmed screen behind it.
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        host.view.backgroundColor = .clear
        presenter.present(host, animated: true)
    }
}
