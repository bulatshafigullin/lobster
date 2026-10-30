// Run without a window: lobster tests/tasks/tasks.lobster
// Exercises tasks: interleaving, join, timers, what a task sees of its spawner's variables, parking
// from deep in a call chain, and many tasks sharing a VM with real sockets.
// Leaks are reported by the VM when the program ends, so a bad refcount in the free variable
// handling shows up as a failure of the whole run.
import std

var order = []
// Results come back thru globals and shared objects: what a task assigns of its spawner's locals
// stays with the task, see test_tasks_dont_share_locals.
var result_a = 0
var result_b = 0
var sum = 0
var finished = 0

def worker(name: string, n: int):
    for(n) i:
        order.push("{name}{i}")
        task.yield()

def test_interleave():
    order = []
    let a = task.spawn(): worker("a", 3)
    let b = task.spawn(): worker("b", 3)
    // Nothing runs until the spawner parks.
    assert order.length == 0
    assert task.count() == 2
    task.join(a)
    task.join(b)
    assert equal(order, ["a0", "b0", "a1", "b1", "a2", "b2"])
    assert task.count() == 0
    // Joining one that has finished is fine.
    task.join(a)

def test_wait_all():
    order = []
    for(5) i:
        task.spawn(): worker("w{i}", 2)
    task.wait_all()
    assert order.length == 10
    assert task.count() == 0
    // And with nothing to wait for.
    task.wait_all()

def test_sleep_overlaps():
    let start = seconds_elapsed()
    for(4):
        task.spawn(): task.sleep(0.2)
    task.wait_all()
    let took = seconds_elapsed() - start
    // Concurrent, rather than 0.8.
    assert took >= 0.19 and took < 0.5

def test_sleep_order():
    order = []
    task.spawn():
        task.sleep(0.15)
        order.push("slow")
    task.spawn():
        task.sleep(0.05)
        order.push("fast")
    task.wait_all()
    assert equal(order, ["fast", "slow"])

// A task may use variables of the function that spawned it, which has long returned by the
// time it runs. It gets its own copy of them, strings and all.
def spawn_with_args(i: int, s: string, out: [string]):
    task.spawn():
        task.yield()
        out.push("{i}:{s}")

def test_capture_args():
    let out = []
    for(3) i:
        spawn_with_args(i, "s{i}", out)
    task.wait_all()
    assert equal(out, ["0:s0", "1:s1", "2:s2"])

def test_capture_loop_variables():
    let out = []
    for(3) i:
        let tag = "t{i}"
        task.spawn():
            task.yield()
            out.push(tag)
    task.wait_all()
    assert equal(out, ["t0", "t1", "t2"])

struct named:
    name:string
    n:int

def spawn_with_struct(p: named, out: [string]):
    task.spawn():
        task.yield()
        out.push("{p.name}{p.n}")

def test_capture_struct():
    let out = []
    for(2) i:
        spawn_with_struct(named { "p{i}", i * 10 }, out)
    task.wait_all()
    assert equal(out, ["p00", "p110"])

// Each task has its own, so a change in one is not seen by the others, or the spawner.
def test_tasks_dont_share_locals():
    let out = []
    var counter = 100
    for(3) i:
        task.spawn():
            counter += i
            task.yield()
            out.push(counter)
    task.wait_all()
    assert equal(out, [100, 101, 102])
    assert counter == 100

// There is no async: parking is possible however deep the call is.
def deep(n: int, depth_seen: [int]) -> int:
    if n == 0:
        task.sleep(0.02)
        depth_seen.push(1)
        return 0
    return deep(n - 1, depth_seen) + 1

def test_park_deep():
    let seen = []
    let a = task.spawn(): result_a = deep(300, seen)
    let b = task.spawn(): result_b = deep(500, seen)
    task.join(a)
    task.join(b)
    assert result_a == 300 and result_b == 500 and seen.length == 2

def recurse(n: int) -> int:
    return if n == 0: 0 else: recurse(n - 1) + 1

def test_stack_depth():
    task.join(task.spawn(): result_a = recurse(3000))
    assert result_a == 3000

def test_many_tasks():
    sum = 0
    for(2000):
        task.spawn():
            task.yield()
            sum += 1
            task.yield()
    assert task.count() == 2000
    task.wait_all()
    assert sum == 2000

// Tasks that spawn tasks, and wait for them.
def test_nested():
    order = []
    let outer = task.spawn():
        let inner = task.spawn(): order.push("inner")
        order.push("outer")
        task.join(inner)
    task.join(outer)
    assert equal(order, ["outer", "inner"])

// A server and its clients, all in one VM. Every wait here would stop all of them if it blocked.
def send_all(conn: resource<tcpsocket>, data: string):
    var off = 0
    while off < data.length:
        let n, err = tcp.send(conn, data, off)
        assert not err
        off += n
        if off < data.length: tcp.wait(nil, conn, true, 1.0)

def echo(conn: resource<tcpsocket>):
    while true:
        let data, err = tcp.receive(conn, 4096)
        if err: return
        if data:
            if data.length == 0: return  // EOF
            send_all(conn, data)
        else:
            tcp.wait(nil, conn, false, 1.0)

def serve(listener: resource<tcplistener>, clients: int):
    var accepted = 0
    while accepted < clients:
        let conn, err = tcp.accept(listener)
        assert not err
        if conn:
            accepted++
            task.spawn(): echo(conn)
        else:
            tcp.wait(listener, nil, false, 1.0)

def client(port: int, id: int, rounds: int):
    let sock_opt, connect_error = tcp.connect("127.0.0.1", port)
    assert not connect_error
    let sock = assert sock_opt
    while true:
        let connected, err = tcp.connected(sock)
        assert not err
        if connected: break
        tcp.wait(nil, sock, true, 1.0)
    for(rounds) r:
        let msg = "client{id} says {r}"
        send_all(sock, msg)
        var got = ""
        while got.length < msg.length:
            let data, err = tcp.receive(sock, 4096)
            assert not err and not (data and data.length == 0)
            if data: got += data
            else: tcp.wait(nil, sock, false, 1.0)
        assert got == msg
    return 1

def test_tcp():
    let listener_opt, listen_error = tcp.listen("127.0.0.1", 0)
    assert not listen_error
    let listener = assert listener_opt
    let port, port_error = tcp.port(listener)
    assert not port_error
    let clients = 25
    task.spawn(): serve(listener, clients)
    finished = 0
    for(clients) id:
        task.spawn():
            finished += client(port, id, 5)
    let deadline = seconds_elapsed() + 20.0
    task.wait_all()
    assert finished == clients
    assert seconds_elapsed() < deadline

var rw_got = ""
var rw_writable = false

// A read wait and a write wait on the same socket, which a queue that arms a descriptor for one
// event (epoll) must keep apart: the write is ready at once, the read only when the peer sends.
def test_read_and_write_waits():
    let listener_opt, listen_error = tcp.listen("127.0.0.1", 0)
    assert not listen_error
    let listener = assert listener_opt
    let port, port_error = tcp.port(listener)
    assert not port_error
    let sock_opt, connect_error = tcp.connect("127.0.0.1", port)
    assert not connect_error
    let sock = assert sock_opt
    var peer: resource<tcpsocket>? = nil
    while not peer:
        let accepted, accept_error = tcp.accept(listener)
        assert not accept_error
        peer = accepted
        if not peer: tcp.wait(listener, nil, false, 1.0)
    let server = assert peer
    while true:
        let connected, err = tcp.connected(sock)
        assert not err
        if connected: break
        tcp.wait(nil, sock, true, 1.0)
    rw_got = ""
    rw_writable = false
    let t0 = seconds_elapsed()
    task.spawn():
        while rw_got.length == 0:
            let data, err = tcp.receive(sock, 100)
            assert not err
            if data: rw_got += data
            else: tcp.wait(nil, sock, false, 1.0)
    task.spawn():
        tcp.wait(nil, sock, true, 1.0)
        rw_writable = true
    task.sleep(0.05)
    assert rw_writable
    assert rw_got.length == 0
    let n, send_error = tcp.send(server, "hello", 0)
    assert not send_error and n == 5
    task.wait_all()
    assert rw_got == "hello"
    assert seconds_elapsed() - t0 < 0.9

test_interleave()
test_wait_all()
test_sleep_overlaps()
test_sleep_order()
test_capture_args()
test_capture_loop_variables()
test_capture_struct()
test_tasks_dont_share_locals()
test_park_deep()
test_stack_depth()
test_many_tasks()
test_nested()
test_tcp()
test_read_and_write_waits()

print "tasks test passed"
