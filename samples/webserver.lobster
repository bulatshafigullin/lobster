// A web server with handlers in both styles, see modules/httpserver.lobster.
//
//     bin/lobster samples/webserver.lobster [-- port]
//
// then open http://localhost:8080/hello, /countdown or /slow.
import std
import httpserver

def int_arg(s: string) -> int:
    let v, ok = string_to_int(s, 10)
    assert ok
    return v

var hits = 0

let args = command_line_arguments()
let srv, err = http_listen("127.0.0.1", if args.length: int_arg(args[0]) else: 8080)
assert not err
let server = assert srv

// Hand-written handlers run on the event loop and must not block. Most of them answer at once.
server.route("GET", "/hello") r:
    hits++
    text("hello, you are visitor {hits}\n")

server.route("POST", "/echo") r:
    text(r.body)

// One that is not ready is called again on the next pass of the loop, with its state kept in
// the request: this counts down three passes before it answers.
server.route("GET", "/countdown") r:
    r.state++
    if r.state <= 3: nil else: text("liftoff\n")

// Handlers in blocking style run in tasks of their own, so they can wait for things, however
// deep in their calls, while the server carries on with everything else.
def fetch_slowly(n: int) -> int:
    task.sleep(0.5)
    return n * n

server.route_task("GET", "/slow") r:
    let a = fetch_slowly(3)
    let b = fetch_slowly(4)
    text("slow answer {a + b}\n")

print "listening on http://127.0.0.1:{server.port}/"
server.serve()
