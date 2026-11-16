#import <Foundation/Foundation.h>

/* A greeter. */
@interface Greeter : NSObject
@property (nonatomic, copy) NSString *name;
- (void)greet;
@end

@implementation Greeter
- (void)greet {
    NSLog(@"Hello, %@", self.name); // say it
}
@end
