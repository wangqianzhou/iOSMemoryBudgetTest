//
//  ViewController.m
//  MemoryTest
//
//  Created by Jan Ilavsky on 11/5/12.
//  Copyright (c) 2012 Jan Ilavsky. All rights reserved.
//

#import "ViewController.h"
#import <sys/types.h>
#import <sys/sysctl.h>
#import "SystemMemoryObserver.h"
#include <mach/vm_statistics.h>
#include <mach/mach_types.h>
#include <mach/mach_init.h>
#include <mach/mach_host.h>
#import <mach/mach.h>
#include <sys/sysctl.h>

#define CRASH_MEMORY_FILE_NAME @"CrashMemory.dat"
#define MEMORY_WARNINGS_FILE_NAME @"MemoryWarnings.dat"

double currentTime() { return [[NSDate date] timeIntervalSince1970]; }

int systemMemoryLevel()
{
#if IOS_SIMULATOR
    return 35;
#else
    static int memoryFreeLevel = -1;
    static double previousCheckTime;
    double time = currentTime();
    if (time - previousCheckTime < 0.1)
        return memoryFreeLevel;
    previousCheckTime = time;
    size_t size = sizeof(memoryFreeLevel);
    sysctlbyname("kern.memorystatus_level", &memoryFreeLevel, &size, nullptr, 0);
    return memoryFreeLevel;
#endif
    
//    
//    return 10;
}


@interface ViewController () {
    
    NSTimer *timer;

    int allocatedMB;
    Byte *p[10000];
    uint64_t physicalMemorySize;
    uint64_t userMemorySize;
    
    NSMutableArray *infoLabels;
    NSMutableArray *memoryWarnings;
    
    BOOL initialLayoutFinished;
    BOOL firstMemoryWarningReceived;
}

@property (weak, nonatomic) IBOutlet UIView *progressBarBG;
@property (weak, nonatomic) IBOutlet UIView *alocatedMemoryBar;
@property (weak, nonatomic) IBOutlet UIView *kernelMemoryBar;
@property (weak, nonatomic) IBOutlet UILabel *userMemoryLabel;
@property (weak, nonatomic) IBOutlet UILabel *totalMemoryLabel;
@property (weak, nonatomic) IBOutlet UIButton *startButton;
@property (nonatomic, strong)  dispatch_source_t memoryStatusEventSource;
@end

@implementation ViewController

#pragma mark - Helpers

- (void)refreshUI {
    
    int physicalMemorySizeMB = physicalMemorySize / 1048576;
    int userMemorySizeMB = userMemorySize / 1048576;
    
    self.userMemoryLabel.text = [NSString stringWithFormat:@"%d MB -", userMemorySizeMB];
    self.totalMemoryLabel.text = [NSString stringWithFormat:@"%d MB -", physicalMemorySizeMB];
    
    CGRect rect;
    
    CGFloat userMemoryProgressLength = self.progressBarBG.bounds.size.height *  (userMemorySizeMB / (float)physicalMemorySizeMB);
    
    rect = self.userMemoryLabel.frame;
    rect.origin.y = roundf((self.progressBarBG.bounds.size.height - userMemoryProgressLength) - self.userMemoryLabel.bounds.size.height * 0.5f + self.progressBarBG.frame.origin.y - 3);
    self.userMemoryLabel.frame = rect;
    
    rect = self.kernelMemoryBar.frame;
    rect.size.height = roundf(self.progressBarBG.bounds.size.height - userMemoryProgressLength);
    self.kernelMemoryBar.frame = rect;
    
    rect = self.alocatedMemoryBar.frame;
    rect.size.height = roundf(self.progressBarBG.bounds.size.height * (allocatedMB / (float)physicalMemorySizeMB));
    rect.origin.y = self.progressBarBG.bounds.size.height - rect.size.height;
    self.alocatedMemoryBar.frame = rect;
}

- (void)refreshMemoryInfo {
    
    // Get memory info
    int mib[2];
    size_t length;
    mib[0] = CTL_HW;
    
    mib[1] = HW_MEMSIZE;
    length = sizeof(int64_t);
    sysctl(mib, 2, &physicalMemorySize, &length, NULL, 0);
    
    mib[1] = HW_USERMEM;
    length = sizeof(int64_t);
    sysctl(mib, 2, &userMemorySize, &length, NULL, 0);
    
    
    vm_size_t page_size;
    mach_port_t mach_port;
    mach_msg_type_number_t count;
    vm_statistics64_data_t vm_stats;
    
    long long free_memory = 0;
    long long used_memory = 0;
    
    mach_port = mach_host_self();
    count = sizeof(vm_stats) / sizeof(natural_t);
    if (KERN_SUCCESS == host_page_size(mach_port, &page_size) &&
        KERN_SUCCESS == host_statistics64(mach_port, HOST_VM_INFO,
                                          (host_info64_t)&vm_stats, &count))
    {
        free_memory = (int64_t)vm_stats.free_count * (int64_t)page_size;
        
        used_memory = ((int64_t)vm_stats.active_count +
                                 (int64_t)vm_stats.inactive_count +
                                 (int64_t)vm_stats.wire_count) *  (int64_t)page_size;
    }
    
    struct task_basic_info info;
    mach_msg_type_number_t size = sizeof(info);
    
    task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &size);
    
    NSLog(@"currentMemLevel : %3d, alloc: %zdM; current:%zd, physicalUse:%zd, UserUse:%zd, free:%lld, use:%lld, level:%lld",
          
          systemMemoryLevel(),
          allocatedMB,
          [SystemMemoryObserver currentVirtualSize],
          physicalMemorySize/1024/1024/4,
          userMemorySize/1024/1024,
          free_memory/1024/1024, used_memory/1024/1024,
          (info.resident_size + info.virtual_size) * 100 / physicalMemorySize);
}

- (void)allocateMemory {
    
    p[allocatedMB] = (Byte*)malloc(1048576);
    memset(p[allocatedMB], 0, 1048576);
    allocatedMB += 1;
    
    [self refreshMemoryInfo];
    [self refreshUI];

    
    if (firstMemoryWarningReceived) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
        [NSKeyedArchiver archiveRootObject:@(allocatedMB) toFile:[basePath stringByAppendingPathComponent:CRASH_MEMORY_FILE_NAME]];
    }
}

- (void)clearAll {
    
    for (int i = 0; i < allocatedMB; i++) {
        free(p[i]);
    }
    
    allocatedMB = 0;
    
    [infoLabels makeObjectsPerformSelector:@selector(removeFromSuperview)];
    [infoLabels removeAllObjects];
    
    [memoryWarnings removeAllObjects];
}

- (void)addLabelAtMemoryProgress:(int)memory text:(NSString*)text color:(UIColor*)color {

    CGFloat length = self.progressBarBG.bounds.size.height * (1.0f - memory / (float)(physicalMemorySize / 1048576));
    
    CGRect rect;
    rect.origin.x = 20;
    rect.size.width = self.progressBarBG.frame.origin.x - rect.origin.x - 8;
    rect.size.height = 20;
    rect.origin.y = roundf(self.progressBarBG.frame.origin.y + length - rect.size.height * 0.5f);

    UILabel *label = [[UILabel alloc] initWithFrame:rect];
    label.textAlignment = NSTextAlignmentRight;
    label.text = [NSString stringWithFormat:@"%@ %d MB -", text, memory];
    label.font = self.totalMemoryLabel.font;
    label.textColor = color;
    
    [infoLabels addObject:label];
    [self.view addSubview:label];
}

#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    infoLabels = [[NSMutableArray alloc] init];
    memoryWarnings = [[NSMutableArray alloc] init];
    
    [self registerMemoryPressureListener];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onRecvMemLimitNotification) name:kMemoryUseUpToKillZone object:nil];
}

- (void)viewDidLayoutSubviews {
    
    if (!initialLayoutFinished) {
    
        [self refreshMemoryInfo];
        [self refreshUI];
        
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
        NSInteger crashMemory = [[NSKeyedUnarchiver unarchiveObjectWithFile:[basePath stringByAppendingPathComponent:CRASH_MEMORY_FILE_NAME]] intValue];
        if (crashMemory > 0) {
            [self addLabelAtMemoryProgress:crashMemory text:@"Crash" color:[UIColor colorWithRed:0.8 green:0.0 blue:0.0 alpha:1.0]];
        }
        
        NSArray *lastMemoryWarnings = [NSKeyedUnarchiver unarchiveObjectWithFile:[basePath stringByAppendingPathComponent:MEMORY_WARNINGS_FILE_NAME]];
        if (lastMemoryWarnings) {
            
            for (NSNumber *number in lastMemoryWarnings) {
                
                [self addLabelAtMemoryProgress:[number intValue] text:@"Memory Warning" color:[UIColor colorWithWhite:0.6 alpha:1.0]];
            }
        }
        
        initialLayoutFinished = YES;
    }
}

- (void)viewDidUnload {
    
    [timer invalidate];
    [self clearAll];    
    
    infoLabels = nil;
    memoryWarnings = nil;
    
    initialLayoutFinished = NO;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [super viewDidUnload];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    
    firstMemoryWarningReceived = YES;
    
    [self addLabelAtMemoryProgress:allocatedMB text:@"Memory Warning" color:[UIColor colorWithWhite:0.6 alpha:1.0]];
    
    [memoryWarnings addObject:@(allocatedMB)];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *basePath = ([paths count] > 0) ? [paths objectAtIndex:0] : nil;
    [NSKeyedArchiver archiveRootObject:memoryWarnings toFile:[basePath stringByAppendingPathComponent:MEMORY_WARNINGS_FILE_NAME]];
}

- (void)registerMemoryPressureListener
{
    self.memoryStatusEventSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE,
                                                      0,
                                                      DISPATCH_MEMORYPRESSURE_NORMAL|DISPATCH_MEMORYPRESSURE_WARN|DISPATCH_MEMORYPRESSURE_CRITICAL,
                                                      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    
    dispatch_source_set_event_handler(self.memoryStatusEventSource, ^{
        unsigned long currentStatus = dispatch_source_get_data(self.memoryStatusEventSource);
        [self onMemoryWarningWithStatus:currentStatus];
    });
    
    dispatch_resume(self.memoryStatusEventSource);
}

- (void)onMemoryWarningWithStatus:(unsigned long)status
{
    NSLog(@"Recv Memory Status : %@", @(status));
}

#pragma mark - Actions

- (IBAction)startButtonPressed:(id)sender {
    
    [self clearAll];
    
    firstMemoryWarningReceived = NO;
    
    [timer invalidate];
    timer = [NSTimer scheduledTimerWithTimeInterval:0.02 target:self selector:@selector(allocateMemory) userInfo:nil repeats:YES];
}

- (void)onRecvMemLimitNotification
{
    NSLog(@"onRecvMemLimitNotification .........");
}
@end

