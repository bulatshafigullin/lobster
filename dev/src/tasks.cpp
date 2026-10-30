// Copyright 2026 Wouter van Oortmerssen. All rights reserved.
// Licensed under the Apache License, Version 2.0 (see LICENSE.txt).

// Tasks, see tasks.h for what they are.
//
// A task is a native stack and a saved stack pointer to switch to it. The generated code keeps its
// locals on the native stack, so unlike what the old interpreter's coroutines had to do, a switch
// copies no stack and touches no reference counts: the stack stays where it is, and is simply
// left and re-entered.
//
// What does live in the VM, and so has to be swapped on a switch, is whatever is per call chain:
// the line, the function id stack for stack traces, the free variable backups, and the free
// variables that are really locals of a function in the chain (not globals, which stay shared).

#include "lobster/stdafx.h"
#include "lobster/natreg.h"
#include "lobster/tasks.h"

#if LOBSTER_TASKS
    #if !defined(__aarch64__) && !defined(__x86_64__)
        #include <ucontext.h>  // Only for the architectures without a switch of our own below.
    #endif
    #include <sys/mman.h>
    #include <poll.h>
    #include <unistd.h>
    #include <chrono>
    #include <deque>
    #include <map>
    #include <unordered_map>
    // Waiting for descriptors costs a time per wait that grows with how many tasks wait with
    // poll, with a kernel queue (kqueue, epoll) only with the ones that become ready. poll is
    // the fallback, and what LOBSTER_TASKS_NO_EVENTQ asks for.
    #if (defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)) && \
        !defined(LOBSTER_TASKS_NO_EVENTQ)
        #define TASKS_KQUEUE 1
        #define TASKS_EPOLL 0
        #include <sys/event.h>
        #include <fcntl.h>
    #elif defined(__linux__) && !defined(LOBSTER_TASKS_NO_EVENTQ)
        #define TASKS_KQUEUE 0
        #define TASKS_EPOLL 1
        #include <sys/epoll.h>
        #include <fcntl.h>
        #include <unordered_set>
    #else
        #define TASKS_KQUEUE 0
        #define TASKS_EPOLL 0
    #endif
    #define TASKS_EVQ (TASKS_KQUEUE || TASKS_EPOLL)
#endif

namespace lobster {

#if LOBSTER_TASKS

// Switching stacks. The registers a call preserves are all that has to be kept, and a few
// instructions do that. The library routines (makecontext & co) would do as well, but on macOS
// makecontext writes all of the new stack, so that every task would cost all of it from the
// start, and swapcontext makes a system call on each switch to save the signal mask.
#if defined(__aarch64__) || defined(__x86_64__)
    #define TASKS_ASM_SWITCH 1
    #if defined(__APPLE__)
        #define TASKS_SYM(x) "_" x
    #else
        #define TASKS_SYM(x) x
    #endif
    extern "C" void lobster_task_switch(void **save_sp, void *load_sp);
    #if defined(__aarch64__)
    // x19-x30 and d8-d15 are what the calling convention has the callee keep. The new stack
    // starts with a frame as if switched out from the entry function, see Ctx::Init.
    __asm__(
        ".text\n"
        ".globl " TASKS_SYM("lobster_task_switch") "\n"
        ".p2align 2\n"
        TASKS_SYM("lobster_task_switch") ":\n"
        "    sub sp, sp, #160\n"
        "    stp x19, x20, [sp, #0]\n"
        "    stp x21, x22, [sp, #16]\n"
        "    stp x23, x24, [sp, #32]\n"
        "    stp x25, x26, [sp, #48]\n"
        "    stp x27, x28, [sp, #64]\n"
        "    stp x29, x30, [sp, #80]\n"
        "    stp d8, d9, [sp, #96]\n"
        "    stp d10, d11, [sp, #112]\n"
        "    stp d12, d13, [sp, #128]\n"
        "    stp d14, d15, [sp, #144]\n"
        "    mov x2, sp\n"
        "    str x2, [x0]\n"
        "    mov sp, x1\n"
        "    ldp x19, x20, [sp, #0]\n"
        "    ldp x21, x22, [sp, #16]\n"
        "    ldp x23, x24, [sp, #32]\n"
        "    ldp x25, x26, [sp, #48]\n"
        "    ldp x27, x28, [sp, #64]\n"
        "    ldp x29, x30, [sp, #80]\n"
        "    ldp d8, d9, [sp, #96]\n"
        "    ldp d10, d11, [sp, #112]\n"
        "    ldp d12, d13, [sp, #128]\n"
        "    ldp d14, d15, [sp, #144]\n"
        "    add sp, sp, #160\n"
        "    ret\n"
    );
    #else
    // rbx, rbp and r12-r15, with the return address on top for ret to take.
    __asm__(
        ".text\n"
        ".globl " TASKS_SYM("lobster_task_switch") "\n"
        TASKS_SYM("lobster_task_switch") ":\n"
        "    pushq %rbp\n"
        "    pushq %rbx\n"
        "    pushq %r12\n"
        "    pushq %r13\n"
        "    pushq %r14\n"
        "    pushq %r15\n"
        "    movq %rsp, (%rdi)\n"
        "    movq %rsi, %rsp\n"
        "    popq %r15\n"
        "    popq %r14\n"
        "    popq %r13\n"
        "    popq %r12\n"
        "    popq %rbx\n"
        "    popq %rbp\n"
        "    ret\n"
    );
    #endif

    struct Ctx {
        void *sp = nullptr;  // Where the registers were saved on the stack, while switched out.

        // Make this the context of a stack that starts out running entry, which never returns.
        void Init(char *stack, size_t size, void (*entry)()) {
            auto top = (uintptr_t)(stack + size) & ~(uintptr_t)15;
            auto frame = (void **)top;
            #if defined(__aarch64__)
                frame -= 20;  // 160 bytes
                for (int i = 0; i < 20; i++) frame[i] = nullptr;
                frame[11] = (void *)entry;  // x30, where ret goes.
            #else
                *--frame = nullptr;  // The return address entry would have, and the alignment.
                *--frame = (void *)entry;
                for (int i = 0; i < 6; i++) *--frame = nullptr;
            #endif
            sp = frame;
        }
        void Switch(Ctx &to) { lobster_task_switch(&sp, to.sp); }
    };
#else  // Any other architecture: the library routines.
    #define TASKS_ASM_SWITCH 0
    struct Ctx {
        ucontext_t uc;
        void Init(char *stack, size_t size, void (*entry)()) {
            getcontext(&uc);
            uc.uc_stack.ss_sp = stack;
            uc.uc_stack.ss_size = size;
            uc.uc_link = nullptr;
            makecontext(&uc, entry, 0);
        }
        void Switch(Ctx &to) { swapcontext(&uc, &to.uc); }
    };
#endif

#endif  // LOBSTER_TASKS

static ResourceType task_type = { "task" };

// Just names a task, which is on its own once spawned: dropping this does not stop it.
struct TaskHandle : Resource {
    uint64_t id;
    explicit TaskHandle(uint64_t _id) : id(_id) {}
};

#if LOBSTER_TASKS

typedef std::chrono::steady_clock task_clock;

// Virtual memory only, pages are committed as the task touches them.
static const size_t task_stack_size = 1 << 20;
// Stacks of finished tasks kept to reuse, which keep the pages they touched. Mapping and
// unmapping one costs far more than the rest of a spawn, so this is meant to cover a burst.
static const size_t max_pooled_stacks = 2048;

enum class TaskState { READY, RUNNING, WAITING, DONE };

struct Task {
    uint64_t id = 0;
    TaskState state = TaskState::READY;
    fun_base_t fn = nullptr;
    Ctx ctx;
    char *stack = nullptr;  // The whole mapping, guard page first.

    // The VM state of this task while another one is running.
    Line last{ -1, -1 };
    int ret_unwind_to = -1;
    vector<VM::FunStack> fun_ids;
    vector<Value> fvar_backup;
    vector<Value> freevars;  // Scheduler::fv_idx, in that order.

    // While waiting for time or descriptors: read, read, write.
    int fds[3] = { -1, -1, -1 };
    bool timed = false;
    task_clock::time_point deadline;
    bool io_ready = false;
    #if TASKS_EVQ
        vector<int64_t> regs;  // Scheduler::WaitKey of each descriptor wait it is in.
        std::multimap<task_clock::time_point, Task *>::iterator timer;
    #endif

    vector<Task *> joiners;
};

static thread_local Scheduler *tl_sched = nullptr;

static void TaskEntry();

struct Scheduler {
    VM &vm;
    Task root;  // Stands for the stack the VM started on, which has no mapping of our own.
    Task *current = &root;
    uint64_t next_id = 1;

    std::deque<Task *> ready;
    #if TASKS_EVQ
        int kq = -1;  // The kqueue or epoll descriptor.
        #if TASKS_KQUEUE
            vector<struct kevent> kchanges;  // Registrations to make with the next kevent call.
        #else
            std::unordered_set<int> epoll_known;  // Descriptors epoll_ctl has been given.
        #endif
        std::unordered_map<int64_t, vector<Task *>> fd_waiters;
        std::multimap<task_clock::time_point, Task *> timers;
    #else
        vector<Task *> waiting;  // Parked on a timer and/or descriptors.
    #endif
    vector<Task *> all_waiters;  // Parked in wait_all.
    std::map<uint64_t, unique_ptr<Task>> tasks;  // Every task that hasn't finished.
    vector<unique_ptr<Task>> zombies;  // Finished, but can't free the stack they may be on yet.
    vector<char *> stack_pool;
    bool pending_error = false;

    // The free variable slots that belong to a call chain, and what is in each, to refcount.
    bool layout_ready = false;
    vector<int> fv_idx;
    vector<RTType> fv_type;

    explicit Scheduler(VM &_vm) : vm(_vm) { root.state = TaskState::RUNNING; }

    ~Scheduler() {
        for (auto &t : tasks) if (t.second->stack) munmap(t.second->stack, StackLen());
        for (auto &z : zombies) if (z->stack) munmap(z->stack, StackLen());
        for (auto s : stack_pool) munmap(s, StackLen());
        #if TASKS_EVQ
            if (kq >= 0) close(kq);
        #endif
    }

    static size_t GuardLen() { return (size_t)sysconf(_SC_PAGESIZE); }
    static size_t StackLen() { return GuardLen() + task_stack_size; }

    char *AllocStack() {
        if (!stack_pool.empty()) {
            auto s = stack_pool.back();
            stack_pool.pop_back();
            return s;
        }
        auto p = mmap(nullptr, StackLen(), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) return nullptr;
        // Stacks grow down, so running off the end hits this instead of someone else's memory.
        if (mprotect(p, GuardLen(), PROT_NONE)) {
            munmap(p, StackLen());
            return nullptr;
        }
        return (char *)p;
    }

    void FreeStack(char *s) {
        if (stack_pool.size() < max_pooled_stacks) stack_pool.push_back(s);
        else munmap(s, StackLen());
    }

    void EnsureLayout() {
        if (layout_ready) return;
        layout_ready = true;
        auto &ids = vm.vma.meta->specidents;
        size_t i = 0;
        while (i < ids.size()) {
            // A struct takes a slot per field, each with an entry of its own, see CodeGen::Codegen.
            auto &ti = vm.GetVarTypeInfo((int)i);
            auto is_struct = RTIsStruct(ti.t);
            size_t width = is_struct ? (size_t)max<iint>(ti.len, 1) : 1;
            for (size_t j = 0; j < width && i + j < ids.size(); j++) {
                auto &sid = ids[i + j];
                // Globals are shared by all tasks, as they should be.
                if (!sid.used_as_freevar || sid.global) continue;
                fv_idx.push_back((int)(i + j));
                fv_type.push_back(is_struct ? LObject::ElemTypeSOf(vm, ti, (iint)j).t : ti.t);
            }
            i += width;
        }
        root.freevars.assign(fv_idx.size(), Value(0));
    }

    void Save(Task &t) {
        t.last = vm.last;
        t.ret_unwind_to = vm.ret_unwind_to;
        t.fun_ids = std::move(vm.fun_id_stack);
        vm.fun_id_stack.clear();
        t.fvar_backup = std::move(vm.fvar_def_backup);
        vm.fvar_def_backup.clear();
        for (size_t k = 0; k < fv_idx.size(); k++) t.freevars[k] = vm.fvars_ptr[fv_idx[k]];
    }

    void Restore(Task &t) {
        vm.last = t.last;
        vm.ret_unwind_to = t.ret_unwind_to;
        vm.fun_id_stack = std::move(t.fun_ids);
        t.fun_ids.clear();
        vm.fvar_def_backup = std::move(t.fvar_backup);
        t.fvar_backup.clear();
        for (size_t k = 0; k < fv_idx.size(); k++) vm.fvars_ptr[fv_idx[k]] = t.freevars[k];
    }

    void ReapZombies() {
        for (auto &z : zombies) FreeStack(z->stack);
        zombies.clear();
    }

    void SwitchTo(Task *next) {
        auto prev = current;
        if (next == prev) {
            prev->state = TaskState::RUNNING;
            return;
        }
        Save(*prev);
        Restore(*next);
        current = next;
        next->state = TaskState::RUNNING;
        tl_sched = this;
        prev->ctx.Switch(next->ctx);
        // Back on prev's stack, whoever switched here already restored its VM state.
        ReapZombies();
        if (pending_error && current == &root) {
            pending_error = false;
            vm.UnwindOnError();
        }
    }

    [[noreturn]] void ForwardErrorToRoot() {
        pending_error = true;
        SwitchTo(&root);
        abort();  // Nothing switches back to a task that has failed.
    }

    void MakeReady(Task *t) {
        t->state = TaskState::READY;
        ready.push_back(t);
    }

    // What waiting on time and descriptors has to provide, one way or the other:
    //   AddWaiter(t)    t has set its fds and deadline, and is to be woken for them.
    //   PollWaiters(b)  move to ready the tasks whose time or descriptors came, waiting for them
    //                   if b, which only is when nothing else can run.
    //   NothingWaits()  no task is waiting for either.
    #if TASKS_EVQ

    static int64_t WaitKey(int fd, bool write) { return (int64_t)fd * 2 + (write ? 1 : 0); }

    bool NothingWaits() const { return timers.empty() && fd_waiters.empty(); }

    #if TASKS_KQUEUE
    void QueueChange(int64_t key, uint16_t flags) {
        struct kevent ev;
        EV_SET(&ev, (uintptr_t)(key >> 1), (key & 1) ? EVFILT_WRITE : EVFILT_READ, flags, 0, 0, nullptr);
        kchanges.push_back(ev);
    }
    #else
    // epoll has one registration per descriptor, for reading and writing together. It is armed
    // for one event only (EPOLLONESHOT), which is what is waited for here: nothing has to be
    // taken back when a task stops waiting, and a descriptor that was closed and had its number
    // reused can't leave a stale registration behind that misses events.
    void Arm(int fd) {
        epoll_event ev{};
        ev.data.fd = fd;
        ev.events = EPOLLONESHOT;
        if (fd_waiters.count(WaitKey(fd, false))) ev.events |= EPOLLIN;
        if (fd_waiters.count(WaitKey(fd, true))) ev.events |= EPOLLOUT;
        if (ev.events == EPOLLONESHOT) return;
        bool known = epoll_known.count(fd) > 0;
        if (known && epoll_ctl(kq, EPOLL_CTL_MOD, fd, &ev) == 0) return;
        if (epoll_ctl(kq, EPOLL_CTL_ADD, fd, &ev) == 0) {
            epoll_known.insert(fd);
        } else if (errno == EEXIST) {
            epoll_ctl(kq, EPOLL_CTL_MOD, fd, &ev);
        } else {
            // Not something epoll can watch (a regular file, say) or no longer a descriptor.
            // The call a woken task tries next is the one to report it, or to just work.
            epoll_known.erase(fd);
            epoll_failed.push_back(fd);
        }
    }
    vector<int> epoll_failed;  // Descriptors to wake the waiters of at the next poll.
    #endif

    void AddWaiter(Task *t) {
        t->regs.clear();
        for (int k = 0; k < 3; k++) {
            if (t->fds[k] < 0) continue;
            auto key = WaitKey(t->fds[k], k == 2);
            if (find(t->regs.begin(), t->regs.end(), key) != t->regs.end()) continue;
            auto &w = fd_waiters[key];
            // Registered while anyone waits, so several tasks may wait on the same descriptor.
            #if TASKS_KQUEUE
                if (w.empty()) QueueChange(key, EV_ADD);
            #else
                bool first = w.empty();
            #endif
            w.push_back(t);
            t->regs.push_back(key);
            #if TASKS_EPOLL
                if (first) Arm(t->fds[k]);
            #endif
        }
        if (t->timed) t->timer = timers.emplace(t->deadline, t);
    }

    // Takes t out of everything it waits for, which is more than what woke it.
    void StopWaiting(Task *t) {
        for (auto key : t->regs) {
            auto it = fd_waiters.find(key);
            if (it == fd_waiters.end()) continue;
            auto &w = it->second;
            w.erase(find(w.begin(), w.end(), t));
            if (w.empty()) {
                #if TASKS_KQUEUE
                    QueueChange(key, EV_DELETE);
                #endif
                fd_waiters.erase(it);
            }
        }
        t->regs.clear();
        if (t->timed) timers.erase(t->timer);
    }

    #if TASKS_KQUEUE
    void PollWaiters(bool block) {
        if (kq < 0) {
            kq = kqueue();
            if (kq < 0 || fcntl(kq, F_SETFD, FD_CLOEXEC) < 0) vm.BuiltinError("task: kqueue failed");
        }
        timespec ts{ 0, 0 };
        timespec *timeout = &ts;
        if (block) {
            if (timers.empty()) {
                timeout = nullptr;
            } else {
                auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                              timers.begin()->first - task_clock::now()).count();
                ns = max<long long>(ns, 0);
                ts.tv_sec = (time_t)(ns / 1000000000);
                ts.tv_nsec = (long)(ns % 1000000000);
            }
        }
        struct kevent events[64];
        int n = kevent(kq, kchanges.data(), (int)kchanges.size(), events, 64, timeout);
        if (n >= 0) {
            kchanges.clear();
        } else if (errno != EINTR) {
            // Something in the changes was refused and there was no room to say what. Wake all
            // descriptor waiters, the call each tries next is the one to report it.
            kchanges.clear();
            vector<Task *> all;
            for (auto &w : fd_waiters) all.insert(all.end(), w.second.begin(), w.second.end());
            for (auto t : all) Wake(t, true);
            n = 0;
        } else {
            n = 0;  // Changes stay queued, and are made again by the next call.
        }
        for (int i = 0; i < n; i++) {
            auto &ev = events[i];
            // Taking back a registration that is already gone is not worth waking anyone for.
            if ((ev.flags & EV_ERROR) && ev.data == ENOENT) continue;
            auto it = fd_waiters.find(WaitKey((int)ev.ident, ev.filter == EVFILT_WRITE));
            if (it == fd_waiters.end()) continue;
            auto woken = it->second;  // Wake changes it.
            // An error counts as ready too: the call that is tried next reports it.
            for (auto t : woken) Wake(t, true);
        }
        auto now = task_clock::now();
        while (!timers.empty() && timers.begin()->first <= now) Wake(timers.begin()->second, false);
    }

    #else  // TASKS_EPOLL

    void WakeKey(int fd, bool write) {
        auto it = fd_waiters.find(WaitKey(fd, write));
        if (it == fd_waiters.end()) return;
        auto woken = it->second;  // Wake changes it.
        for (auto t : woken) Wake(t, true);
    }

    void PollWaiters(bool block) {
        if (kq < 0) {
            kq = epoll_create1(EPOLL_CLOEXEC);
            if (kq < 0) vm.BuiltinError("task: epoll_create1 failed");
        }
        int timeout_ms = 0;
        if (block && epoll_failed.empty()) {
            if (timers.empty()) {
                timeout_ms = -1;
            } else {
                auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                              timers.begin()->first - task_clock::now()).count();
                timeout_ms = (int)min<long long>(max<long long>((ns + 999999) / 1000000, 0), 1 << 30);
            }
        }
        epoll_event events[64];
        int n = epoll_wait(kq, events, 64, timeout_ms);  // EINTR just means try again.
        for (int i = 0; i < max(n, 0); i++) {
            int fd = events[i].data.fd;
            auto e = events[i].events;
            // An error counts as ready too: the call that is tried next reports it.
            bool err = (e & (EPOLLERR | EPOLLHUP)) != 0;
            if (e & EPOLLIN || err) WakeKey(fd, false);
            if (e & EPOLLOUT || err) WakeKey(fd, true);
            // Armed for one event, so whoever is still waiting for the other kind needs it again.
            if (fd_waiters.count(WaitKey(fd, false)) || fd_waiters.count(WaitKey(fd, true))) Arm(fd);
        }
        auto failed = std::move(epoll_failed);
        epoll_failed.clear();
        for (auto fd : failed) {
            WakeKey(fd, false);
            WakeKey(fd, true);
        }
        auto now = task_clock::now();
        while (!timers.empty() && timers.begin()->first <= now) Wake(timers.begin()->second, false);
    }
    #endif

    void Wake(Task *t, bool io) {
        StopWaiting(t);
        t->io_ready = io;
        MakeReady(t);
    }

    #else  // !TASKS_EVQ

    bool NothingWaits() const { return waiting.empty(); }

    void AddWaiter(Task *t) { waiting.push_back(t); }

    // Kept between polls so that polling allocates nothing.
    vector<pollfd> poll_fds;
    vector<size_t> poll_first;
    vector<Task *> poll_still;

    void PollWaiters(bool block) {
        auto &pfds = poll_fds;
        auto &first = poll_first;
        pfds.clear();
        first.clear();
        auto now = task_clock::now();
        int timeout_ms = block ? -1 : 0;
        for (auto t : waiting) {
            first.push_back(pfds.size());
            for (int k = 0; k < 3; k++)
                if (t->fds[k] >= 0) pfds.push_back({ t->fds[k], (short)(k < 2 ? POLLIN : POLLOUT), 0 });
            if (block && t->timed) {
                auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(t->deadline - now).count();
                auto ms = (int)min<long long>(max<long long>((ns + 999999) / 1000000, 0), 1 << 30);
                timeout_ms = timeout_ms < 0 ? ms : min(timeout_ms, ms);
            }
        }
        first.push_back(pfds.size());
        int n = poll(pfds.data(), (nfds_t)pfds.size(), timeout_ms);  // EINTR just means try again.
        now = task_clock::now();
        auto &still = poll_still;
        still.clear();
        for (size_t i = 0; i < waiting.size(); i++) {
            auto t = waiting[i];
            bool io = false;
            // An error or a closed descriptor counts, the call tried next is the one to report it.
            if (n > 0) for (auto j = first[i]; j < first[i + 1]; j++) io |= pfds[j].revents != 0;
            if (io || (t->timed && now >= t->deadline)) {
                t->io_ready = io;
                MakeReady(t);
            } else {
                still.push_back(t);
            }
        }
        waiting.swap(still);
    }

    #endif  // TASKS_EVQ

    // With tasks ready to run, waiters are only looked at every so often: a poll per switch is a
    // system call each, and would then cost more than the switch. Waiting for the ready ones to
    // run first delays an event by at most this many switches.
    int switches_since_poll = 0;
    static constexpr int polls_every = 32;

    // Null if nothing can ever run again.
    Task *PickNext() {
        for (;;) {
            if (!NothingWaits() && (ready.empty() || ++switches_since_poll >= polls_every)) {
                switches_since_poll = 0;
                PollWaiters(ready.empty());
            }
            if (!ready.empty()) {
                auto t = ready.front();
                ready.pop_front();
                return t;
            }
            if (NothingWaits()) return nullptr;
        }
    }

    // The current task has already put itself wherever it is to be woken from.
    void Park() {
        auto next = PickNext();
        if (!next)
            vm.BuiltinError("task: deadlock, every task is waiting for another that can't finish");
        SwitchTo(next);
    }

    uint64_t Spawn(fun_base_t f) {
        EnsureLayout();
        auto t = make_unique<Task>();
        t->stack = AllocStack();
        if (!t->stack) vm.BuiltinError("task.spawn: out of memory for a stack");
        t->id = next_id++;
        t->fn = f;
        t->last = vm.last;
        // A task starts out seeing what its spawner can see, since the function it runs may use
        // variables of the function that spawned it, and will outlive that call. Taking them by
        // value is what makes this safe, the spawner moves on and may change or free them.
        t->freevars.reserve(fv_idx.size());
        for (size_t k = 0; k < fv_idx.size(); k++) {
            auto v = vm.fvars_ptr[fv_idx[k]];
            if (RTIsRefNil(fv_type[k])) v.LTINCRTNIL();
            t->freevars.push_back(v);
        }
        t->ctx.Init(t->stack + GuardLen(), task_stack_size, TaskEntry);
        auto id = t->id;
        ready.push_back(t.get());
        tasks[id] = std::move(t);
        return id;
    }

    // The first thing a task does, on its own stack.
    [[noreturn]] void Run() {
        ReapZombies();
        auto t = current;
        try {
            vm.CallFunctionValue(t->fn);
        } catch (...) {
            // VM errors are forwarded before they are thrown, so this is some other exception,
            // which would otherwise have nowhere to go.
            if (vm.errmsg.empty()) vm.errmsg = "task: unexpected C++ exception";
            ForwardErrorToRoot();
        }
        Finish(t);
    }

    [[noreturn]] void Finish(Task *t) {
        t->state = TaskState::DONE;
        // Back to what was spawned with, see Spawn, which we own a count of.
        for (size_t k = 0; k < fv_idx.size(); k++)
            if (RTIsRefNil(fv_type[k])) vm.fvars_ptr[fv_idx[k]].LTDECRTNIL(vm);
        for (auto j : t->joiners) MakeReady(j);
        t->joiners.clear();
        auto it = tasks.find(t->id);
        zombies.push_back(std::move(it->second));
        tasks.erase(it);
        WakeAllWaiters();
        auto next = PickNext();
        if (!next)
            vm.BuiltinError("task: deadlock, every task is waiting for another that can't finish");
        SwitchTo(next);
        abort();  // A finished task is never switched to.
    }

    size_t LiveTasks() const {
        size_t n = tasks.size();
        for (auto w : all_waiters) if (w != &root) n--;
        return n;
    }

    void WakeAllWaiters() {
        if (all_waiters.empty() || LiveTasks()) return;
        for (auto w : all_waiters) MakeReady(w);
        all_waiters.clear();
    }

    void Yield() {
        if (ready.empty() && NothingWaits()) return;
        MakeReady(current);
        Park();
    }

    bool WaitIO(int read1, int read2, int write1, double seconds) {
        auto t = current;
        t->fds[0] = read1;
        t->fds[1] = read2;
        t->fds[2] = write1;
        t->timed = true;
        t->deadline = task_clock::now() + std::chrono::duration_cast<task_clock::duration>(
                                              std::chrono::duration<double>(seconds));
        t->io_ready = false;
        t->state = TaskState::WAITING;
        AddWaiter(t);
        Park();
        t->fds[0] = t->fds[1] = t->fds[2] = -1;
        return t->io_ready;
    }

    void Join(uint64_t id) {
        auto it = tasks.find(id);
        if (it == tasks.end()) return;  // Already finished.
        auto target = it->second.get();
        if (target == current) vm.BuiltinError("task.join: a task can't wait for itself");
        target->joiners.push_back(current);
        current->state = TaskState::WAITING;
        Park();
    }

    void WaitAll() {
        if (!LiveTasks()) return;
        all_waiters.push_back(current);
        current->state = TaskState::WAITING;
        Park();
    }
};

static void TaskEntry() {
    tl_sched->Run();
}

void DeleteScheduler(Scheduler *s) {
    delete s;
}

void TaskForwardError(VM &vm) {
    auto s = vm.sched;
    if (s && s->current != &s->root) s->ForwardErrorToRoot();
}

bool TaskWaitIO(VM &vm, int read1, int read2, int write1, double seconds, bool &ready) {
    auto s = vm.sched;
    if (!s || !s->LiveTasks()) return false;
    ready = s->WaitIO(read1, read2, write1, seconds);
    return true;
}

static Scheduler &SchedulerFor(VM &vm) {
    if (!vm.sched) vm.sched = new Scheduler(vm);
    return *vm.sched;
}

static uint64_t SpawnTask(VM &vm, fun_base_t f) { return SchedulerFor(vm).Spawn(f); }
static void YieldTask(VM &vm) { if (vm.sched) vm.sched->Yield(); }
static void SleepTask(VM &vm, double seconds) {
    // Also what a NaN gets, and a huge time is cut to something the clock can add to now.
    if (!(seconds > 0)) return YieldTask(vm);
    SchedulerFor(vm).WaitIO(-1, -1, -1, min(seconds, 1e7));
}
static void JoinTask(VM &vm, uint64_t id) { if (vm.sched) vm.sched->Join(id); }
static void WaitAllTasks(VM &vm) { if (vm.sched) vm.sched->WaitAll(); }
static iint CountTasks(VM &vm) { return vm.sched ? (iint)vm.sched->tasks.size() : 0; }

#else  // !LOBSTER_TASKS

void DeleteScheduler(Scheduler *) {}
void TaskForwardError(VM &) {}
bool TaskWaitIO(VM &, int, int, int, double, bool &) { return false; }

static void NoTasks(VM &vm) { vm.BuiltinError("tasks are not supported on this platform"); }
static uint64_t SpawnTask(VM &vm, fun_base_t) { NoTasks(vm); return 0; }
static void YieldTask(VM &) {}
static void SleepTask(VM &, double seconds) {
    if (seconds > 0) std::this_thread::sleep_for(std::chrono::duration<double>(min(seconds, 1e7)));
}
static void JoinTask(VM &, uint64_t) {}
static void WaitAllTasks(VM &) {}
static iint CountTasks(VM &) { return 0; }

#endif  // LOBSTER_TASKS

BuiltinGroup task_builtins;
#define BUILTIN_GROUP task_builtins
#define BUILTIN_SYM(name) builtin_task_##name

BUILTIN(spawn, "f", "L", "R:task",
    "start a task running f, a function with no arguments, and return a handle for join. The task"
    " runs when the current one parks: in task.sleep, task.join, task.wait_all, task.yield or"
    " tcp.wait, which can be anywhere down a call chain, there is no async/await coloring."
    " Tasks share one thread and never run in parallel, so they need no locking. f sees"
    " copies of the variables of the function calling spawn as they are now, and the globals"
    " themselves. An error in a task ends the program, the same as an error anywhere else.")
(VM &vm, fun_base_t f) {
    auto id = SpawnTask(vm, f);
    return vm.NewResource(&task_type, new TaskHandle(id));
}

BUILTIN(yield, "", "", "",
    "let the other tasks that can run take a turn, then continue.")
(VM &vm) {
    YieldTask(vm);
}

BUILTIN(sleep, "seconds", "F", "",
    "park the current task for the given time, letting other tasks run. Unlike sleeping, this"
    " does not hold up the others.")
(VM &vm, double seconds) {
    SleepTask(vm, seconds);
}

BUILTIN(join, "task", "R:task", "",
    "park the current task until the given one has finished. Returns at once if it already has.")
(VM &vm, LResource *task) {
    JoinTask(vm, GetResourceDec<TaskHandle>(task, &task_type).id);
}

BUILTIN(wait_all, "", "", "",
    "park the current task until all other tasks have finished, which is what a main program that"
    " has tasks to run to completion should do last.")
(VM &vm) {
    WaitAllTasks(vm);
}

BUILTIN(count, "", "", "I",
    "the number of tasks that have not finished yet. A task counts itself.")
(VM &vm) {
    return CountTasks(vm);
}

}  // namespace lobster
