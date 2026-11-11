#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift no puede atrapar excepciones de Objective-C. AVAudioEngine las lanza
/// (por ejemplo, installTap con un formato que ya no coincide cuando unos
/// audífonos Bluetooth se desconectan) y sin esto cierran la app.
@interface ObjCExceptionCatcher : NSObject
+ (BOOL)tryBlock:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error NS_SWIFT_NAME(catching(_:));
@end

NS_ASSUME_NONNULL_END
