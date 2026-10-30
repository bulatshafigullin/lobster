// A small HTTP/1.1 server that mixes two ways of doing asynchronous work.
//
// The low level, reading requests and writing responses on many connections at once, is
// hand-written: an event loop running a state machine per connection, on the non-blocking tcp
// calls. It never blocks on any one connection, and a connection that is slow costs nothing but
// its buffers.
//
// What the user of the server writes can be in either style, per route:
//
//   route(...)       a hand-written handler, a function from request to response?. It is called
//                    on the event loop, so it must not block. Returning a response ends the
//                    request. Returning nil means "not ready": it is called again on the next pass
//                    of the loop, with request.state and request.data to keep a state machine in.
//                    Most handlers just return a response straight away.
//
//   route_task(...)  a handler that is plain blocking-style code, from request to response. It
//                    runs in a task of its own (see task.spawn), so it may task.sleep, wait on
//                    other tasks, or use sockets with tcp.wait, however deep in its calls, and
//                    other requests carry on meanwhile. There is no async/await to write.
//
// Both kinds can be on the same server, and the same loop serves them. Needs a build with tasks
// only for route_task, route does not use them.
//
// Not here: TLS, chunked request bodies, percent-decoding, HTTP/2. An error in a handler is an
// error of the whole program, as anywhere else.
//
//     import httpserver
//     let srv, err = http_listen("127.0.0.1", 8080)
//     assert not err
//     srv.route("GET", "/hello") r: text("hello")
//     srv.route_task("GET", "/slow") r:
//         task.sleep(1.0)
//         text("done")
//     srv.serve()

import std

// What the handler is told.
class request:
    method: string
    path: string
    query: string  // After the ?, undecoded.
    header_names: [string]  // Lowercase.
    header_values: [string]
    body: string
    // For a handler that is called again until it has a response, to keep its place.
    state: int = 0
    data: string = ""

    def header(name: string) -> string:
        let n = lowercase(name)
        for(header_names) h, i:
            if h == n: return header_values[i]
        return ""

class response:
    status: int
    body: string
    content_type: string
    headers: [string]  // Extra lines, each "Name: value".

def text(body: string, status: int = 200) -> response:
    return response { status, body, "text/plain; charset=utf-8", [] }

def html(body: string, status: int = 200) -> response:
    return response { status, body, "text/html; charset=utf-8", [] }

def json(body: string, status: int = 200) -> response:
    return response { status, body, "application/json", [] }

// The types of the two kinds of handler.
def handler_t(r: request) -> response?
def task_handler_t(r: request) -> response

private class polled_route:
    method: string
    path: string  // A trailing * matches any rest.
    handler: handler_t

private class task_route:
    method: string
    path: string
    handler: task_handler_t

// Where a connection is.
private let READ_HEAD = 0
private let READ_BODY = 1
private let HANDLING = 2
private let WRITING = 3
private let CLOSED = 4

private let max_head_bytes = 16384
private let max_body_bytes = 1048576

private class conn:
    sock: resource<tcpsocket>
    id: int  // Its place in server.slots, plus one, and what the poller reports it as.
    queued: bool = false  // In server.active.
    write_watch: bool = false  // The poller is told to report when it can be written to.
    phase: int = READ_HEAD
    inbuf: string = ""
    req: request? = nil
    body_start: int = 0  // Where in inbuf the body of req begins.
    body_len: int = 0
    polled: polled_route? = nil
    task_done: bool = false  // The task handling it (if that is how) has set result.
    result: response? = nil
    out: string = ""
    sent: int = 0
    keep_alive: bool = true

class server:
    private listener: resource<tcplistener>
    port: int
    private poller: resource<tcppoller>
    private slots: [conn?]  // All connections, closed ones leave a nil.
    private free_slots: [int]
    private active: [conn]  // To be stepped on the next pass, they got somewhere on the last.
    private handling: [conn]  // Waiting for a handler, which has to be asked on every pass.
    private polled_routes: [polled_route]
    private task_routes: [task_route]
    private running = true

    // A hand-written handler, see the top of this file.
    def route(method: string, path: string, handler: handler_t):
        polled_routes.push(polled_route { method, path, handler })

    // A handler that may block, see the top of this file.
    def route_task(method: string, path: string, handler: task_handler_t):
        task_routes.push(task_route { method, path, handler })

    // Makes serve() return, after the pass of the loop it is in.
    def stop():
        running = false

    // Runs the event loop until stop() is called. A server may be run in a task of its own to do
    // other things meanwhile.
    //
    // A pass steps the connections the poller says something happened to, and those that got
    // somewhere on the last pass, since a step does one receive or send and there may be more. A
    // connection whose step got nowhere is left alone until the poller reports it again, which
    // is what makes many idle connections free. Only waiting for a handler has to be polled.
    def serve():
        while running:
            // Handlers are waited for by asking, or by their task finishing, which only happens
            // while this waits or yields, so then not for long.
            let timeout = if active.length: 0.0 elif handling.length: 0.001 else: 0.1
            for(tcp.poll(poller, timeout)) tag:
                if tag == 0:
                    accept_pending()
                elif tag <= slots.length:
                    let c = slots[tag - 1]
                    if c: enqueue(c)
            let stepping = active
            active = []
            for(stepping) c:
                c.queued = false
                if c.phase != CLOSED and step(c): enqueue(c)
            var i = 0
            while i < handling.length:
                let c = handling[i]
                if c.phase == HANDLING:
                    if step(c): enqueue(c)
                if c.phase == HANDLING:
                    i++
                else:
                    handling[i] = handling[handling.length - 1]
                    handling.pop()
            if task.count() > 0 and active.length: task.yield()

    private def enqueue(c: conn):
        if not c.queued:
            c.queued = true
            active.push(c)

    // Takes in all the connections waiting, the poller doesn't say again about those it did.
    private def accept_pending():
        while true:
            let sock, err = tcp.accept(listener)
            if err or not sock: break
            var slot = slots.length
            if free_slots.length:
                slot = free_slots.pop()
            else:
                slots.push(nil)
            let c = conn { sock, slot + 1 }
            slots[slot] = c
            assert not tcp.watch(poller, sock, c.id, false)
            enqueue(c)

    // One step of the state machine of a connection, true if it did anything.
    private def step(c: conn) -> bool:
        if c.phase <= READ_BODY: return read_step(c)
        if c.phase == HANDLING: return handle_step(c)
        if c.phase == WRITING: return write_step(c)
        return false

    private def read_step(c: conn) -> bool:
        var progress = false
        // What is buffered already may be a whole request, if they were sent together.
        if c.inbuf.length == 0 or not request_complete(c):
            let data, err = tcp.receive(c.sock, 16384)
            if err:
                close_conn(c)
                return true
            if not data: return false
            if data.length == 0:
                close_conn(c)
                return true
            c.inbuf += data
            progress = true
            if not request_complete(c):
                if c.phase == READ_HEAD and c.inbuf.length > max_head_bytes:
                    fail(c, 431, "request headers too large")
                return progress
        if c.phase != CLOSED and c.phase != WRITING: dispatch(c)
        return true

    // Looks at the buffer for the head and the body of a request, and moves the connection to
    // READ_BODY or returns true when all of a request is there. Answers by itself if it is bad.
    private def request_complete(c: conn) -> bool:
        if c.phase == READ_HEAD:
            let end = find_string(c.inbuf, "\r\n\r\n")
            if end < 0: return false
            if not parse_head(c, end): return false
            c.phase = READ_BODY
        if c.phase == READ_BODY:
            return c.inbuf.length - c.body_start >= c.body_len
        return false

    private def parse_head(c: conn, end: int) -> bool:
        let lines = tokenize(substring(c.inbuf, 0, end), "\n", "\r \t", 0)
        let first = if lines.length: tokenize(lines[0], " ", "", 0) else: []
        if first.length != 3 or not (first[2] == "HTTP/1.1" or first[2] == "HTTP/1.0"):
            fail(c, 400, "bad request")
            return false
        let target = first[1]
        let q = find_string(target, "?")
        let names: [string] = []
        let values: [string] = []
        for(lines.length - 1) i:
            let line = lines[i + 1]
            let colon = find_string(line, ":")
            if colon > 0:
                names.push(lowercase(substring(line, 0, colon)))
                var v = colon + 1
                while v < line.length and (line[v] == 32 or line[v] == 9): v++
                values.push(substring(line, v, -1))
        let r = request { first[0], if q >= 0: substring(target, 0, q) else: target,
                          if q >= 0: substring(target, q + 1, -1) else: "", names, values, "" }
        let length_header = r.header("content-length")
        var length = 0
        if length_header.length:
            let n, ok = string_to_int(length_header, 10)
            if not ok or n < 0:
                fail(c, 400, "bad content-length")
                return false
            length = n
        if length > max_body_bytes:
            fail(c, 413, "request body too large")
            return false
        if r.header("transfer-encoding").length:
            fail(c, 501, "chunked request bodies are not supported")
            return false
        let conn_header = lowercase(r.header("connection"))
        c.keep_alive = if first[2] == "HTTP/1.0": conn_header == "keep-alive" else: conn_header != "close"
        c.req = r
        c.body_start = end + 4
        c.body_len = length
        return true

    // Finds the handler for the complete request in the buffer and starts it.
    private def dispatch(c: conn):
        let r = assert c.req
        r.body = substring(c.inbuf, c.body_start, c.body_len)
        c.inbuf = substring(c.inbuf, c.body_start + c.body_len, -1)
        c.phase = HANDLING
        handling.push(c)
        for(polled_routes) pr:
            if matches(pr.method, pr.path, r):
                c.polled = pr
                return
        for(task_routes) tr:
            if matches(tr.method, tr.path, r):
                let h = tr.handler
                task.spawn():
                    c.result = h(r)
                    c.task_done = true
                return
        c.result = text("not found", 404)
        c.task_done = true

    private def matches(method: string, path: string, r: request) -> bool:
        if method != r.method: return false
        if path.length and path[path.length - 1] == 42:  // *
            return r.path.length >= path.length - 1 and
                   substring(r.path, 0, path.length - 1) == substring(path, 0, path.length - 1)
        return path == r.path

    private def handle_step(c: conn) -> bool:
        if c.polled:
            let h = c.polled.handler
            let result = h(assert c.req)
            if not result: return false
            c.polled = nil
            c.result = result
            c.task_done = true
        if not c.task_done: return false
        let result = assert c.result
        c.result = nil
        begin_write(c, result)
        return true

    private def fail(c: conn, status: int, message: string):
        c.keep_alive = false
        c.inbuf = ""
        begin_write(c, text(message, status))

    private def begin_write(c: conn, r: response):
        var head = "HTTP/1.1 {r.status} {reason(r.status)}\r\nContent-Type: {r.content_type}\r\n" +
                   "Content-Length: {r.body.length}\r\nConnection: {if c.keep_alive: "keep-alive" else: "close"}\r\n"
        for(r.headers) h: head += h + "\r\n"
        c.out = head + "\r\n" + r.body
        c.sent = 0
        c.req = nil
        c.result = nil
        c.task_done = false
        c.phase = WRITING

    // Closes the socket for real, a dropped reference to it may be kept by anything.
    private def close_conn(c: conn):
        tcp.close(c.sock)
        c.phase = CLOSED
        slots[c.id - 1] = nil
        free_slots.push(c.id - 1)

    private def write_step(c: conn) -> bool:
        let n, err = tcp.send(c.sock, c.out, c.sent)
        if err:
            close_conn(c)
            return true
        c.sent += n
        if c.sent < c.out.length:
            // The poller says when there is room again, once asked to.
            if n == 0 and not c.write_watch:
                assert not tcp.watch(poller, c.sock, c.id, true)
                c.write_watch = true
            return n > 0
        if c.write_watch:
            assert not tcp.watch(poller, c.sock, c.id, false)
            c.write_watch = false
        c.out = ""
        if c.keep_alive: c.phase = READ_HEAD else: close_conn(c)
        return true

def reason(status: int) -> string:
    return switch status:
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status"

// Starts listening, port 0 to be given any free one (see server.port). Returns the server and
// nil, or nil and what went wrong.
def http_listen(ip: string, port: int) -> server?, string?:
    let listener, err = tcp.listen(ip, port)
    if err or not listener: return nil, if err: err else: "listen failed"
    let actual, port_err = tcp.port(listener)
    if port_err: return nil, port_err
    let poller, poller_err = tcp.poller()
    if poller_err or not poller: return nil, if poller_err: poller_err else: "poller failed"
    assert not tcp.watch_listener(poller, listener, 0)
    return server { listener, actual, poller, [], [], [], [], [], [] }, nil
