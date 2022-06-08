//
//  DKStackBacktrack.m
//  DKStackBacktrack
//
//  Created by admin on 2022/3/23.
//

#import "DKStackBacktrack.h"
#import <mach/mach.h>
#import <pthread/pthread.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>


#pragma mark - DEFINE MACRO FOR DIFFERENT CPU ARCHITECTURE -

#if defined(__arm64__)
#define DK_THREAD_STATE_COUNT                           ARM_THREAD_STATE64_COUNT
#define DK_THREAD_STATE                                 ARM_THREAD_STATE64
#define DK_MACH_PC_ADDRESS(context)                     ((mcontext_t const)(&context))->__ss.__pc
#define DK_MACH_LR_ADDRESS(context)                     ((mcontext_t const)(&context))->__ss.__lr
#define DK_MACH_FP_ADDRESS(context)                     ((mcontext_t const)(&context))->__ss.__fp
#define DK_CALL_INSTRUCTION_FROM_RETURN_ADDRESS(A)      (((A) & ~(3UL)) - 1)

#elif defined(__arm__)
#define DK_THREAD_STATE_COUNT                           ARM_THREAD_STATE_COUNT
#define DK_THREAD_STATE                                 ARM_THREAD_STATE
#define DK_MACH_PC_ADDRESS(context)                     ((mcontext_t const)(&context))->__ss.__pc
#define DK_MACH_LR_ADDRESS(context)                     ((mcontext_t const)(&context))->__ss.__lr
#define DK_MACH_FP_ADDRESS(context)                     ((mcontext_t const)(&context))->__ss.__r[7]
#define DK_CALL_INSTRUCTION_FROM_RETURN_ADDRESS(A)      (((A) & ~(1UL)) - 1)

#elif defined(__x86_64__)
#define DK_THREAD_STATE_COUNT                           x86_THREAD_STATE64_COUNT
#define DK_THREAD_STATE                                 x86_THREAD_STATE64
#define DK_MACH_PC_ADDRESS(context)                     ((mcontext_t const)(&context))->__ss.__rip
#define DK_MACH_LR_ADDRESS(context)                     0
#define DK_MACH_FP_ADDRESS(context)                     ((mcontext_t const)(&context))->__ss.__rbp
#define DK_CALL_INSTRUCTION_FROM_RETURN_ADDRESS(A)      ((A) - 1)

#elif defined(__i386__)
#define DK_THREAD_STATE_COUNT                           x86_THREAD_STATE32_COUNT
#define DK_THREAD_STATE                                 x86_THREAD_STATE32
#define DK_MACH_PC_ADDRESS(context)                     ((mcontext_t const)(&context))->__ss.__eip
#define DK_MACH_LR_ADDRESS(context)                     0
#define DK_MACH_FP_ADDRESS(context)                     ((mcontext_t const)(&context))->__ss.__ebp
#define DK_CALL_INSTRUCTION_FROM_RETURN_ADDRESS(A)      ((A) - 1)
#endif

#if defined(__LP64__)
#define TRACE_FMT                                       "%-4d%-31s 0x%016lx %s + %lu"
#define POINTER_FMT                                     "0x%016lx"
#define POINTER_SHORT_FMT                               "0x%lx"
#define DK_NLIST struct nlist_64
#else
#define TRACE_FMT                                       "%-4d%-31s 0x%08lx %s + %lu"
#define POINTER_FMT                                     "0x%08lx"
#define POINTER_SHORT_FMT                               "0x%lx"
#define DK_NLIST struct nlist
#endif

// 栈帧结构体
typedef struct DKStackFrameEntry {
    const struct DKStackFrameEntry * const previous; // 前一个栈帧地址
    const uintptr_t return_address; // 栈帧的函数返回地址（此函数结束后返回的上一个函数的下一条指令的地址）
} DKStackFrameEntry;

// 存储 thread 信息的结构体
typedef struct DKThreadInfoEntry {
    double cpuUsage;
    double userTime;
} DKThreadInfoEntry;

static mach_port_t _dk_main_thread_id;

@implementation DKStackBacktrack

+ (void)load
{
    _dk_main_thread_id = mach_thread_self();
}

+ (NSString *)stackBacktraceOfMainThread
{
    return [self stackBacktraceOfNSThread:[NSThread mainThread]];
}

+ (NSString *)stackBacktraceOfCurrentThread
{
    return [self stackBacktraceOfNSThread:[NSThread currentThread]];
}

+ (NSString *)stackBacktraceOfAllThread
{
    thread_act_array_t list;
    mach_msg_type_number_t listCnt;
    kern_return_t kr = task_threads(mach_task_self(), &list, &listCnt);
    if (kr != KERN_SUCCESS) {
        return @"DKStackBacktrack - ERROR: Fail to get information of all threads";
    }
    
    NSMutableString *resultString = [NSMutableString stringWithFormat:@"\nDKStackBacktrack 所有 %u threads 调用栈信息:\n", listCnt];
    
    for (int i = 0; i < listCnt; i++) {
        char name[256];
        pthread_t pt = pthread_from_mach_thread_np(list[i]);
        pthread_getname_np(pt, name, sizeof(name));
        NSString *sname = [NSString stringWithCString:name encoding:NSUTF8StringEncoding];
        if ( !sname || [sname isEqualToString:@""] ) {
            sname = [NSString stringWithFormat:@"Thread number: %d", i + 1];
        } else {
            sname = [NSString stringWithFormat:@"Thread number: %d name: (%@)", i + 1, sname];
        }
        
        [resultString appendString:[self stackBacktraceOfThread:list[i] threadDesc:sname]];
    }
    return resultString;
}


#pragma mark - private -

+ (NSString *)stackBacktraceOfNSThread:(NSThread *)nsthread
{
    return [self stackBacktraceOfThread:dk_machThreadFromNSThread(nsthread) threadDesc:nsthread.description];
}

+ (NSString *)stackBacktraceOfThread:(thread_t)thread threadDesc:(NSString *)threadDesc
{
    // 1.获取当前线程的上下文信息
    _STRUCT_MCONTEXT machineContent;
    mach_msg_type_number_t stateCnt = DK_THREAD_STATE_COUNT;
    if (thread_get_state(thread, DK_THREAD_STATE, (thread_state_t)&machineContent.__ss, &stateCnt) != KERN_SUCCESS) {
        return [NSString stringWithFormat:@"DKStackBacktrack - [%@] ERROR: Fail to get information about thread: %u", threadDesc, thread];
    };
    
    // 2.创建 backtraceBuffer
    uintptr_t backtraceBuffer[50];
    int i = 0;
    
    // 3.得到 PC 寄存器 (当前函数的下一条指令) 地址
    const uintptr_t pcAddress = DK_MACH_PC_ADDRESS(machineContent);
    backtraceBuffer[i] = pcAddress;
    i++;
    
    // 4.得到 LR 寄存器 (当前函数返回后调用方的下一条指令) 地址, 位于调用方的代码中
    uintptr_t lrAddress = DK_MACH_LR_ADDRESS(machineContent);
    if (lrAddress) {
        backtraceBuffer[i] = lrAddress;
        i++;
    }
    
    if (pcAddress == 0) {
        return [NSString stringWithFormat:@"DKStackBacktrack - [%@] ERROR: Fail to get instruction address", threadDesc];
    }
    
    // 5.得到 FP 寄存器, 通过 FP 可以得到整个函数的调用关系
    DKStackFrameEntry stackFrame = {0};
    const uintptr_t framePtr = DK_MACH_FP_ADDRESS(machineContent);
    if (framePtr == 0 ||
        dk_machMemCopy((void *)framePtr, &stackFrame, sizeof(stackFrame)) != KERN_SUCCESS) {
        return [NSString stringWithFormat:@"[DKStackBacktrack] - [%@] ERROR: Fail to get frame pointer", threadDesc];
    }
    
    // 6.反向遍历得到函数堆栈
    for (; i < 50; i++) {
        backtraceBuffer[i] = stackFrame.return_address;
        if (backtraceBuffer[i] == 0 ||
            stackFrame.previous == 0 ||
            dk_machMemCopy((void *)stackFrame.previous, &stackFrame, sizeof stackFrame) != KERN_SUCCESS) {
            break;
        }
    }
    
    /**
        Dl_info 函数信息结构体：
         typedef struct dl_info {
                 const char      *dli_fname;     // 文件地址
                 void            *dli_fbase;     // 起始地址（machO模块的虚拟地址）
                 const char      *dli_sname;     // 符号名称
                 void            *dli_saddr;     // 内存真实地址(偏移后的真实物理地址)
         } Dl_info;
     */
    
    // 7.对当前的堆栈进行符号化
    // 7.1找到地址所属的内存镜像
    // 7.2然后定位镜像中的符号表
    // 7.3最后在符号表中找到目标地址的符号
    int backtraceLength = i;
    Dl_info symbolicated[backtraceLength];
    dk_symbolicate(backtraceBuffer, symbolicated, backtraceLength, 0);
    
    NSMutableString *resultString = [[NSMutableString alloc] initWithFormat:@"\nDKStackBacktrack - [%@ id: %u] 调用栈信息:\n", threadDesc, thread];
    
    // 线程信息(cpu、time)
    DKThreadInfoEntry threadInfoEntry = {0};
    if (dk_threadInfoFromThread(thread, &threadInfoEntry)) {
        [resultString appendString:[NSString stringWithFormat:@"💻 CPU used: %0.2f\%%\n⏰ user time: %0.2f ms\n", threadInfoEntry.cpuUsage, threadInfoEntry.userTime]];
    };
    
    for (int i = 0; i < backtraceLength; ++i) {
        [resultString appendFormat:@"%@", dk_logBacktraceEntry(i, backtraceBuffer[i], &symbolicated[i])];
    }
    
    // 释放资源, 防止内存泄漏
    assert(vm_deallocate(mach_task_self(), (vm_address_t)thread, sizeof(thread_t)) == KERN_SUCCESS);
    
    return [resultString copy];
}

/// 获取线程信息
bool dk_threadInfoFromThread(thread_t thread, DKThreadInfoEntry *threadInfoEntry) {
    thread_info_data_t threadInfo;
    thread_basic_info_t threadBasicInfo;
    mach_msg_type_number_t threadInfoCnt = THREAD_INFO_MAX;
    if (thread_info((thread_act_t)thread, THREAD_BASIC_INFO, (thread_info_t)threadInfo, &threadInfoCnt) == KERN_SUCCESS) {
        threadBasicInfo = (thread_basic_info_t)threadInfo;
        if (!(threadBasicInfo->flags & TH_FLAGS_IDLE)) {
            threadInfoEntry->cpuUsage = threadBasicInfo->cpu_usage/10;
            threadInfoEntry->userTime = threadBasicInfo->system_time.microseconds/1000;
            return true;
        }
    }
    return false;
}

/// nsthread 转换成 mach thread
/// 该方法用了一个很巧妙的方法, 将需要抓取的线程设置一个特定的名字, 然后在 mach thread 的列表中遍历, 通过名字的对比来找到当前的 NSThread 对应的 pthread_t
thread_t dk_machThreadFromNSThread(NSThread *nsthread) {
    char name[256];
    thread_act_array_t list;
    mach_msg_type_number_t listCnt;
    task_threads(mach_task_self(), &list, &listCnt);
    
    if ([nsthread isMainThread]) {
        return (thread_t)_dk_main_thread_id;
    }
    
    // 时间戳
    NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
    NSString *originName = [nsthread name];
    [nsthread setName:[NSString stringWithFormat:@"%f", currentTimestamp]];
    
    for (int i = 0; i < listCnt; i++) {
        pthread_t pt = pthread_from_mach_thread_np(list[i]);
        if (pt) {
            // 获取线程名字
            name[0] = '\0';
            pthread_getname_np(pt, name, sizeof name);
            // 从线程的列表中遍历线程，寻找 name 匹配的线程返回
            if (!strcmp(name, [nsthread name].UTF8String)) {
                [nsthread setName:originName];
                return list[i];
            }
        }
    }
    
    [nsthread setName:originName];
    return mach_thread_self();
}

/// 拷贝FP到结构体
/// @param src FP
/// @param dst DKStackFrame
/// @param byteSize DKStackFrame 长度
kern_return_t dk_machMemCopy(const void *const src, void *const dst, const size_t byteSize) {
    /**
     kern_return_t vm_read_overwrite
     (
         vm_map_t target_task,  // task任务
         vm_address_t address,  // 栈帧指针FP
         vm_size_t size,  // 结构体大小 sizeof（StackFrame）
         vm_address_t data,  // 结构体指针StackFrame
         vm_size_t *outsize  // 赋值大小
     );
     */
    vm_size_t bytesCopied = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)src, (vm_size_t)byteSize, (vm_address_t)dst, &bytesCopied);
}

/// 地址转符号字符串
/// @param backtraceBuffer 栈数据数组
/// @param symbolsBuffer 空数组
/// @param numEntries 栈数据长度
/// @param skippedEntries = 0
void dk_symbolicate(const uintptr_t *const backtraceBuffer, Dl_info *const symbolsBuffer, const int numEntries, const int skippedEntries) {
    int i = 0;
    // 第一个存储的是 PC 寄存器
    if (!skippedEntries && i < numEntries) {
//        dladdr((const void *)backtraceBuffer[i], &symbolsBuffer[i]);
        dk_dladdr(backtraceBuffer[i], &symbolsBuffer[i]);
        i++;
    }
    
    // 后面存储的都是 LR
    for (; i < numEntries; i++) {
//        dladdr((const void *)DK_CALL_INSTRUCTION_FROM_RETURN_ADDRESS(backtraceBuffer[i]), &symbolsBuffer[i]);
       dk_dladdr(DK_CALL_INSTRUCTION_FROM_RETURN_ADDRESS(backtraceBuffer[i]), &symbolsBuffer[i]);
    }
}

/// 找到LR指针最近的符号, 放到 info 中
bool dk_dladdr(const uintptr_t address, Dl_info * const info) {
    // 1.找到地址所属的内存镜像
    // 2.然后定位镜像中的符号表
    // 3.最后在符号表中找到目标地址的符号
    
    info->dli_fbase = NULL;
    info->dli_fname = NULL;
    info->dli_saddr = NULL;
    info->dli_sname = NULL;
    
    // 得到 adress 所在的 image 的索引
    const uint32_t idx = dk_imageIndexFromAddress(address);
    if (idx == UINT_MAX) {
        return false;
    }
    
    // 得到 mach-o 头部信息结构体指针(header), header 对象存储 load command 个数及大小
    const struct mach_header *header = _dyld_get_image_header(idx);
    
    // 随机基址 slide
    const uintptr_t slide = (uintptr_t)_dyld_get_image_vmaddr_slide(idx);
    
    // 得到 LR 的 在 mach-o 的真实内存地址
    const uintptr_t addressWSlide = address - slide;
    
    // 得到段的基地址
    const uintptr_t segmentBaseAddress = dk_segmentBaseAddressOfImageIndex(idx) + slide;
    if (segmentBaseAddress == 0) {
        return false;
    }
    
    info->dli_fname = _dyld_get_image_name(idx);
    info->dli_fbase = (void *)header;
    
    /* 位于系统库 头文件中 struct nlist {
      union {
         uint32_t n_strx;  // 符号名在字符串表中的偏移量
      } n_un;
      uint8_t n_type;
      uint8_t n_sect;
      int16_t n_desc;
      uint32_t n_value; // 符号在内存中的地址，类似于函数虚拟地址指针
    };*/
    
    // 查找符号表并获取与地址最接近的符号
    const DK_NLIST *bestMatch = NULL;
    uintptr_t bestDistance = ULONG_MAX;
    uintptr_t cmdPtr = dk_firstCmdFromMachHeader(header);
    if (cmdPtr == 0) {
        return false;
    }
    for (uint32_t iCmd = 0; iCmd < header->ncmds; iCmd++) {
        const struct load_command *loadCmd = (struct load_command *)cmdPtr;
        if (loadCmd->cmd == LC_SYMTAB) {
            const struct symtab_command *symtabCmd = (struct symtab_command *)cmdPtr;
            // 得到符号表地址
            const DK_NLIST *symbolTable = (struct nlist_64 *)(segmentBaseAddress + symtabCmd->symoff);
            // 得到字符串表地址
            const uintptr_t stringTable = segmentBaseAddress + symtabCmd->stroff;

            // 遍历符号表找出追佳匹配
            for (uint32_t iSym = 0; iSym < symtabCmd->nsyms; iSym++) {
                if (symbolTable[iSym].n_value != 0) {
                    // 得到符号表在内存中的真实地址
                    uintptr_t sysbolBaseAddress = symbolTable[iSym].n_value;
                    // 得到当前符号表与指令的距离
                    uintptr_t currentDistance = addressWSlide - sysbolBaseAddress;
                    // 函数地址值在此符号之后 且 距离小于之前的最近距离
                    if (addressWSlide >= sysbolBaseAddress &&
                        currentDistance <= bestDistance) {
                        // 最匹配的符号 = 当前符号表结构体 + n个偏移
                        bestMatch = symbolTable + iSym;
                        // 最近距离 = 当前距离
                        bestDistance = currentDistance;
                    }
                }
            }
            
            if (bestMatch != NULL) {
                // 去字符串表中寻找对应的符号名称, 记录符号的虚拟地址+aslr
                // 符号真实地址 = n_value + slide
                info->dli_saddr = (void *)(bestMatch->n_value + slide);
                // 字符真实地址 = 字符串表地址 + 最接近的符号中的字符串表(数组)索引值 n_strx(输出从此处到下一个null)
                info->dli_sname = (const char *)((intptr_t)stringTable + (intptr_t)bestMatch->n_un.n_strx);
                // 去掉下划线
                if(*info->dli_sname == '_') {
                    info->dli_sname++;
                }
                // 所有的 symbols 的已经被处理好了
                if (info->dli_saddr == info->dli_fbase && bestMatch->n_type == 3) {
                    info->dli_sname = NULL;
                }
                break;
            }
        }
        cmdPtr += loadCmd->cmdsize;
    }
    return true;
}

// 通过 address 找到对应的 image 的索引, 从而能够得到 image 的更多信息
uint32_t dk_imageIndexFromAddress(const uintptr_t address) {
    // 返回当前进程中加载的镜像的数量
    const uint32_t imageCount = _dyld_image_count();
    const struct mach_header *header = 0;
    
    // 遍历 image
    for (uint32_t iImg = 0; iImg < imageCount; iImg++) {
        header = _dyld_get_image_header(iImg);
        if (header != NULL) {
            // 得到减去 ASLR 之后的地址, 在 mach-o 中真实地址
            uintptr_t addressWSlide = address - (uintptr_t)_dyld_get_image_vmaddr_slide(iImg);
            // 得到 Header 下面第一个 loadCommands 的地址
            uintptr_t cmdPtr = dk_firstCmdFromMachHeader(header);
            if (cmdPtr == 0) {
                continue;
            }
            // 遍历 Header 的 所有 loadCommands 找到符合条件的镜像索引
            for (uint32_t iCmd = 0; iCmd < header->ncmds; iCmd++) {
                const struct load_command *loadCmd = (struct load_command *)cmdPtr;
                if (loadCmd->cmd == LC_SEGMENT) {
                    const struct segment_command *segCmd = (struct segment_command *)cmdPtr;
                    if (addressWSlide >= segCmd->vmaddr &&
                        addressWSlide < segCmd->vmaddr + segCmd->vmsize) {
                        return iImg;
                    }
                }
                else if (loadCmd->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *segCmd = (struct segment_command_64 *)cmdPtr;
                    if (addressWSlide >= segCmd->vmaddr &&
                        addressWSlide < segCmd->vmaddr + segCmd->vmsize) {
                        return iImg;
                    }
                }
                cmdPtr += loadCmd->cmdsize;
            }
        }
    }
    return UINT_MAX;
}

uintptr_t dk_firstCmdFromMachHeader(const struct mach_header *header) {
    switch (header->magic) {
        case MH_MAGIC:
        case MH_CIGAM:
            return (uintptr_t)(header + 1);
        case MH_MAGIC_64:
        case MH_CIGAM_64:
            return (uintptr_t)((struct mach_header_64 *)header + 1);
        default:
            return 0;
    }
}

/// 计算程序未减去 slide 的链接基址
uintptr_t dk_segmentBaseAddressOfImageIndex(const uint32_t idx) {
    const struct mach_header *header = _dyld_get_image_header(idx);
    
    uintptr_t cmdPtr = dk_firstCmdFromMachHeader(header);
    if (cmdPtr == 0) {
        return 0;
    }
    
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *loadCmd = (struct load_command *)cmdPtr;
        if (loadCmd->cmd == LC_SEGMENT) {
            const struct segment_command *segmentCmd = (struct segment_command *)cmdPtr;
            if (strcmp(segmentCmd->segname, SEG_LINKEDIT) == 0) {
                return segmentCmd->vmaddr - segmentCmd->fileoff;
            }
        }
        else if (loadCmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segmentCmd = (struct segment_command_64 *)cmdPtr;
            if (strcmp(segmentCmd->segname, SEG_LINKEDIT) == 0) {
                return segmentCmd->vmaddr - segmentCmd->fileoff;
            }
        }
        cmdPtr += loadCmd->cmdsize;
    }
    return 0;
}


#pragma mark - Generate Bacbsrack String -

/// 组装符号字符串
NSString *dk_logBacktraceEntry(const int entryNum,
                               const uintptr_t address,
                               const Dl_info * const dlInfo) {
    char faddrBuff[20];
    char saddrBuff[20];
    
    const char *fname = dk_lastPathEntry(dlInfo->dli_fname);
    if(fname == NULL) {
        sprintf(faddrBuff, POINTER_FMT, (uintptr_t)dlInfo->dli_fbase);
        fname = faddrBuff;
    }
    
    uintptr_t offset = address - (uintptr_t)dlInfo->dli_saddr;
    const char *sname = dlInfo->dli_sname;
    if(sname == NULL) {
        sprintf(saddrBuff, POINTER_SHORT_FMT, (uintptr_t)dlInfo->dli_fbase);
        sname = saddrBuff;
        offset = address - (uintptr_t)dlInfo->dli_fbase;
    }
    return [NSString stringWithFormat:@"%-30s  0x%08" PRIxPTR " %s + %lu\n" ,fname, (uintptr_t)address, sname, offset];
}

const char *dk_lastPathEntry(const char * const path) {
    if(path == NULL) {
        return NULL;
    }
    
    char *lastFile = strrchr(path, '/');
    return lastFile == NULL ? path : lastFile + 1;
}

@end
