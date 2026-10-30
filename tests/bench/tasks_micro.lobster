// Microbenchmarks of tasks: what a switch, a spawn and a parked task cost.
//
//     bin/lobster tests/bench/tasks_micro.lobster            switch + spawn costs
//     bin/lobster tests/bench/tasks_micro.lobster parked     only parks 10000 tasks, to read the
//                                                            peak memory of (/usr/bin/time -l)
//
// Needs a build with tasks. For the cost of the same server written without them see
// tests/bench/tcp_echo_tasks.lobster and tcp_echo_polling.lobster.
import std

var count = 0

def spinner(n: int):
    for(n):
        count += 1
        task.yield()

def parked():
    task.sleep(2.0)
    count += 1

def best_of(runs: int, f) -> float:
    var best = 1000000000.0
    for(runs):
        let t0 = seconds_elapsed()
        f()
        best = min(best, seconds_elapsed() - t0)
    return best

if command_line_arguments().length > 0 and command_line_arguments()[0] == "parked":
    for(10000): task.spawn(): parked()
    task.wait_all()
    print "parked tasks done: {count}"
else:
    // Two tasks yielding to each other, so every yield is exactly one switch.
    let switches = 200000
    let t_switch = best_of(5):
        count = 0
        task.spawn(): spinner(switches)
        task.spawn(): spinner(switches)
        task.wait_all()
        assert count == switches * 2
    print "switch: {int(t_switch / (switches * 2) * 1000000000.0)} ns per switch ({switches * 2} switches, best of 5)"

    // Spawn, run to completion and reap, in batches so the stack pool is what is measured.
    let batch = 1000
    let batches = 100
    let t_spawn = best_of(5):
        count = 0
        for(batches):
            for(batch): task.spawn(): count += 1
            task.wait_all()
        assert count == batch * batches
    print "spawn+run+finish: {int(t_spawn / (batch * batches) * 1000000000.0)} ns per task ({batch * batches} tasks, best of 5)"

    // The same, but each batch has to be spawned larger than the stack pool, so stacks are mapped.
    let big = 5000
    let t_big = best_of(3):
        count = 0
        for(big): task.spawn(): count += 1
        task.wait_all()
        assert count == big
    print "spawn+run+finish, {big} alive at once: {int(t_big / big * 1000000000.0)} ns per task (best of 3)"
