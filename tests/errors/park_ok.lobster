// What parking must not make an error: a loop over a variable of the function itself (other
// tasks only have copies of those), and a variable initialized from a global (which then owns a
// reference), also when the park is a call or two down.
// EXPECT-OK

var g = [1, 2, 3]

def helper():
    task.yield()

def local_loop():
    let v = [1, 2, 3]
    var total = 0
    for(v) e:
        task.sleep(0.001)
        total += e
    print total

def copies_global():
    let x = g
    helper()
    helper()
    print x

local_loop()
copies_global()
