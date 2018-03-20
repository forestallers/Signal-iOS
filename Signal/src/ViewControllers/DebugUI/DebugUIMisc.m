//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "DebugUIMisc.h"
#import "OWSBackup.h"
#import "OWSCountryMetadata.h"
#import "OWSTableViewController.h"
#import "RegistrationViewController.h"
#import "Signal-Swift.h"
#import "ThreadUtil.h"
#import <AxolotlKit/PreKeyBundle.h>
#import <SignalMessaging/AttachmentSharing.h>
#import <SignalMessaging/Environment.h>
#import <SignalMessaging/UIImage+OWS.h>
#import <SignalServiceKit/OWSDisappearingConfigurationUpdateInfoMessage.h>
#import <SignalServiceKit/OWSDisappearingMessagesConfiguration.h>
#import <SignalServiceKit/OWSPrimaryStorage+SessionStore.h>
#import <SignalServiceKit/OWSVerificationStateChangeMessage.h>
#import <SignalServiceKit/SecurityUtils.h>
#import <SignalServiceKit/TSCall.h>
#import <SignalServiceKit/TSInvalidIdentityKeyReceivingErrorMessage.h>
#import <SignalServiceKit/TSThread.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSAccountManager (DebugUI)

- (void)resetForRegistration;

@end

#pragma mark -

@interface OWSStorage (DebugUI)

- (NSData *)databasePassword;

@end

#pragma mark -

@implementation DebugUIMisc

#pragma mark - Factory Methods

- (NSString *)name
{
    return @"Misc.";
}

- (nullable OWSTableSection *)sectionForThread:(nullable TSThread *)thread
{
    NSMutableArray<OWSTableItem *> *items = [NSMutableArray new];
    [items addObject:[OWSTableItem itemWithTitle:@"Enable Manual Censorship Circumvention"
                                     actionBlock:^{
                                         [DebugUIMisc setManualCensorshipCircumventionEnabled:YES];
                                     }]];
    [items addObject:[OWSTableItem itemWithTitle:@"Disable Manual Censorship Circumvention"
                                     actionBlock:^{
                                         [DebugUIMisc setManualCensorshipCircumventionEnabled:NO];
                                     }]];
    [items addObject:[OWSTableItem itemWithTitle:@"Clear experience upgrades (works once per launch)"
                                     actionBlock:^{
                                         [ExperienceUpgrade removeAllObjectsInCollection];
                                     }]];
    [items addObject:[OWSTableItem itemWithTitle:@"Clear hasDismissedOffers"
                                     actionBlock:^{
                                         [DebugUIMisc clearHasDismissedOffers];
                                     }]];

    [items addObject:[OWSTableItem
                         itemWithTitle:@"Re-register"
                           actionBlock:^{
                               [OWSAlerts
                                   showConfirmationAlertWithTitle:@"Re-register?"
                                                          message:@"If you proceed, you will not lose any of your "
                                                                  @"current messages, but your account will be "
                                                                  @"deactivated until you complete re-registration."
                                                     proceedTitle:@"Proceed"
                                                    proceedAction:^(UIAlertAction *_Nonnull action) {
                                                        [DebugUIMisc reregister];
                                                    }];
                           }]];


    if (thread) {
        [items addObject:[OWSTableItem itemWithTitle:@"Send Encrypted Database"
                                         actionBlock:^{
                                             [DebugUIMisc sendEncryptedDatabase:thread];
                                         }]];
        [items addObject:[OWSTableItem itemWithTitle:@"Send Unencrypted Database"
                                         actionBlock:^{
                                             [DebugUIMisc sendUnencryptedDatabase:thread];
                                         }]];
    }

    [items addObject:[OWSTableItem itemWithTitle:@"Show 2FA Reminder"
                                     actionBlock:^() {
                                         UINavigationController *navController =
                                             [OWS2FAReminderViewController wrappedInNavController];
                                         [[[UIApplication sharedApplication] frontmostViewController]
                                             presentViewController:navController
                                                          animated:YES
                                                        completion:nil];
                                     }]];

    [items addObject:[OWSTableItem itemWithTitle:@"Reset 2FA Repetition Interval"
                                     actionBlock:^() {
                                         [OWS2FAManager.sharedManager setDefaultRepetitionInterval];
                                     }]];


#ifdef DEBUG
    [items addObject:[OWSTableItem subPageItemWithText:@"Share UIImage"
                                           actionBlock:^(UIViewController *viewController) {
                                               UIImage *image =
                                                   [UIImage imageWithColor:UIColor.redColor size:CGSizeMake(1.f, 1.f)];
                                               [AttachmentSharing showShareUIForUIImage:image];
                                           }]];
#endif

    return [OWSTableSection sectionWithTitle:self.name items:items];
}

+ (void)reregister
{
    DDLogInfo(@"%@ re-registering.", self.logTag);
    [[TSAccountManager sharedInstance] resetForRegistration];
    [[Environment current].preferences unsetRecordedAPNSTokens];

    RegistrationViewController *viewController = [RegistrationViewController new];
    OWSNavigationController *navigationController =
        [[OWSNavigationController alloc] initWithRootViewController:viewController];
    navigationController.navigationBarHidden = YES;

    [UIApplication sharedApplication].delegate.window.rootViewController = navigationController;
}

+ (void)setManualCensorshipCircumventionEnabled:(BOOL)isEnabled
{
    OWSCountryMetadata *countryMetadata = nil;
    NSString *countryCode = OWSSignalService.sharedInstance.manualCensorshipCircumventionCountryCode;
    if (countryCode) {
        countryMetadata = [OWSCountryMetadata countryMetadataForCountryCode:countryCode];
    }

    if (!countryMetadata) {
        countryCode = [PhoneNumber defaultCountryCode];
        if (countryCode) {
            countryMetadata = [OWSCountryMetadata countryMetadataForCountryCode:countryCode];
        }
    }

    if (!countryMetadata) {
        countryCode = @"US";
        countryMetadata = [OWSCountryMetadata countryMetadataForCountryCode:countryCode];
    }

    OWSAssert(countryMetadata);
    OWSSignalService.sharedInstance.manualCensorshipCircumventionCountryCode = countryCode;
    OWSSignalService.sharedInstance.manualCensorshipCircumventionDomain = countryMetadata.googleDomain;

    OWSSignalService.sharedInstance.isCensorshipCircumventionManuallyActivated = isEnabled;
}

+ (void)clearHasDismissedOffers
{
    [OWSPrimaryStorage.dbReadWriteConnection
        readWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            NSMutableArray<TSContactThread *> *contactThreads = [NSMutableArray new];
            [transaction
                enumerateKeysAndObjectsInCollection:[TSThread collection]
                                         usingBlock:^(NSString *_Nonnull key, id _Nonnull object, BOOL *_Nonnull stop) {
                                             TSThread *thread = object;
                                             if (thread.isGroupThread) {
                                                 return;
                                             }
                                             TSContactThread *contactThread = object;
                                             [contactThreads addObject:contactThread];
                                         }];
            for (TSContactThread *contactThread in contactThreads) {
                if (contactThread.hasDismissedOffers) {
                    contactThread.hasDismissedOffers = NO;
                    [contactThread saveWithTransaction:transaction];
                }
            }
        }];
}

+ (void)sendEncryptedDatabase:(TSThread *)thread
{
    NSString *filePath = [OWSFileSystem temporaryFilePathWithFileExtension:@"sqlite"];
    NSString *fileName = filePath.lastPathComponent;

    __block BOOL success;
    [OWSPrimaryStorage.sharedManager.newDatabaseConnection
        readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
            NSError *error;
            success = [[NSFileManager defaultManager] copyItemAtPath:OWSPrimaryStorage.databaseFilePath
                                                              toPath:filePath
                                                               error:&error];
            if (!success || error) {
                OWSFail(@"%@ Could not copy database file: %@.", self.logTag, error);
                success = NO;
            }
        }];

    if (!success) {
        return;
    }

    OWSMessageSender *messageSender = [Environment current].messageSender;
    NSString *utiType = [MIMETypeUtil utiTypeForFileExtension:fileName.pathExtension];
    DataSource *_Nullable dataSource = [DataSourcePath dataSourceWithFilePath:filePath];
    [dataSource setSourceFilename:fileName];
    SignalAttachment *attachment = [SignalAttachment attachmentWithDataSource:dataSource dataUTI:utiType];
    NSData *databasePassword = [OWSPrimaryStorage.sharedManager databasePassword];
    attachment.captionText = [databasePassword hexadecimalString];
    if (!attachment || [attachment hasError]) {
        OWSFail(@"%@ attachment[%@]: %@", self.logTag, [attachment sourceFilename], [attachment errorName]);
        return;
    }
    [ThreadUtil sendMessageWithAttachment:attachment inThread:thread messageSender:messageSender completion:nil];
}

+ (void)sendUnencryptedDatabase:(TSThread *)thread
{
    NSString *filePath = [OWSFileSystem temporaryFilePathWithFileExtension:@"sqlite"];
    NSString *fileName = filePath.lastPathComponent;

    NSError *error = [OWSPrimaryStorage.sharedManager.newDatabaseConnection backupToPath:filePath];
    if (error) {
        OWSFail(@"%@ Could not copy database file: %@.", self.logTag, error);
        return;
    }

    OWSMessageSender *messageSender = [Environment current].messageSender;
    NSString *utiType = [MIMETypeUtil utiTypeForFileExtension:fileName.pathExtension];
    DataSource *_Nullable dataSource = [DataSourcePath dataSourceWithFilePath:filePath];
    [dataSource setSourceFilename:fileName];
    SignalAttachment *attachment = [SignalAttachment attachmentWithDataSource:dataSource dataUTI:utiType];
    if (!attachment || [attachment hasError]) {
        OWSFail(@"%@ attachment[%@]: %@", self.logTag, [attachment sourceFilename], [attachment errorName]);
        return;
    }
    [ThreadUtil sendMessageWithAttachment:attachment inThread:thread messageSender:messageSender completion:nil];
}

@end

NS_ASSUME_NONNULL_END
