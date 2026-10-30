// Copyright 2026 Wouter van Oortmerssen. All rights reserved.
// Licensed under the Apache License, Version 2.0 (see LICENSE.txt).

// Tasks: cheap cooperative threads, in the spirit of Java's virtual threads. Each task runs on a
// native stack of its own inside a single VM, and a call that would block (task.sleep,
// task.join, tcp.wait) parks it and runs another one instead, so code reads as if it blocks.
// There is no function coloring: any function may park, however deep in the call chain.
//
// The compiler's borrow check knows that these calls park (NativeFun::parks), and treats them as
// writes to everything another task can reach: a global, or a field or element of an object.
// A variable initialized from such a location then keeps a reference of its own, flow typing of
// it (a nil check) is undone, and where neither can be done, as when iterating over a global
// vector, parking inside the loop is an error that says so. A variable of the function itself
// is not affected, since a task only has copies of those. Calls thru a declared function type
// are not known to park, as they are not known to write either.
//
// All tasks of a VM share its thread, and never run in parallel, so they need no locking.
// The scheduler is owned by the VM, and each worker thread's VM has its own.

#ifndef LOBSTER_TASKS_H
#define LOBSTER_TASKS_H

// The switch needs ucontext, which Windows (fibers would do) and Wasm do not have. Define
// LOBSTER_NO_TASKS to build without, where task.spawn is then a runtime error.
#if (defined(__unix__) || defined(__APPLE__)) && !defined(__EMSCRIPTEN__) && !defined(LOBSTER_NO_TASKS)
    #define LOBSTER_TASKS 1
#else
    #define LOBSTER_TASKS 0
#endif

namespace lobster {

struct VM;
struct Scheduler;

void DeleteScheduler(Scheduler *s);

// Called when a VM error is about to unwind the stack. An error in a task has to be raised on
// the stack the VM started on, since that is where whatever catches it lives. This switches
// there, and does not return, if the error is in a task. Otherwise it does nothing.
void TaskForwardError(VM &vm);

// For tcp.wait: if tasks exist, park the current one until one of the (possibly -1) descriptors
// is ready or the time is up, returning true and the same answer tcp.wait would give in `ready`.
// Returns false when there are no tasks, in which case the caller should simply block.
bool TaskWaitIO(VM &vm, int read1, int read2, int write1, double seconds, bool &ready);

}  // namespace lobster

#endif  // LOBSTER_TASKS_H
