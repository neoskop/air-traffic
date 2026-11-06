#import "ATPredicateParsing.h"

NSPredicate * _Nullable ATParsePredicate(NSString *format, NSString * _Nullable * _Nullable errorMessage) {
    @try {
        return [NSPredicate predicateWithFormat:format argumentArray:@[]];
    } @catch (NSException *exception) {
        if (errorMessage != NULL) {
            *errorMessage = exception.reason ?: exception.name;
        }
        return nil;
    }
}
