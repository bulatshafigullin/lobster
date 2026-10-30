// A call that parks the task lets other tasks run, which may write the global the loop is
// iterating over, so it counts as a write to it.
// EXPECT-ERROR: may park the task

var g = [1, 2, 3]

def f():
    for(g) e:
        task.sleep(0.01)
        print e

f()
