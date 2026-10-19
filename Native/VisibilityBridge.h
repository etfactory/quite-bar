#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
BOOL QBVisibilityAvailable(void);
void QBVisibilityActivate(NSArray<NSString *> *bundles,
                          void (^completion)(id _Nullable handle, NSError * _Nullable error));
void QBVisibilityInvalidate(id handle);
NS_ASSUME_NONNULL_END
