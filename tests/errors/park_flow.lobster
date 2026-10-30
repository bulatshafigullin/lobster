// A nil check of a global does not survive a call that parks the task, another task may set
// it to nil meanwhile.
// EXPECT-ERROR: dereferencing nillable type

class node:
    v:int

var n:node? = node { 7 }

def reader():
    if n:
        task.yield()
        print n.v

reader()
