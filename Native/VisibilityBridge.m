// Runtime interface adapted from MIT-licensed code.
// Attribution and full license: THIRD_PARTY_NOTICES.md.
// MIT 라이선스 코드를 수정해 구성한 런타임 인터페이스입니다.
// 저작권 고지와 라이선스 전문은 THIRD_PARTY_NOTICES.md를 참고하세요.
#import "VisibilityBridge.h"
#import <dlfcn.h>
#import <objc/message.h>

static NSError *QBError(NSString *message) {
    return [NSError errorWithDomain:@"QuietBar.Visibility" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

BOOL QBVisibilityAvailable(void) {
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW | RTLD_LOCAL);
    });
    Class config = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertion = NSClassFromString(@"MBAssessmentModeAssertion");
    return framework && config && assertion
        && [config instancesRespondToSelector:NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:")]
        && [assertion instancesRespondToSelector:NSSelectorFromString(@"activateWithConfiguration:completionHandler:")]
        && [assertion instancesRespondToSelector:@selector(invalidate)];
}

void QBVisibilityInvalidate(id handle) {
    @try {
        if ([handle respondsToSelector:@selector(invalidate)]) {
            ((void (*)(id, SEL))objc_msgSend)(handle, @selector(invalidate));
        }
    } @catch (NSException *exception) {
        NSLog(@"QuietBar: failed to release visibility: %@", exception.reason);
    }
}

void QBVisibilityActivate(NSArray<NSString *> *bundles, void (^completion)(id, NSError *)) {
    void (^finish)(id, NSError *) = ^(id handle, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(handle, error); });
    };
    if (!QBVisibilityAvailable()) {
        finish(nil, QBError(@"MenuBarClientCore를 사용할 수 없습니다."));
        return;
    }
    @try {
        NSMutableArray<NSNumber *> *systemItems = [NSMutableArray array];
        for (NSInteger i = 0; i < 64; i++) [systemItems addObject:@(i)];
        id config = ((id (*)(id, SEL, id, id))objc_msgSend)(
            [NSClassFromString(@"MBAssessmentModeConfiguration") alloc],
            NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:"),
            systemItems, bundles);
        id handle = [[NSClassFromString(@"MBAssessmentModeAssertion") alloc] init];
        if (!config || !handle) { finish(nil, QBError(@"숨김 세션을 만들지 못했습니다.")); return; }
        // A hung or changed private API must not leave a delayed, invisible restriction.
        // 시스템 인터페이스의 응답 지연이나 변경으로 뒤늦게 보이지 않는 제한이 남지 않도록 합니다.
        __block BOOL settled = NO; // accessed only on the main queue / 메인 큐에서만 접근합니다.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (settled) return;
            settled = YES;
            QBVisibilityInvalidate(handle);
            completion(nil, QBError(@"숨김 엔진 응답 시간이 초과되었습니다."));
        });
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(
            handle, NSSelectorFromString(@"activateWithConfiguration:completionHandler:"), config,
            ^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (settled) { QBVisibilityInvalidate(handle); return; }
                    settled = YES;
                    if (error) QBVisibilityInvalidate(handle);
                    completion(error ? nil : handle, error);
                });
            });
    } @catch (NSException *exception) {
        finish(nil, QBError([NSString stringWithFormat:@"숨김 API가 변경되었습니다: %@", exception.reason]));
    }
}
