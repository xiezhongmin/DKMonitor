//
//  ViewController.m
//  DKMonitorDemo
//
//  Created by admin on 2022/3/21.
//

#import "ViewController.h"
#import <DKStackBacktrack/DKStackBacktrack.h>

@interface ViewController ()

@end

@implementation ViewController

- (void)foo {
    [self bar];
}

- (void)bar {
    while (true) {
        ;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSLog(@"%@", [DKStackBacktrack stackBacktraceOfMainThread]);
    });
    
    [self foo];
}


@end
