// Tests of modules/httpserver.lobster, with clients (hand-written, over raw sockets) and the
// server in one VM. Needs a build with tasks.
import std
import httpserver

class client:
    sock: resource<tcpsocket>
    buf: string = ""
    closed: bool = false

    def send(data: string):
        var off = 0
        while off < data.length:
            let n, err = tcp.send(sock, data, off)
            assert not err
            off += n
            if off < data.length: tcp.wait(nil, sock, true, 0.1)

    // Reads more into the buffer, false at the end of the connection.
    def fill() -> bool:
        if closed: return false
        for(1000):
            let data, err = tcp.receive(sock, 65536)
            assert not err
            if data:
                if data.length == 0:
                    closed = true
                    return false
                buf += data
                return true
            tcp.wait(nil, sock, false, 0.05)
        assert false
        return false

    // The next response: status, body, and the head for checking headers.
    def response() -> int, string, string:
        var end = find_string(buf, "\r\n\r\n")
        while end < 0:
            assert fill()
            end = find_string(buf, "\r\n\r\n")
        let head = substring(buf, 0, end)
        let status, ok = string_to_int(substring(head, 9, 3), 10)
        assert ok
        let at = find_string(lowercase(head), "content-length:")
        assert at >= 0
        let line_end = find_string(head, "\r\n", at)
        let length, ok2 = string_to_int(substring(head, at + 16, if line_end >= 0: line_end - at - 16 else: -1), 10)
        assert ok2
        while buf.length < end + 4 + length: assert fill()
        let body = substring(buf, end + 4, length)
        buf = substring(buf, end + 4 + length, -1)
        return status, body, head

    def close():
        tcp.close(sock)

    def at_eof() -> bool:
        while not closed and buf.length == 0:
            if not fill(): break
        return closed and buf.length == 0

def open_client(port: int) -> client:
    let sock_opt, err = tcp.connect("127.0.0.1", port)
    assert not err
    let sock = assert sock_opt
    while true:
        let connected, err2 = tcp.connected(sock)
        assert not err2
        if connected: break
        tcp.wait(nil, sock, true, 0.1)
    return client { sock }

def big_body() -> string:
    var b = "0123456789abcdef"
    for(18): b = b + b
    return b

def get(path: string, extra: string = "") -> string:
    return "GET {path} HTTP/1.1\r\nHost: test\r\n{extra}\r\n"

var concurrent_done = 0
var result_of_helper = 0
var slow_latency = 0.0

def main():
    let srv_opt, err = http_listen("127.0.0.1", 0)
    assert not err
    let srv = assert srv_opt
    let port = srv.port

    // Hand-written handlers.
    srv.route("GET", "/hello") r: text("hello")
    srv.route("GET", "/echo") r: text("{r.method} {r.path} [{r.query}] {r.header("X-Test")}")
    srv.route("POST", "/post") r: text("got {r.body.length}: {r.body}", 201)
    srv.route("GET", "/static/*") r: html("<p>{r.path}</p>")
    // One that has to be asked again, to keep its place in a state machine.
    srv.route("GET", "/steps") r:
        r.state++
        if r.state < 4: nil else: text("after {r.state} calls")
    // A response too big for the socket to take at once, which then goes out as it is read.
    srv.route("GET", "/big") r: text(big_body())  // 4 MB
    // Handlers that block.
    srv.route_task("GET", "/slow") r:
        task.sleep(0.2)
        text("slow done")
    srv.route_task("GET", "/nested") r:
        // Parks several calls deep, and uses another task to compute something.
        var result = 0
        let helper = task.spawn():
            task.sleep(0.01)
            result_of_helper = 42
        task.join(helper)
        text("helper said {result_of_helper}")
    task.spawn(): srv.serve()

    // A request, with the rest of the connection kept.
    let c = open_client(port)
    c.send(get("/hello"))
    let s1, b1, h1 = c.response()
    assert s1 == 200 and b1 == "hello"
    assert find_string(h1, "Connection: keep-alive") >= 0
    // Same connection again, and other kinds of request.
    c.send(get("/echo?a=1&b=2", "X-Test:   value with spaces \r\n"))
    let s2, b2, h2 = c.response()
    assert s2 == 200 and b2 == "GET /echo [a=1&b=2] value with spaces"
    c.send("POST /post HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\n\r\nhello")
    let s3, b3, h3 = c.response()
    assert s3 == 201 and b3 == "got 5: hello"
    c.send(get("/static/css/site.css"))
    let s4, b4, h4 = c.response()
    assert s4 == 200 and b4 == "<p>/static/css/site.css</p>" and find_string(h4, "text/html") >= 0
    c.send(get("/nothing"))
    let s5, b5, h5 = c.response()
    assert s5 == 404
    c.send("POST /hello HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
    let s5b, b5b, h5b = c.response()
    assert s5b == 404  // The method is part of the route.

    // The handler that is called until it has an answer.
    c.send(get("/steps"))
    let s6, b6, h6 = c.response()
    assert s6 == 200 and b6 == "after 4 calls"

    // Several requests in one packet are answered in order.
    c.send(get("/hello") + get("/echo?x") + get("/hello"))
    let p1, pb1, ph1 = c.response()
    let p2, pb2, ph2 = c.response()
    let p3, pb3, ph3 = c.response()
    assert pb1 == "hello" and pb2 == "GET /echo [x] " and pb3 == "hello"

    // A request that arrives in pieces, the head and the body.
    let msg = "POST /post HTTP/1.1\r\nContent-Length: 11\r\n\r\nhello world"
    var at = 0
    while at < msg.length:
        c.send(substring(msg, at, min(7, msg.length - at)))
        at += 7
        task.sleep(0.01)
    let s7, b7, h7 = c.response()
    assert s7 == 201 and b7 == "got 11: hello world"

    // A blocking handler.
    c.send(get("/nested"))
    let s8, b8, h8 = c.response()
    assert s8 == 200 and b8 == "helper said 42"

    // A big response, read slowly, and the connection works after it.
    c.send(get("/big"))
    task.sleep(0.1)
    let s8b, b8b, h8b = c.response()
    assert s8b == 200 and b8b.length == 4194304
    c.send(get("/hello"))
    let s8c, b8c, h8c = c.response()
    assert b8c == "hello"

    // Connection: close closes it after the response.
    c.send(get("/hello", "Connection: close\r\n"))
    let s9, b9, h9 = c.response()
    assert s9 == 200 and find_string(h9, "Connection: close") >= 0
    assert c.at_eof()

    // Bad requests.
    let bad = open_client(port)
    bad.send("NOT A REQUEST\r\n\r\n")
    let s10, b10, h10 = bad.response()
    assert s10 == 400
    assert bad.at_eof()
    let chunked = open_client(port)
    chunked.send("POST /post HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
    let s11, b11, h11 = chunked.response()
    assert s11 == 501

    // Blocking handlers overlap: 20 that each sleep 0.2s take about that, not 4s.
    let t0 = seconds_elapsed()
    for(20):
        task.spawn():
            let cl = open_client(port)
            cl.send(get("/slow"))
            let s, b, h = cl.response()
            assert s == 200 and b == "slow done"
            cl.close()
            concurrent_done++
    // And meanwhile hand-written ones are not held up by them.
    task.sleep(0.05)
    let t1 = seconds_elapsed()
    for(10):
        c2_send_and_check(port)
    slow_latency = seconds_elapsed() - t1
    assert slow_latency < 0.15
    while concurrent_done < 20: task.sleep(0.01)
    let took = seconds_elapsed() - t0
    assert took < 1.5

    // Many connections at once, several requests each.
    let many = 100

    for(many) id:
        task.spawn():
            let cl = open_client(port)
            for(5) r:
                cl.send(get("/echo?{id}-{r}"))
                let s, b, h = cl.response()
                assert b == "GET /echo [{id}-{r}] "
            cl.close()
            concurrent_done++
    while concurrent_done < 20 + many: task.sleep(0.01)

    srv.stop()
    task.wait_all()

def c2_send_and_check(port: int):
    let cl = open_client(port)
    cl.send(get("/hello"))
    let s, b, h = cl.response()
    assert s == 200 and b == "hello"
    cl.close()

main()
print "httpserver test passed"
