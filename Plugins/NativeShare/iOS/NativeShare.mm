#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <LinkPresentation/LPLinkMetadata.h>
#if defined(UNITY_4_0) || defined(UNITY_5_0)
#import "iPhone_View.h"
#else
extern UIViewController* UnityGetGLViewController();
#endif

#define CHECK_IOS_VERSION( version )  ([[[UIDevice currentDevice] systemVersion] compare:version options:NSNumericSearch] != NSOrderedAscending)

// Credit: https://github.com/ChrisMaire/unity-native-sharing

// Credit: https://stackoverflow.com/a/29916845/2373034
@interface UNativeShareEmailItemProvider : NSObject <UIActivityItemSource>
@property (nonatomic, strong) NSString *subject;
@property (nonatomic, strong) NSString *body;
@end

// Credit: https://stackoverflow.com/a/29916845/2373034
@implementation UNativeShareEmailItemProvider
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)activityViewController
{
    return [self body];
}

- (id)activityViewController:(UIActivityViewController *)activityViewController itemForActivityType:(NSString *)activityType
{
    return [self body];
}

- (NSString *)activityViewController:(UIActivityViewController *)activityViewController subjectForActivityType:(NSString *)activityType
{
    return [self subject];
}
@end

// Credit: https://stackoverflow.com/a/29916845/2373034
@interface UNativeShareImageItemSource : NSObject <UIActivityItemSource>
@property (nonatomic, strong) LPLinkMetadata *linkMetadata;
@property (nonatomic, strong) UIImage* sharedImage;
@end

// Credit: https://stackoverflow.com/a/29916845/2373034
@implementation UNativeShareImageItemSource
- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)activityViewController
{
    // use image here instead of URL to prevent warnings in the log of the form: "Failed to request default share mode for ..."
    return [self sharedImage];
}

- (LPLinkMetadata *)activityViewControllerLinkMetadata:(UIActivityViewController *)activityViewController API_AVAILABLE(ios(13.0))
{
    return [self linkMetadata];
}

- (id)activityViewController:(UIActivityViewController *)activityViewController itemForActivityType:(NSString *)activityType
{
    return [self sharedImage];
}
@end

extern "C" void _NativeShare_Share( const char* files[], int filesCount, const char* subject, const char* text, const char* link )
{
    NSMutableArray *items = [NSMutableArray new];
    
    // When there is a subject on iOS 7 or later, text is provided together with subject via a UNativeShareEmailItemProvider
    // Credit: https://stackoverflow.com/a/29916845/2373034
    if( strlen( subject ) > 0 && CHECK_IOS_VERSION( @"7.0" ) )
    {
        UNativeShareEmailItemProvider *emailItem = [UNativeShareEmailItemProvider new];
        emailItem.subject = [NSString stringWithUTF8String:subject];
        emailItem.body = [NSString stringWithUTF8String:text];
        
        [items addObject:emailItem];
    }
    else if( strlen( text ) > 0 )
        [items addObject:[NSString stringWithUTF8String:text]];
    
    // Credit: https://forum.unity.com/threads/native-share-for-android-ios-open-source.519865/page-13#post-6942362
    if( strlen( link ) > 0 )
    {
        NSString *urlRaw = [NSString stringWithUTF8String:link];
        NSURL *url = [NSURL URLWithString:urlRaw];
        if( url == nil )
        {
            // Try escaping the URL
            if( CHECK_IOS_VERSION( @"9.0" ) )
            {
                url = [NSURL URLWithString:[urlRaw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLHostAllowedCharacterSet]]];
                if( url == nil )
                    url = [NSURL URLWithString:[urlRaw stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLFragmentAllowedCharacterSet]]];
            }
            else
                url = [NSURL URLWithString:[urlRaw stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
        }
        
        if( url != nil )
            [items addObject:url];
        else
            NSLog( @"Couldn't create a URL from link: %@", urlRaw );
    }
    
    for( int i = 0; i < filesCount; i++ )
    {
        NSString *filePath = [NSString stringWithUTF8String:files[i]];
        UIImage *image = [UIImage imageWithContentsOfFile:filePath];
        
        if( image != nil )
        {
            if ( CHECK_IOS_VERSION(@"13.0") ) {
                NSURL* url = [NSURL fileURLWithPath:filePath];
                NSItemProvider * imageProvider = [[NSItemProvider alloc] initWithObject:image];
                LPLinkMetadata * metaData = [[LPLinkMetadata alloc] init];
                metaData.originalURL = url;
                metaData.URL = url;
                metaData.iconProvider = imageProvider;
                metaData.imageProvider = imageProvider;
                
                UNativeShareImageItemSource *linkItem = [[UNativeShareImageItemSource alloc] init];
                linkItem.linkMetadata = metaData;
                linkItem.sharedImage = image;
                
                [items addObject:linkItem];
            }
            else
            {
                [items addObject:image];
            }
        }
        else
        {
            [items addObject:[NSURL fileURLWithPath:filePath]];
        }
    }
    
    if( strlen( subject ) == 0 && [items count] == 0 )
    {
        NSLog( @"Share canceled because there is nothing to share..." );
        UnitySendMessage( "NSShareResultCallbackiOS", "OnShareCompleted", "2" );
        
        return;
    }

    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    if( strlen( subject ) > 0 )
        [activity setValue:[NSString stringWithUTF8String:subject] forKey:@"subject"];
    
    void (^shareResultCallback)(UIActivityType activityType, BOOL completed, UIActivityViewController *activityReference) = ^void( UIActivityType activityType, BOOL completed, UIActivityViewController *activityReference )
    {
        NSLog( @"Shared to %@ with result: %d", activityType, completed );
        
        if( activityReference )
        {
            const char *resultMessage = [[NSString stringWithFormat:@"%d%@", completed ? 1 : 2, activityType] UTF8String];
            char *result = (char*) malloc( strlen( resultMessage ) + 1 );
            strcpy( result, resultMessage );
            
            UnitySendMessage( "NSShareResultCallbackiOS", "OnShareCompleted", result );
            
            // On iPhones, the share sheet isn't dismissed automatically when share operation is canceled, do that manually here
            if( !completed && [[UIDevice currentDevice]userInterfaceIdiom] == UIUserInterfaceIdiomPhone )
                [activityReference dismissViewControllerAnimated:NO completion:nil];
            
        }
        else
            NSLog( @"Share result callback is invoked multiple times!" );
    };
    
    if( CHECK_IOS_VERSION( @"8.0" ) )
    {
        __block UIActivityViewController *activityReference = activity; // About __block usage: https://gist.github.com/HawkingOuYang/b2c9783c75f929b5580c
        activity.completionWithItemsHandler = ^( UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError )
        {
            if( activityError != nil )
                NSLog( @"Share error: %@", activityError );
            
            shareResultCallback( activityType, completed, activityReference );
            activityReference = nil;
        };
    }
    else if( CHECK_IOS_VERSION( @"6.0" ) )
    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        __block UIActivityViewController *activityReference = activity;
        activity.completionHandler = ^( UIActivityType activityType, BOOL completed )
        {
            shareResultCallback( activityType, completed, activityReference );
            activityReference = nil;
        };
#pragma clang diagnostic pop
    }
    else
        UnitySendMessage( "NSShareResultCallbackiOS", "OnShareCompleted", "" );
    
    UIViewController *rootViewController = UnityGetGLViewController();
    if( [[UIDevice currentDevice]userInterfaceIdiom] == UIUserInterfaceIdiomPhone ) // iPhone
    {
        [rootViewController presentViewController:activity animated:YES completion:nil];
    }
    else // iPad
    {
        if( CHECK_IOS_VERSION( @"9.0" ) )
        {
            // set modal presentation style to popover on your view controller
            // must be done before you reference controller.popoverPresentationController
            activity.modalPresentationStyle = UIModalPresentationPopover;
            activity.preferredContentSize = CGSizeMake(rootViewController.view.frame.size.width / 2, rootViewController.view.frame.size.height / 2);
            
            // configure popover style & delegate
            UIPopoverPresentationController *popover =  activity.popoverPresentationController;
            popover.sourceView = rootViewController.view;
            popover.sourceRect = CGRectMake( rootViewController.view.frame.size.width / 2, rootViewController.view.frame.size.height / 2, 1, 1 );
            popover.permittedArrowDirections = 0;
            
            // display the controller in the usual way
            [rootViewController presentViewController:activity animated:YES completion:nil];
        }
        else
        {
            UIPopoverController *popup = [[UIPopoverController alloc] initWithContentViewController:activity];
            [popup presentPopoverFromRect:CGRectMake( rootViewController.view.frame.size.width / 2, rootViewController.view.frame.size.height / 2, 1, 1 ) inView:rootViewController.view permittedArrowDirections:0 animated:YES];
        }
        
    }
}