# realtime sensitive scheduling - thread 2 thread latency

- thread 2 thread latency: time from thread A says do task and thread B executing the task
- for realtime scheduling OS thread priority must be used correctly (../thread/thread_prio.zig), otherwise the critical threads can be impeded by other threads running on the system
- normally a program needs to (asynchronously and_or parallely) execute tasks of which some tasks need to start almost immediately (realtime tasks) and finish in bounded time, other tasks are more relaxed
- the best mechanism for dispatching tasks in a multithreaded scenario is almost always some sort of Queue (SPSC, MPMC, etc.)

# task timing and low worst case latency

- when talking about task based scheduling there is a lower limit one can reach on a gpOS with regards to latency and it is dependent on the task itself
- low latency tasks need to be themself bounded in time aka short lifed. otherwise worst case latency explodes

# scheduling methods and Latency class

## Class 0 - a few microseconds

- this class is the limit for modern computer systems
- (hardware, driver approach, interupt) external hardware issues an interupt, this triggers high priority thread execution
- (software, polling) using N threads constantly spin-waiting for new tasks (this drains the system battery and cpu!!)
- unfortunately thread waking (way more efficient) using the OS can have bad worse case latency and is unsuitable for Class 0 (except when running on a rt-optimized system, but even there it has overhead for the thread which is pushing tasks)
- number of highest priority threads must be less than physical core count, otherwise they impede each other or impede lower priority threads (also OS dependent), but in a ideal system 100% low latency task saturation must never be reached because it would clog up the system. headroom in a rt system is a necessary thing
- on gpOS you want to avoid this scenario since its hard to achieve and extremely taxing for the system

## class 1 - a few milliseconds

- this class is easier to achieve for modern computer systems
- for reliability one should use high priority threads
- (software, polling) using N threads waiting for new tasks and short sleep intervals (this drains the system battery and cpu!!), this is compatible with class 0
- (software, notify) using N threads that sleep if no work is available and are woken up using OS primitives, careful! this is not compatible with class 0, which means everything in class 0 may not issue tasks using this mechanism
- latency parameters: sleep interval, OS timer accuracy, OS scheduling accuracy (this will be better on RT optimized OS)
- on gpOS you want to use a hybrid approach of the 2 methods

## class 2 - 100 milliseconds

- this class is easy to achieve for modern computer systems
- use low / normal priority threads
- use notify mechanism (this is compatible with class 1)

## class 3 - general purpose task

- this class is easy to achieve for modern computer systems
- use normal threads, maybe a thread pool
- use notify mechanism (this is compatible with class 1)
