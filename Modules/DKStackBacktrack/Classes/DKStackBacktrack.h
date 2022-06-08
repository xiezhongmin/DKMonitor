//
//  DKStackBacktrack.h
//  DKStackBacktrack
//
//  Created by admin on 2022/3/23.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DKStackBacktrack : NSObject

+ (NSString *)stackBacktraceOfMainThread;
+ (NSString *)stackBacktraceOfCurrentThread;
+ (NSString *)stackBacktraceOfAllThread;

@end

NS_ASSUME_NONNULL_END
