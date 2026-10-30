// The workload of tcp_echo_tasks.lobster written without tasks, as a loop that tries every
// connection in turn, which is what a build without them has to do: tcp.wait can only sleep on
// one listener and one socket, so it is used only when nothing at all made progress.
//
//     bin/lobster tests/bench/tcp_echo_polling.lobster [-- clients [rounds]]
import std

def int_arg(s: string) -> int:
    let v, ok = string_to_int(s, 10)
    assert ok
    return v

class client_state:
    sock: resource<tcpsocket>
    id: int
    round: int
    sent: bool
    got: string

// Locals of the top level are globals, which would keep the last socket open to the end.
def main():
    let args = command_line_arguments()
    let clients = if args.length > 0: int_arg(args[0]) else: 50
    let rounds = if args.length > 1: int_arg(args[1]) else: 200

    let listener_opt, listen_error = tcp.listen("127.0.0.1", 0)
    assert not listen_error
    let listener = assert listener_opt
    let port, port_error = tcp.port(listener)
    assert not port_error

    // Connect, one at a time because the listener's backlog is small, as in tcp_echo_tasks.lobster.
    let states: [client_state] = []
    let peers: [resource<tcpsocket>] = []
    for(clients) id:
        let sock_opt, connect_error = tcp.connect("127.0.0.1", port)
        assert not connect_error
        let sock = assert sock_opt
        states.push(client_state { sock, id, 0, false, "" })
        var peer: resource<tcpsocket>? = nil
        while not peer:
            let accepted, accept_error = tcp.accept(listener)
            assert not accept_error
            peer = accepted
            if not peer: tcp.wait(listener, nil, false, 1.0)
        peers.push(assert peer)
        while true:
            let connected, err = tcp.connected(sock)
            assert not err
            if connected: break
            tcp.wait(nil, sock, true, 1.0)

    var finished = 0
    var round_trips = 0

    let t0 = seconds_elapsed()
    while finished < clients:
        var progress = false
        // The server side: echo whatever has arrived.
        for(peers) peer:
            let data, err = tcp.receive(peer, 4096)
            assert not err
            if data and data.length:
                let n, send_error = tcp.send(peer, data, 0)
                assert not send_error and n == data.length
                progress = true
        // The client side: one step of each client's state machine.
        for(states) c:
            if c.round < rounds:
                if not c.sent:
                    let msg = "client{c.id} says {c.round}"
                    let n, err = tcp.send(c.sock, msg, 0)
                    assert not err and n == msg.length
                    c.sent = true
                    progress = true
                else:
                    let data, err = tcp.receive(c.sock, 4096)
                    assert not err
                    if data and data.length:
                        c.got += data
                        let msg = "client{c.id} says {c.round}"
                        if c.got.length >= msg.length:
                            assert c.got == msg
                            c.got = ""
                            c.sent = false
                            c.round++
                            round_trips++
                            progress = true
                            if c.round == rounds: finished++
        if not progress: tcp.wait(listener, nil, false, 0.001)
    let took = seconds_elapsed() - t0
    assert round_trips == clients * rounds
    print "polling: {clients} clients x {rounds} rounds: {round_trips} round trips in {took}s = {int(round_trips / took)} /s"

main()
