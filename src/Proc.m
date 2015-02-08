#import "Proc.h"
#import "AppIcon.h"
#import <mach/mach_init.h>
#import <mach/task_info.h>
#import <mach/thread_info.h>
#import <mach/mach_interface.h>
#import <mach/mach_port.h>

extern kern_return_t task_for_pid(task_port_t task, pid_t pid, task_port_t *target);
extern kern_return_t task_info(task_port_t task, unsigned int info_num, task_info_t info, unsigned int *info_count);

@implementation PSProc

- (instancetype)initWithKinfo:(struct kinfo_proc *)ki iconSize:(CGFloat)size
{
	if (self = [super init]) {
		@autoreleasepool {
			self.display = ProcDisplayStarted;
			self.pid = ki->kp_proc.p_pid;
			self.ppid = ki->kp_eproc.e_ppid;
			self.args = [PSProc getArgsByKinfo:ki];
			NSString *executable = [self.args objectAtIndex:0];
			self.name = [executable lastPathComponent];
			NSString *path = [executable stringByDeletingLastPathComponent];
			self.app = [PSAppIcon getAppByPath:path];
			memset(&events, 0, sizeof(events));
			if (self.app) {
				NSString *bundle = [self.app valueForKey:@"CFBundleIdentifier"];
				if (bundle) {
					self.name = bundle;//[self.app valueForKey:@"CFBundleDisplayName"];
					self.icon = [PSAppIcon getIconForApp:self.app bundle:bundle path:path size:size];
				}
			}
			[self updateWithKinfoEx:ki];
//	self.name = [app valueForKey:@"CFBundleIdentifier"];
//	self.bundleName = [app valueForKey:@"CFBundleName"];
//	self.displayName = [app valueForKey:@"CFBundleDisplayName"];
		}
	}
	return self;
}

+ (instancetype)psProcWithKinfo:(struct kinfo_proc *)ki iconSize:(CGFloat)size
{
	return [[[PSProc alloc] initWithKinfo:ki iconSize:size] autorelease];
}

- (void)updateWithKinfo:(struct kinfo_proc *)ki
{
	self.display = ProcDisplayUser;
	[self updateWithKinfoEx:ki];
}

#define PSPROC_STATE_MAX 8

// Thread states are sorted by priority, top priority becomes a "task state"
int mach_state_order(int s, long sleep_time)
{      
	switch (s) {
	case TH_STATE_RUNNING:			return 2;
	case TH_STATE_UNINTERRUPTIBLE:	return 3;
	case TH_STATE_WAITING:			return sleep_time <= 20 ? 4 : 5;
	case TH_STATE_STOPPED:			return 6;
	case TH_STATE_HALTED:			return 7;  
	default:						return PSPROC_STATE_MAX; 
	}
}

- (void)updateWithKinfoEx:(struct kinfo_proc *)ki
{
	time_value_t total_time = {0};
	task_port_t task;
	unsigned int info_count;
	self.priobase = ki->kp_proc.p_priority;
	self.flags = ki->kp_proc.p_flag;
	self.nice = ki->kp_proc.p_nice;
	self.tdev = ki->kp_eproc.e_tdev;
	self.uid = ki->kp_eproc.e_ucred.cr_uid;
	self.gid = ki->kp_eproc.e_pcred.p_rgid;
	memcpy(&events_prev, &events, sizeof(events_prev));
	// Task info
	self.threads = 0;
	self.prio = 0;
	self.pcpu = 0;
	self.state = PSPROC_STATE_MAX;
	// Priority process states
	if (ki->kp_proc.p_stat == SSTOP) self.state = 0;
	if (ki->kp_proc.p_stat == SZOMB) self.state = 1;
	if (task_for_pid(mach_task_self(), ki->kp_proc.p_pid, &task) == KERN_SUCCESS) {
		// Basic task info
		info_count = TASK_BASIC_INFO_COUNT;
		if (task_info(task, TASK_BASIC_INFO, (task_info_t)&basic, &info_count) == KERN_SUCCESS) {
			// Time
			total_time = basic.user_time;
			time_value_add(&total_time, &basic.system_time);
			// Task scheduler info
			struct policy_rr_base sched = {0};			// this struct is compatible with all task scheduling policies
			switch (basic.policy) {
			case POLICY_TIMESHARE:
				info_count = POLICY_TIMESHARE_INFO_COUNT;
				if (task_info(task, TASK_SCHED_TIMESHARE_INFO, (task_info_t)&sched, &info_count) == KERN_SUCCESS)
					self.priobase = sched.base_priority;
				break;
			case POLICY_RR:
				info_count = POLICY_RR_INFO_COUNT;
				if (task_info(task, TASK_SCHED_RR_INFO, (task_info_t)&sched, &info_count) == KERN_SUCCESS)
					self.priobase = sched.base_priority;
				break;
			case POLICY_FIFO:
				info_count = POLICY_FIFO_INFO_COUNT;
				if (task_info(task, TASK_SCHED_FIFO_INFO, (task_info_t)&sched, &info_count) == KERN_SUCCESS)
					self.priobase = sched.base_priority;
				break;
			}
		}
		// Task times
		struct task_thread_times_info times;
		info_count = TASK_THREAD_TIMES_INFO_COUNT;
		if (task_info(task, TASK_THREAD_TIMES_INFO, (task_info_t)&times, &info_count) != KERN_SUCCESS)
			memset(&times, 0, sizeof(times));
		time_value_add(&total_time, &times.user_time);
		time_value_add(&total_time, &times.system_time);
		// Task events
		info_count = TASK_EVENTS_INFO_COUNT;
		if (task_info(task, TASK_EVENTS_INFO, (task_info_t)&events, &info_count) != KERN_SUCCESS)
			memset(&events, 0, sizeof(events));
		else if (!events_prev.csw)	// Fill in events_prev on first update
			memcpy(&events_prev, &events, sizeof(events_prev));
		// Task ports
		mach_msg_type_number_t ncnt, tcnt;
		mach_port_name_array_t names;
		mach_port_type_array_t types;
		if (mach_port_names(task, &names, &ncnt, &types, &tcnt) == KERN_SUCCESS) {
			vm_deallocate(mach_task_self(), (vm_address_t)names, ncnt * sizeof(*names));
			vm_deallocate(mach_task_self(), (vm_address_t)types, tcnt * sizeof(*types));
			self.ports = ncnt;
		} else
			self.ports = 0;
		// Enumerate all threads to acquire detailed info
		unsigned int				thread_count;
		thread_port_array_t			thread_list;
		struct thread_basic_info	thval;
		if (task_threads(task, &thread_list, &thread_count) == KERN_SUCCESS) {
			self.threads = thread_count;
			for (unsigned int j = 0; j < thread_count; j++) {
				info_count = THREAD_BASIC_INFO_COUNT;
				if (thread_info(thread_list[j], THREAD_BASIC_INFO, (thread_info_t)&thval, &info_count) == KERN_SUCCESS) {
					self.pcpu += thval.cpu_usage;
					// Actual process priority will be the largest priority of a thread
					struct policy_timeshare_info sched;		// this struct is compatible with all scheduler policies
					switch (thval.policy) {
					case POLICY_TIMESHARE:
						info_count = POLICY_TIMESHARE_INFO_COUNT;
						if (thread_info(thread_list[j], THREAD_SCHED_TIMESHARE_INFO, (thread_info_t)&sched, &info_count) == KERN_SUCCESS)
							if (self.prio < sched.cur_priority) self.prio = sched.cur_priority;
						break;
					case POLICY_RR:
						info_count = POLICY_RR_INFO_COUNT;
						if (thread_info(thread_list[j], THREAD_SCHED_RR_INFO, (thread_info_t)&sched, &info_count) == KERN_SUCCESS)
							if (self.prio < sched.base_priority) self.prio = sched.base_priority;
						break;
					case POLICY_FIFO:
						info_count = POLICY_FIFO_INFO_COUNT;
						if (thread_info(thread_list[j], THREAD_SCHED_FIFO_INFO, (thread_info_t)&sched, &info_count) == KERN_SUCCESS)
							if (self.prio < sched.base_priority) self.prio = sched.base_priority;
						break;
					}
				}
				// Task state is formed from all thread states
				int thstate = mach_state_order(thval.run_state, thval.sleep_time);
				if (self.state > thstate)
					self.state = thstate;
				mach_port_deallocate(mach_task_self(), thread_list[j]);
			}
			// Deallocate the list of threads
			vm_deallocate(mach_task_self(), (vm_address_t)thread_list, sizeof(*thread_list) * thread_count);
		}
		mach_port_deallocate(mach_task_self(), task);
	}
	// Roundup time: 100's of a second
	self.ptime = total_time.seconds * 100 + (total_time.microseconds + 5000) / 10000;
}

+ (NSArray *)getArgsByKinfo:(struct kinfo_proc *)ki
{
	NSArray		*args = nil;
	int			nargs, c = 0;
	static int	argmax = 0;
	char		*argsbuf, *sp, *cp;
	int			mib[3] = {CTL_KERN, KERN_PROCARGS2, ki->kp_proc.p_pid};
	size_t		size;

	if (!argmax) {
		int mib2[2] = {CTL_KERN, KERN_ARGMAX};
		size = sizeof(argmax);
		if (sysctl(mib2, 2, &argmax, &size, NULL, 0) < 0)
			argmax = 1024;
	}
	// Allocate process environment buffer
	argsbuf = (char *)malloc(argmax);
	if (argsbuf) {
		size = (size_t)argmax;
		if (sysctl(mib, 3, argsbuf, &size, NULL, 0) == 0) {
			// Skip args count
			nargs = *(int *)argsbuf;
			cp = argsbuf + sizeof(nargs);
			// Skip exec_path and trailing nulls
			for (; cp < &argsbuf[size]; cp++)
				if (!*cp) break;
			for (; cp < &argsbuf[size]; cp++)
				if (*cp) break;
			for (sp = cp; cp < &argsbuf[size] && c < nargs; cp++)
				if (*cp == '\0') c++;
			while (sp < cp && sp[0] == '/' && sp[1] == '/') sp++;
			if (sp != cp) {
				args = [[[[NSString alloc] initWithBytes:sp length:(cp-sp)
					encoding:NSUTF8StringEncoding] autorelease]		// NSASCIIStringEncoding?
					componentsSeparatedByString:@"\0"];
			}
		}
		free(argsbuf);
	}
	if (args)
		return args;
	ki->kp_proc.p_comm[MAXCOMLEN] = 0;	// Just in case
	return [NSArray arrayWithObject:[NSString stringWithFormat:@"(%s)", ki->kp_proc.p_comm]];
}

- (void)dealloc
{
	[_name release];
	[_args release];
	[_icon release];
	[_app release];
	[super dealloc];
}

@end

@implementation PSProcArray

- (instancetype)initProcArrayWithIconSize:(CGFloat)size
{
	if (self = [super init]) {
		self.procs = [NSMutableArray arrayWithCapacity:200];
		self.iconSize = size;
	}
	return self;
}

+ (instancetype)psProcArrayWithIconSize:(CGFloat)size
{
	return [[[PSProcArray alloc] initProcArrayWithIconSize:size] autorelease];
}

- (int)refresh
{
	struct kinfo_proc *kp;
	int nentries;
	size_t bufSize;
	int i, err;
	int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};

	// Remove terminated processes
	[self.procs filterUsingPredicate:[NSPredicate predicateWithBlock: ^BOOL(PSProc *obj, NSDictionary *bind) {
		return obj.display != ProcDisplayTerminated;
	}]];
	[self setAllDisplayed:ProcDisplayTerminated];
	// Get buffer size
	if (sysctl(mib, 4, NULL, &bufSize, NULL, 0) < 0)
		return errno;
	kp = (struct kinfo_proc *)malloc(bufSize);
	// Get process list and update the procs array
	err = sysctl(mib, 4, kp, &bufSize, NULL, 0);
	if (!err) {
		nentries = bufSize / sizeof(struct kinfo_proc);
		for (i = 0; i < nentries; i++) {
			NSUInteger idx = [self.procs indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
				return ((PSProc *)obj).pid == kp[i].kp_proc.p_pid;
			}];
			if (idx == NSNotFound)
				[self.procs addObject:[PSProc psProcWithKinfo:&kp[i] iconSize:self.iconSize]];
			else
				[self.procs[idx] updateWithKinfo:&kp[i]];
		}
	}
	free(kp);
	return err;
}

- (void)sortWithComparator:(NSComparator)comp
{
	[self.procs sortUsingComparator:comp];
}

- (void)setAllDisplayed:(display_t)display
{
	for (PSProc *proc in self.procs)
		proc.display = display;
}

- (NSUInteger)indexOfDisplayed:(display_t)display
{
	return [self.procs indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
		return ((PSProc *)obj).display == display;
	}];
}

- (NSUInteger)count
{
	return self.procs.count;
}

- (PSProc *)procAtIndex:(NSUInteger)index
{
	return (PSProc *)self.procs[index];
}

- (void)dealloc
{
	[_procs release];
	[super dealloc];
}

@end
