#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Parst einen NSPredicate-Formatstring ohne Argumente. Fängt die NSException,
/// die Foundation bei ungültigen Formaten wirft, und liefert dann nil.
NSPredicate * _Nullable ATParsePredicate(NSString *format, NSString * _Nullable * _Nullable errorMessage);

NS_ASSUME_NONNULL_END
