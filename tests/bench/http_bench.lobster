// Requests per second of modules/httpserver.lobster for its two kinds of handler, with the clients
// in the same VM (so the numbers are of the server and clients together, on one thread), each on
// one keep-alive connection, and optionally with many more connections that do nothing.
//
//     bin/lobster tests/bench/http_bench.lobster [-- clients [requests_each [idle_connections]]]
import std
import httpserver

def int_arg(s: string) -> int:
    let v, ok = string_to_int(s, 10)
    assert ok
    return v

var done_requests = 0

def read_response(sock: resource<tcpsocket>, want: string):
    var got = ""
    while got.length < want.length:
        let data, err = tcp.receive(sock, 4096)
        assert not err and not (data and data.length == 0)
        if data: got += data
        else: tcp.wait(nil, sock, false, 0.1)
    assert got == want

def main():
    let args = command_line_arguments()
    let clients = if args.length > 0: int_arg(args[0]) else: 50
    let each = if args.length > 1: int_arg(args[1]) else: 200
    let idle_count = if args.length > 2: int_arg(args[2]) else: 0
    let srv_opt, err = http_listen("127.0.0.1", 0)
    assert not err
    let srv = assert srv_opt
    srv.route("GET", "/polled") r: text("ok")
    srv.route_task("GET", "/task") r: text("ok")
    task.spawn(): srv.serve()
    let idle: [resource<tcpsocket>] = []
    for(idle_count):
        let sock_opt, idle_err = tcp.connect("127.0.0.1", srv.port)
        assert not idle_err
        idle.push(assert sock_opt)
        task.yield()
    task.sleep(0.2)
    let want = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nok"
    for(["/polled", "/task"]) path:
        done_requests = 0
        let t0 = seconds_elapsed()
        let handles = map(clients) i: task.spawn(): one_client(srv.port, path, each, want)
        for(handles) h: task.join(h)
        let took = seconds_elapsed() - t0
        assert done_requests == clients * each
        print "{path}: {clients} connections (+{idle_count} idle) x {each} requests = {int(done_requests / took)} requests/s"
    srv.stop()
    for(idle) sock: tcp.close(sock)
    task.wait_all()

def one_client(port: int, path: string, each: int, want: string):
    let sock_opt, err = tcp.connect("127.0.0.1", port)
    assert not err
    let sock = assert sock_opt
    while true:
        let connected, err2 = tcp.connected(sock)
        assert not err2
        if connected: break
        tcp.wait(nil, sock, true, 0.1)
    let request = "GET {path} HTTP/1.1\r\nHost: b\r\n\r\n"
    for(each):
        var off = 0
        while off < request.length:
            let n, err3 = tcp.send(sock, request, off)
            assert not err3
            off += n
        read_response(sock, want)
        done_requests++
    tcp.close(sock)

main()
