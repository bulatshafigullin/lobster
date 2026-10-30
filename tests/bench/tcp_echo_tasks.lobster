// A TCP echo server and its clients, all in one VM, written with tasks: every connection is
// plain blocking-style code. The same workload without tasks is tcp_echo_polling.lobster, which
// has to be a hand-written state machine. Both print the same number to compare, and take the
// same two phases: connecting (not timed, a few at a time because the listener's backlog is
// small) and then every client doing its round trips at once.
//
//     bin/lobster tests/bench/tcp_echo_tasks.lobster [-- clients [rounds]]
import std

def int_arg(s: string) -> int:
    let v, ok = string_to_int(s, 10)
    assert ok
    return v

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
            if data.length == 0: return
            send_all(conn, data)
        else:
            tcp.wait(nil, conn, false, 1.0)

var accepted = 0
var connected_clients = 0
var go = false
var round_trips = 0

def serve(listener: resource<tcplistener>, clients: int):
    while accepted < clients:
        let conn, err = tcp.accept(listener)
        assert not err
        if conn:
            accepted++
            task.spawn(): echo(conn)
        else:
            tcp.wait(listener, nil, false, 1.0)

def client(port: int, id: int, rounds: int):
    // Not too far ahead of the server accepting, or connections are refused.
    while id - accepted >= 4: task.yield()
    let sock_opt, connect_error = tcp.connect("127.0.0.1", port)
    assert not connect_error
    let sock = assert sock_opt
    while true:
        let connected, err = tcp.connected(sock)
        assert not err
        if connected: break
        tcp.wait(nil, sock, true, 1.0)
    connected_clients++
    while not go: task.yield()
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
        round_trips++

def main():
    let args = command_line_arguments()
    let clients = if args.length > 0: int_arg(args[0]) else: 50
    let rounds = if args.length > 1: int_arg(args[1]) else: 200

    let listener_opt, listen_error = tcp.listen("127.0.0.1", 0)
    assert not listen_error
    let listener = assert listener_opt
    let port, port_error = tcp.port(listener)
    assert not port_error

    task.spawn(): serve(listener, clients)
    let handles = map(clients) id: task.spawn(): client(port, id, rounds)
    while connected_clients < clients: task.yield()

    let t0 = seconds_elapsed()
    go = true
    for(handles) h: task.join(h)
    let took = seconds_elapsed() - t0
    assert round_trips == clients * rounds
    print "tasks:   {clients} clients x {rounds} rounds: {round_trips} round trips in {took}s = {int(round_trips / took)} /s"

main()
// A client closes its socket when its task ends, which in turn ends the echo task serving it.
task.wait_all()
