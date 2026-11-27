// SPDX-License-Identifier: MIT
// TFTP [-i] host[:port] GET remote [local]
// TFTP [-i] host[:port] PUT local [remote]
//
// A TFTP client (RFC 1350, with the blksize option of RFC 2347/2348) that
// carries its own small network stack, ARP + IPv4 + UDP, on top of the
// packet driver service E1h (ABI.md). Static configuration from the
// environment variables IP, NETMASK and GATEWAY; unset, they default to the
// addresses of QEMU's user-mode network (10.0.2.15/24, gateway 10.0.2.2).
//
// Lock-step transfer with retransmission on timeout (1 s doubling to 4 s,
// six tries). Duplicate DATA is acknowledged again; duplicate ACKs are
// ignored (no Sorcerer's Apprentice). Block numbers wrap at 65535 as 16-bit
// counters. Packets from a foreign port get error 5 and are otherwise
// ignored. Without -i the transfer uses netascii: CR NUL <-> bare CR,
// bare LF -> CR LF on PUT.
.include "lib.inc"

.equ PKT_MAX, 1536              // frame buffers (largest frame 1514)
.equ WANT_BLKSIZE, 1432         // requested: fits a 1500-byte MTU
.equ MAX_TRIES, 6
.equ FIRST_TIMEOUT, 1000        // ms
.equ MAX_TIMEOUT, 4000
.equ DALLY_MS, 500
.equ FBUF_SIZE, 4096
// Offsets in a frame (Ethernet header first).
.equ ETH_TYPE, 12
.equ IP_HDR, 14
.equ UDP_HDR, 34                // with a 20-byte IP header (as sent)
.equ UDP_DATA, 42
// TFTP opcodes.
.equ OP_RRQ, 1
.equ OP_WRQ, 2
.equ OP_DATA, 3
.equ OP_ACK, 4
.equ OP_ERROR, 5
.equ OP_OACK, 6

.macro ldg reg, sym
    adrp \reg, \sym
    ldr \reg, [\reg, :lo12:\sym]
.endm
.macro stg reg, sym, tmp
    adrp \tmp, \sym
    str \reg, [\tmp, :lo12:\sym]
.endm
// Big-endian 16-bit fields at any byte offset (w registers).
.macro ld_be16 dst, base, off, tmp
    ldrb \dst, [\base, #\off]
    ldrb \tmp, [\base, #(\off + 1)]
    orr \dst, \tmp, \dst, lsl #8
.endm
.macro st_be16 val, base, off, tmp
    lsr \tmp, \val, #8
    strb \tmp, [\base, #\off]
    strb \val, [\base, #(\off + 1)]
.endm
// An IPv4 address (raw network order) at a 2-byte aligned offset.
.macro ld_ip dst, base, off, tmp
    ldrh \dst, [\base, #\off]
    ldrh \tmp, [\base, #(\off + 2)]
    orr \dst, \dst, \tmp, lsl #16
.endm
.macro st_ip val, base, off, tmp
    strh \val, [\base, #\off]
    lsr \tmp, \val, #16
    strh \tmp, [\base, #(\off + 2)]
.endm
.macro net fn
    mov x0, #\fn
    mov w8, #0xe1
    bl dos_entry
.endm

main:
    enter
    mov x19, x0
    isb
    mrs x0, cntfrq_el0
    mov x1, #1000
    udiv x0, x0, x1
    cmp x0, #0
    csinc x0, x0, xzr, ne
    stg x0, tick_ms, x1
    mov x0, #69
    stg x0, server_port, x1
    mov x0, x19
    bl arg_next
    mov x19, x1
    ldrb w2, [x0]
    cmp w2, #'-'
    b.eq 1f
    cmp w2, #'/'
    b.ne 2f
1:
    ldrb w2, [x0, #1]
    orr w2, w2, #0x20
    cmp w2, #'i'
    b.ne usage
    ldrb w2, [x0, #2]
    cbnz w2, usage
    mov x2, #1
    stg x2, octet, x3
    mov x0, x19
    bl arg_next
    mov x19, x1
2:
    ldrb w2, [x0]
    cbz w2, usage
    // host[:port]
    bl parse_ip
    cbnz x1, bad_host
    stg x0, server_ip, x3
    ldrb w3, [x2]
    cbz w3, 3f
    cmp w3, #':'
    b.ne bad_host
    add x0, x2, #1
    bl parse_dec
    cbnz x1, bad_host
    ldrb w3, [x2]
    cbnz w3, bad_host
    cbz x0, bad_host
    mov x3, #0xffff
    cmp x0, x3
    b.hi bad_host
    stg x0, server_port, x3
3:
    mov x0, x19
    bl arg_next
    mov x19, x1
    mov x20, x0
    address x1, word_get
    bl strcmpi
    mov x21, #OP_RRQ
    cbz x0, 4f
    mov x0, x20
    address x1, word_put
    bl strcmpi
    cbnz x0, usage
    mov x21, #OP_WRQ
4:
    mov x0, x19
    bl arg_next
    mov x19, x1
    mov x22, x0                 // source
    ldrb w2, [x22]
    cbz w2, usage
    mov x0, x19
    bl arg_next
    mov x19, x1
    mov x23, x0                 // destination, or empty
    mov x0, x19
    bl arg_next
    ldrb w2, [x0]
    cbnz w2, usage              // too many arguments
    ldrb w2, [x23]
    cbnz w2, 5f
    mov x0, x22                 // default: the source's last component
    bl last_component
    mov x23, x0
    ldrb w2, [x23]
    cbz w2, usage
5:
    cmp x21, #OP_RRQ
    csel x24, x22, x23, eq      // remote name
    csel x25, x23, x22, eq      // local name
    mov x0, x24
    bl strlen
    cmp x0, #400
    b.hi bad_name
    stg x24, remote_name, x2
    stg x25, local_name, x2
    bl net_setup
    cbnz x0, 9f
    bl arp_resolve
    cbnz x0, 9f
    isb
    mrs x0, cntvct_el0
    stg x0, start_time, x1
    and x0, x0, #0x3fff         // an ephemeral local port per run
    add x0, x0, #49152
    stg x0, local_port, x1
    cmp x21, #OP_RRQ
    b.ne 6f
    bl do_get
    b 9f
6:
    bl do_put
9:
    leave
usage:
    address x0, usage_text
    bl puts
    bl show_interface
    mov x0, #1
    leave
bad_host:
    say "Invalid host: give an IPv4 address such as 10.0.2.2, optionally :port.\r\n"
    mov x0, #1
    leave
bad_name:
    say "File name too long.\r\n"
    mov x0, #1
    leave

// x0 = cursor. Splits off one blank-separated argument ("quotes" allowed;
// unlike next_arg, '/' is part of a name, as in remote paths): x0 =
// argument (empty at the end), x1 = rest.
arg_next:
1:
    ldrb w2, [x0]
    cmp w2, #' '
    b.eq 2f
    cmp w2, #9
    b.eq 2f
    cmp w2, #13
    b.eq 2f
    cmp w2, #10
    b.ne 3f
2:
    add x0, x0, #1
    b 1b
3:
    mov w4, #' '                // terminator
    cmp w2, #'"'
    b.ne 4f
    mov w4, #'"'
    add x0, x0, #1
4:
    mov x1, x0
5:
    ldrb w2, [x1]
    cbz w2, 7f
    cmp w2, w4
    b.eq 6f
    cmp w4, #'"'
    b.eq 51f
    cmp w2, #9
    b.eq 6f
    cmp w2, #13
    b.eq 6f
    cmp w2, #10
    b.eq 6f
51:
    add x1, x1, #1
    b 5b
6:
    strb wzr, [x1], #1
7:
    ret

// x0 = path. Returns x0 = the part after the last '/', '\' or ':'.
last_component:
    mov x1, x0
1:
    ldrb w2, [x1], #1
    cbz w2, 2f
    cmp w2, #'/'
    b.eq 11f
    cmp w2, #'\\'
    b.eq 11f
    cmp w2, #':'
    b.ne 1b
11:
    mov x0, x1
    b 1b
2:
    ret

// x0 = dotted quad. Returns x0 = address in network byte order as a raw
// little-endian u32, x1 = 0 ok / 1 invalid, x2 = the byte after it.
parse_ip:
    mov x3, #0                  // address
    mov x4, #0                  // octet index
    mov x9, #10
1:
    mov x5, #0                  // value
    mov x6, #0                  // digits
2:
    ldrb w7, [x0]
    sub w7, w7, #'0'
    cmp w7, #9
    b.hi 3f
    madd x5, x5, x9, x7
    add x6, x6, #1
    add x0, x0, #1
    cmp x6, #3
    b.ls 2b
    b 8f
3:
    cbz x6, 8f
    cmp x5, #255
    b.hi 8f
    lsl x7, x4, #3
    lsl x5, x5, x7
    orr x3, x3, x5
    add x4, x4, #1
    cmp x4, #4
    b.eq 4f
    ldrb w7, [x0]
    cmp w7, #'.'
    b.ne 8f
    add x0, x0, #1
    b 1b
4:
    mov x2, x0
    mov x0, x3
    mov x1, #0
    ret
8:
    mov x2, x0
    mov x1, #1
    ret

// x0 = raw address: prints a.b.c.d.
print_ip:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, #0
1:
    lsr x0, x19, x20
    and x0, x0, #0xff
    mov x1, #0
    bl put_dec
    add x20, x20, #8
    cmp x20, #32
    b.hs 2f
    mov x0, #'.'
    bl putc
    b 1b
2:
    ldp x19, x20, [sp], #16
    unframe

// x0 = 6-byte address: prints xx:xx:xx:xx:xx:xx.
print_mac:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, #0
1:
    ldrb w0, [x19, x20]
    mov x1, #2
    bl put_hex
    add x20, x20, #1
    cmp x20, #6
    b.hs 2f
    mov x0, #':'
    bl putc
    b 1b
2:
    ldp x19, x20, [sp], #16
    unframe

// The interface line of the usage text.
show_interface:
    frame
    stp x19, x20, [sp, #-16]!
    net 0
    cbz x1, 1f
    say "Network: no packet driver (E1h).\r\n"
    b 9f
1:
    mov x19, x0
    address x1, my_mac
    net 1
    say "Network: Ethernet "
    address x0, my_mac
    bl print_mac
    address x0, link_up_text
    address x1, link_down_text
    cmp x19, #0
    csel x0, x0, x1, ne
    bl puts
9:
    ldp x19, x20, [sp], #16
    unframe

// Finds the packet driver and reads the configuration. Returns x0 = 0.
net_setup:
    frame
    stp x19, x20, [sp, #-16]!
    net 0
    cbz x1, 1f
    say "No network: the packet driver (E1h) is not available.\r\n"
    say "Networking needs native mode and a virtio-net device.\r\n"
    b 8f
1:
    cbnz x0, 2f
    say "Network link is down.\r\n"
    b 8f
2:
    address x1, my_mac
    net 1
    cbnz x1, 8f
    mov x1, #3                  // own address and broadcast
    net 4
    address x0, env_ip
    movz w1, #0x000a            // 10.0.2.15
    movk w1, #0x0f02, lsl #16
    bl env_address
    cbnz x1, 8f
    stg x0, my_ip, x1
    address x0, env_netmask
    mov w1, #0x00ffffff         // 255.255.255.0
    bl env_address
    cbnz x1, 8f
    stg x0, netmask, x1
    address x0, env_gateway
    movz w1, #0x000a            // 10.0.2.2
    movk w1, #0x0202, lsl #16
    bl env_address
    cbnz x1, 8f
    stg x0, gateway, x1
    mov x0, #0
    ldp x19, x20, [sp], #16
    unframe
8:
    mov x0, #1
    ldp x19, x20, [sp], #16
    unframe

// x0 = variable name, w1 = default. Returns x0 = address, x1 = 0, or
// x1 = 1 after reporting a malformed value.
env_address:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov w20, w1
    bl getenv
    cbz x0, 1f
    bl parse_ip
    cbnz x1, 2f
    ldrb w3, [x2]
    cbnz w3, 2f
    ldp x19, x20, [sp], #16
    unframe
1:
    mov w0, w20
    mov x1, #0
    ldp x19, x20, [sp], #16
    unframe
2:
    say "Invalid address in environment variable "
    mov x0, x19
    bl puts
    bl crlf
    mov x1, #1
    ldp x19, x20, [sp], #16
    unframe

// x0 = data, x1 = length, x2 = running sum. Returns x0 = the 16-bit one's
// complement sum (folded, not inverted), big-endian words.
checksum:
1:
    cmp x1, #2
    b.lo 2f
    ldrb w3, [x0]
    ldrb w4, [x0, #1]
    add x2, x2, x3, lsl #8
    add x2, x2, x4
    add x0, x0, #2
    sub x1, x1, #2
    b 1b
2:
    cbz x1, 3f
    ldrb w3, [x0]
    add x2, x2, x3, lsl #8
3:
    lsr x3, x2, #16
    cbz x3, 4f
    and x2, x2, #0xffff
    add x2, x2, x3
    b 3b
4:
    mov x0, x2
    ret

// x0 = destination, x1 = source: copies a 6-byte MAC (2-byte aligned).
copy6:
    ldrh w2, [x1]
    strh w2, [x0]
    ldrh w2, [x1, #2]
    strh w2, [x0, #2]
    ldrh w2, [x1, #4]
    strh w2, [x0, #4]
    ret

// x0 = length of the frame in tx_frame. Returns x1 = 0 when sent.
send_frame:
    frame
    mov x2, x0
    address x1, tx_frame
    net 2
    unframe

// Polls for one frame and handles ARP. Returns x0 = UDP payload for our
// port (0 if none), x1 = its length, x2 = source port, x3 = source address.
net_poll:
    frame
    address x1, rx_frame
    mov x2, #PKT_MAX
    net 3
    cbnz x1, 8f
    cmp x0, x2                  // truncated frames are not ours
    b.ne 8f
    cbz x0, 8f
    mov x1, x0
    address x0, rx_frame
    ld_be16 w2, x0, ETH_TYPE, w3
    cmp w2, #0x0800
    b.eq 2f
    mov w3, #0x0806
    cmp w2, w3
    b.ne 8f
    bl arp_input
    b 8f
2:
    bl ip_input
    unframe
8:
    mov x0, #0
    unframe

// x0 = frame, x1 = length: learns the address we are resolving and
// answers requests for our own address.
arp_input:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    cmp x1, #42
    b.lo 9f
    ld_be16 w2, x19, 14, w3     // hardware type: Ethernet
    cmp w2, #1
    b.ne 9f
    ld_be16 w2, x19, 16, w3     // protocol: IPv4
    cmp w2, #0x0800
    b.ne 9f
    ldrh w2, [x19, #18]         // lengths 6 and 4
    mov w3, #0x0406
    cmp w2, w3
    b.ne 9f
    ld_be16 w20, x19, 20, w3    // operation
    ld_ip w2, x19, 28, w3       // sender protocol address
    ldg x4, arp_wanted
    cmp w2, w4
    b.ne 1f
    cbz w2, 1f
    address x0, hop_mac
    add x1, x19, #22
    bl copy6
    mov x2, #1
    stg x2, arp_done, x3
1:
    cmp w20, #1
    b.ne 9f
    ld_ip w2, x19, 38, w3       // target protocol address
    ldg x4, my_ip
    cmp w2, w4
    b.ne 9f
    // Reply: to the asker, from us.
    address x20, tx_frame
    mov x0, x20
    add x1, x19, #22
    bl copy6
    add x0, x20, #6
    address x1, my_mac
    bl copy6
    mov w2, #0x0806
    st_be16 w2, x20, ETH_TYPE, w3
    mov w2, #1
    st_be16 w2, x20, 14, w3
    mov w2, #0x0800
    st_be16 w2, x20, 16, w3
    mov w2, #0x0406
    strh w2, [x20, #18]
    mov w2, #2
    st_be16 w2, x20, 20, w3
    add x0, x20, #22
    address x1, my_mac
    bl copy6
    ldg x2, my_ip
    st_ip w2, x20, 28, w3
    add x0, x20, #32
    add x1, x19, #22
    bl copy6
    ld_ip w2, x19, 28, w3
    st_ip w2, x20, 38, w3
    mov x0, #42
    bl send_frame
9:
    ldp x19, x20, [sp], #16
    unframe

// x0 = frame, x1 = length. Validates IPv4 and UDP (checksums included) and
// returns as net_poll does.
ip_input:
    frame
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    add x19, x0, #IP_HDR
    sub x20, x1, #IP_HDR        // bytes after the Ethernet header
    cmp x20, #28
    b.lt 8f
    ldrb w2, [x19]
    lsr w3, w2, #4
    cmp w3, #4
    b.ne 8f
    and w2, w2, #15
    lsl w21, w2, #2             // header length
    cmp w21, #20
    b.lo 8f
    ld_be16 w22, x19, 2, w3     // total length
    cmp x22, x20
    b.hi 8f
    add w3, w21, #8
    cmp w22, w3
    b.lo 8f
    ldrb w2, [x19, #6]          // fragments are not reassembled
    and w2, w2, #0x3f
    ldrb w3, [x19, #7]
    orr w2, w2, w3
    cbnz w2, 8f
    ldrb w2, [x19, #9]
    cmp w2, #17                 // UDP
    b.ne 8f
    ld_ip w2, x19, 16, w3
    ldg x4, my_ip
    cmp w2, w4
    b.ne 8f
    mov x0, x19
    mov x1, x21
    mov x2, #0
    bl checksum
    mov x3, #0xffff
    cmp x0, x3
    b.ne 8f
    add x20, x19, x21           // UDP header
    sub w22, w22, w21           // bytes of UDP
    ld_be16 w2, x20, 4, w3      // UDP length
    cmp w2, #8
    b.lo 8f
    cmp w2, w22
    b.hi 8f
    mov w22, w2
    ld_be16 w2, x20, 2, w3
    ldg x4, local_port
    cmp w2, w4
    b.ne 8f
    ld_be16 w2, x20, 6, w3
    cbz w2, 1f                  // no checksum sent
    add x0, x19, #12            // pseudo header: addresses, protocol, length
    mov x1, #8
    add x2, x22, #17
    bl checksum
    mov x2, x0
    mov x0, x20
    mov x1, x22
    bl checksum
    mov x3, #0xffff
    cmp x0, x3
    b.ne 8f
1:
    add x0, x20, #8
    sub x1, x22, #8
    ld_be16 w2, x20, 0, w3
    ld_ip w3, x19, 12, w4
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe
8:
    mov x0, #0
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    unframe

// Returns x0 = the counter value x0 milliseconds from now.
deadline_ms:
    ldg x1, tick_ms
    mul x1, x1, x0
    isb
    mrs x0, cntvct_el0
    add x0, x0, x1
    ret

// Resolves the next hop (the server on our subnet, else the gateway) into
// hop_mac. Returns x0 = 0, or 1 after reporting.
arp_resolve:
    enter
    ldg x2, server_ip
    ldg x3, my_ip
    ldg x4, netmask
    eor x5, x2, x3
    tst x5, x4
    b.eq 1f
    ldg x2, gateway
1:
    mov x21, x2
    stg x21, arp_wanted, x3
    stg xzr, arp_done, x3
    mov x19, #4                 // requests
2:
    address x20, tx_frame
    mov x2, #-1
    str w2, [x20]               // broadcast
    strh w2, [x20, #4]
    add x0, x20, #6
    address x1, my_mac
    bl copy6
    mov w2, #0x0806
    st_be16 w2, x20, ETH_TYPE, w3
    mov w2, #1
    st_be16 w2, x20, 14, w3
    mov w2, #0x0800
    st_be16 w2, x20, 16, w3
    mov w2, #0x0406
    strh w2, [x20, #18]
    mov w2, #1                  // request
    st_be16 w2, x20, 20, w3
    add x0, x20, #22
    address x1, my_mac
    bl copy6
    ldg x2, my_ip
    st_ip w2, x20, 28, w3
    str wzr, [x20, #32]
    strh wzr, [x20, #36]
    st_ip w21, x20, 38, w3
    mov x0, #42
    bl send_frame
    mov x0, #1000
    bl deadline_ms
    mov x22, x0
3:
    bl net_poll
    ldg x2, arp_done
    cbnz x2, 8f
    bl console_check
    isb
    mrs x2, cntvct_el0
    cmp x2, x22
    b.lo 3b
    subs x19, x19, #1
    b.ne 2b
    say "No ARP reply from "
    mov x0, x21
    bl print_ip
    say "; check IP, NETMASK and GATEWAY.\r\n"
    mov x0, #1
    leave
8:
    mov x0, #0
    leave

// Lets Ctrl-C through (a DOS call checks for it) now and then.
console_check:
    adrp x9, poll_count
    ldr x10, [x9, :lo12:poll_count]
    add x10, x10, #1
    str x10, [x9, :lo12:poll_count]
    tst x10, #0xff
    b.ne 1f
    frame
    mov w8, #0x0b
    bl dos_entry
    unframe
1:
    ret

// x0 = payload, x1 = length, x2 = destination port: one UDP datagram to
// the server. Returns x1 = 0 when sent.
udp_send:
    enter
    mov x21, x0
    mov x22, x1
    mov x23, x2
    address x19, tx_frame
    mov x0, x19
    address x1, hop_mac
    bl copy6
    add x0, x19, #6
    address x1, my_mac
    bl copy6
    mov w2, #0x0800
    st_be16 w2, x19, ETH_TYPE, w3
    add x20, x19, #IP_HDR
    mov w2, #0x45               // IPv4, 20-byte header, TOS 0
    strh w2, [x20]
    add w2, w22, #28
    st_be16 w2, x20, 2, w3
    ldg x2, ip_id
    add x3, x2, #1
    stg x3, ip_id, x4
    st_be16 w2, x20, 4, w3
    mov w2, #0x40               // don't fragment
    strh w2, [x20, #6]
    mov w2, #0x1140             // TTL 64, protocol 17
    strh w2, [x20, #8]
    strh wzr, [x20, #10]
    ldg x2, my_ip
    st_ip w2, x20, 12, w3
    ldg x2, server_ip
    st_ip w2, x20, 16, w3
    mov x0, x20
    mov x1, #20
    mov x2, #0
    bl checksum
    mvn w0, w0
    st_be16 w0, x20, 10, w3
    add x24, x19, #UDP_HDR
    ldg x2, local_port
    st_be16 w2, x24, 0, w3
    st_be16 w23, x24, 2, w3
    add w25, w22, #8
    st_be16 w25, x24, 4, w3
    strh wzr, [x24, #6]
    mov x2, #0
1:
    cmp x2, x22
    b.hs 2f
    ldrb w3, [x21, x2]
    add x4, x24, #8
    strb w3, [x4, x2]
    add x2, x2, #1
    b 1b
2:
    add x0, x20, #12
    mov x1, #8
    add x2, x25, #17
    bl checksum
    mov x2, x0
    mov x0, x24
    mov x1, x25
    bl checksum
    mvn w0, w0
    and w0, w0, #0xffff
    cbnz w0, 3f
    mov w0, #0xffff             // 0 means "no checksum"
3:
    st_be16 w0, x24, 6, w3
    add x0, x22, #UDP_DATA
    bl send_frame
    leave

// x0 = deadline. Waits for a UDP datagram from the server. Returns as
// net_poll, or x0 = 0 at the deadline.
wait_server:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
1:
    bl net_poll
    cbz x0, 2f
    ldg x4, server_ip
    cmp w3, w4
    b.ne 1b
    ldp x19, x20, [sp], #16
    unframe
2:
    bl console_check
    isb
    mrs x2, cntvct_el0
    cmp x2, x19
    b.lo 1b
    mov x0, #0
    ldp x19, x20, [sp], #16
    unframe

// ---------------------------------------------------------------------------
// TFTP.

// The port to send to: the server's transfer ID once known.
dest_port:
    ldg x0, locked
    cbz x0, 1f
    ldg x0, peer_port
    ret
1:
    ldg x0, server_port
    ret

// x0 = length of the packet in pkt: sends it as the new "last packet"
// and restarts the retransmission timer.
tftp_send:
    frame
    stg x0, last_len, x1
    stg xzr, tries, x1
    mov x0, #FIRST_TIMEOUT
    stg x0, timeout, x1
    bl deadline_ms
    stg x0, deadline, x1
    bl tftp_resend
    unframe

// Sends the last packet again (timers unchanged).
tftp_resend:
    frame
    bl dest_port
    mov x2, x0
    address x0, pkt
    ldg x1, last_len
    bl udp_send
    unframe

// x0 = error code, x1 = message, x2 = port: sends an ERROR packet.
send_error:
    frame
    address x3, err_pkt
    mov w4, #OP_ERROR
    st_be16 w4, x3, 0, w5
    st_be16 w0, x3, 2, w5
    add x3, x3, #4
    mov x4, #0
1:
    ldrb w5, [x1], #1
    strb w5, [x3], #1
    add x4, x4, #1
    cbnz w5, 1b
    address x0, err_pkt
    add x1, x4, #4
    bl udp_send
    unframe

// Receives the next packet of the transfer, retransmitting on timeouts.
// Returns x0 = 0 with x1 = payload, x2 = length, x3 = opcode; or x0 = 1
// after reporting a timeout.
tftp_recv:
    enter
1:
    ldg x0, deadline
    bl wait_server
    cbz x0, 5f
    mov x19, x0
    mov x20, x1
    mov x21, x2
    ldg x3, locked
    cbz x3, 2f
    ldg x4, peer_port
    cmp x21, x4
    b.eq 2f
    mov x0, #5                  // someone else's transfer
    address x1, msg_unknown_tid
    mov x2, x21
    bl send_error
    b 1b
2:
    cmp x20, #4
    b.lo 1b
    strb wzr, [x19, x20]        // NUL after the packet: strings end
    ld_be16 w22, x19, 0, w3
    cmp w22, #OP_ERROR
    b.eq 3f
    ldg x3, locked
    cbnz x3, 3f
    stg x21, peer_port, x3      // the server's transfer ID
    mov x3, #1
    stg x3, locked, x4
3:
    mov x0, #0
    mov x1, x19
    mov x2, x20
    mov x3, x22
    leave
5:
    ldg x2, tries
    add x2, x2, #1
    stg x2, tries, x3
    cmp x2, #MAX_TRIES
    b.hs 6f
    ldg x0, timeout
    lsl x0, x0, #1
    mov x1, #MAX_TIMEOUT
    cmp x0, x1
    csel x0, x0, x1, ls
    stg x0, timeout, x1
    bl deadline_ms
    stg x0, deadline, x1
    bl tftp_resend
    b 1b
6:
    say "Timed out waiting for the server.\r\n"
    mov x0, #1
    leave

// x0 = opcode, x1 = file name. Builds RRQ/WRQ in pkt (with the blksize
// option while use_options is set) and sends it.
send_request:
    frame
    address x2, pkt
    st_be16 w0, x2, 0, w3
    mov x0, x1
    add x1, x2, #2
    bl strcpy
    add x1, x0, #1
    address x0, mode_netascii
    ldg x2, octet
    cbz x2, 1f
    address x0, mode_octet
1:
    bl strcpy
    add x1, x0, #1
    ldg x2, use_options
    cbz x2, 2f
    address x0, opt_blksize
    bl strcpy
    add x1, x0, #1
    address x0, opt_blksize_value
    bl strcpy
    add x1, x0, #1
2:
    address x0, pkt
    sub x0, x1, x0
    bl tftp_send
    unframe

// x0 = opcode, x1 = block: builds DATA/ACK header in pkt.
put_header:
    address x2, pkt
    st_be16 w0, x2, 0, w3
    st_be16 w1, x2, 2, w3
    ret

// x0 = ERROR payload, x1 = its length: reports it. Returns x0 = the code.
report_error:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    ld_be16 w20, x19, 2, w3
    say "Error from server: "
    add x0, x19, #4
    ldrb w2, [x0]
    cbnz w2, 1f
    address x0, msg_no_text
1:
    bl puts
    say " (code "
    mov x0, x20
    mov x1, #0
    bl put_dec
    say ")\r\n"
    mov x0, x20
    ldp x19, x20, [sp], #16
    unframe

// x0 = OACK payload, x1 = length. Accepts blksize up to what was asked.
// Returns x0 = 0, or 1 (after sending error 8) for anything else.
parse_oack:
    enter
    add x19, x0, #2
    add x20, x0, x1             // end (a NUL was stored there)
1:
    cmp x19, x20
    b.hs 8f
    mov x21, x19                // name
    mov x0, x19
    bl strlen
    add x22, x21, x0
    add x22, x22, #1            // value
    cmp x22, x20
    b.hs 9f
    mov x0, x22
    bl strlen
    add x19, x22, x0
    add x19, x19, #1
    mov x0, x21
    address x1, opt_blksize
    bl strcmpi
    cbnz x0, 9f                 // an option we did not ask for
    mov x0, x22
    bl parse_dec
    cbnz x1, 9f
    ldrb w3, [x2]
    cbnz w3, 9f
    cmp x0, #8
    b.lo 9f
    cmp x0, #WANT_BLKSIZE
    b.hi 9f
    stg x0, blksize, x1
    b 1b
8:
    mov x0, #0
    leave
9:
    bl dest_port
    mov x2, x0
    mov x0, #8
    address x1, msg_bad_option
    bl send_error
    say "Server sent an unacceptable option.\r\n"
    mov x0, #1
    leave

// Shared start of a transfer.
transfer_reset:
    mov x0, #512
    stg x0, blksize, x1
    mov x0, #1
    stg x0, use_options, x1
    stg xzr, locked, x1
    ret

// Prints "Transfer successful: n bytes in s.ss seconds."
report_success:
    frame
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    say "Transfer successful: "
    mov x0, x19
    mov x1, #0
    bl put_dec
    say " bytes in "
    isb
    mrs x0, cntvct_el0
    ldg x1, start_time
    sub x0, x0, x1
    ldg x1, tick_ms
    udiv x0, x0, x1             // milliseconds
    mov x1, #10
    udiv x0, x0, x1             // hundredths
    mov x20, x0
    mov x1, #100
    udiv x0, x20, x1
    mov x1, #0
    bl put_dec
    mov x0, #'.'
    bl putc
    mov x1, #100
    udiv x0, x20, x1
    msub x0, x0, x1, x20
    mov x1, #2
    bl put_dec0
    say " seconds.\r\n"
    ldp x19, x20, [sp], #16
    unframe

// GET: remote_name from the server into local_name. Returns x0 = exit code.
do_get:
    enter
    ldg x0, local_name
    mov x1, #0
    bl fcreate
    cbz x1, 1f
    mov x19, x0
    say "Cannot create "
    ldg x0, local_name
    bl puts
    say ": "
    mov x0, x19
    bl print_error
    mov x0, #1
    leave
1:
    mov x19, x0                 // handle
    mov x20, #1                 // expected block
    mov x21, #0                 // bytes received
    mov x23, #1                 // still in the request stage
    stg xzr, prev_cr, x2
    bl transfer_reset
2:
    mov x0, #OP_RRQ
    ldg x1, remote_name
    bl send_request
3:
    bl tftp_recv
    cbnz x0, 90f
    mov x24, x1                 // payload
    mov x25, x2                 // length
    cmp x3, #OP_ERROR
    b.eq 20f
    cmp x3, #OP_OACK
    b.eq 30f
    cmp x3, #OP_DATA
    b.eq 40f
    b 80f
20:
    cbz x23, 21f                // server rejected our options: once more
    ldg x2, use_options         // without them (RFC 2347)
    cbz x2, 21f
    ld_be16 w2, x24, 2, w3
    cmp w2, #8
    b.ne 21f
    stg xzr, use_options, x2
    stg xzr, locked, x2
    b 2b
21:
    mov x0, x24
    mov x1, x25
    bl report_error
    b 90f
30:
    cbz x23, 31f
    ldg x2, use_options
    cbz x2, 80f
    mov x0, x24
    mov x1, x25
    bl parse_oack
    cbnz x0, 90f
    mov x23, #0
    mov x0, #OP_ACK
    mov x1, #0
    bl put_header
    mov x0, #4
    bl tftp_send
    b 3b
31:
    cmp x20, #1                 // our ACK 0 was lost: send it again
    b.ne 3b
    bl tftp_resend
    b 3b
40:
    ld_be16 w2, x24, 2, w3
    sub x26, x25, #4            // data bytes
    cmp w2, w20
    b.eq 41f
    cbnz x23, 3b
    sub w3, w20, #1
    and w3, w3, #0xffff
    cmp w2, w3
    b.ne 3b                     // neither new nor a repeat: ignore
    bl tftp_resend              // repeat: our ACK was lost
    b 3b
41:
    ldg x2, blksize
    cmp x26, x2
    b.hi 80f
    mov x23, #0
    add x0, x24, #4
    mov x1, x26
    bl decode_netascii
    mov x27, x0
    mov x2, x0
    add x1, x24, #4
    mov x0, x19
    bl fwrite
    cbnz x1, 42f
    cmp x0, x27
    b.ne 42f
43:
    add x21, x21, x26
    mov x0, #OP_ACK
    mov x1, x20
    bl put_header
    mov x0, #4
    bl tftp_send
    add w20, w20, #1
    and w20, w20, #0xffff
    ldg x2, blksize
    cmp x26, x2
    b.lo 50f
    b 3b
42:
    say "Write error: disk full?\r\n"
    bl dest_port
    mov x2, x0
    mov x0, #3
    address x1, msg_disk_full
    bl send_error
    b 90f
50:
    // Done. Dally a little in case the final ACK is lost.
    mov x0, #DALLY_MS
    bl deadline_ms
    mov x22, x0
51:
    mov x0, x22
    bl wait_server
    cbz x0, 52f
    ldg x4, peer_port
    cmp x2, x4
    b.ne 51b
    ld_be16 w3, x0, 0, w4
    cmp w3, #OP_DATA
    b.ne 51b
    bl tftp_resend
    b 51b
52:
    mov x0, x19
    bl fclose
    mov x0, x21
    bl report_success
    mov x0, #0
    leave
80:
    say "Illegal TFTP packet from the server.\r\n"
    bl dest_port
    mov x2, x0
    mov x0, #4
    address x1, msg_illegal
    bl send_error
90:
    mov x0, x19                 // remove the partial file
    bl fclose
    ldg x0, local_name
    mov w8, #0x41
    bl dos_entry
    mov x0, #1
    leave

// x0 = data, x1 = length: in netascii mode, drops the NUL of each CR NUL
// in place. Returns x0 = the length to write.
decode_netascii:
    ldg x2, octet
    cbz x2, 1f
    mov x0, x1
    ret
1:
    ldg x6, prev_cr
    mov x2, #0                  // in
    mov x3, #0                  // out
2:
    cmp x2, x1
    b.hs 4f
    ldrb w4, [x0, x2]
    add x2, x2, #1
    cbz x6, 3f
    cbnz w4, 3f
    mov x6, #0
    b 2b
3:
    strb w4, [x0, x3]
    add x3, x3, #1
    cmp w4, #13
    cset x6, eq
    b 2b
4:
    stg x6, prev_cr, x2
    mov x0, x3
    ret

// PUT: local_name to remote_name on the server. Returns x0 = exit code.
do_put:
    enter
    ldg x0, local_name
    mov x1, #0
    bl fopen
    cbz x1, 1f
    mov x19, x0
    say "Cannot open "
    ldg x0, local_name
    bl puts
    say ": "
    mov x0, x19
    bl print_error
    mov x0, #1
    leave
1:
    mov x19, x0                 // handle
    stg x19, file_handle, x2
    mov x20, #0                 // block awaiting its ACK
    mov x21, #0                 // bytes sent
    mov x22, #0                 // final block sent
    mov x23, #1                 // request stage
    stg xzr, fpos, x2
    stg xzr, flen, x2
    mov x2, #-1
    stg x2, enc_pending, x3
    stg x2, enc_back, x3
    bl transfer_reset
2:
    mov x0, #OP_WRQ
    ldg x1, remote_name
    bl send_request
3:
    bl tftp_recv
    cbnz x0, 90f
    mov x24, x1
    mov x25, x2
    cmp x3, #OP_ERROR
    b.eq 20f
    cmp x3, #OP_OACK
    b.eq 30f
    cmp x3, #OP_ACK
    b.eq 40f
    b 80f
20:
    cbz x23, 21f
    ldg x2, use_options
    cbz x2, 21f
    ld_be16 w2, x24, 2, w3
    cmp w2, #8
    b.ne 21f
    stg xzr, use_options, x2
    stg xzr, locked, x2
    b 2b
21:
    mov x0, x24
    mov x1, x25
    bl report_error
    b 90f
30:
    cbz x23, 3b                 // a repeated OACK: our DATA 1 will be resent
    ldg x2, use_options
    cbz x2, 80f
    mov x0, x24
    mov x1, x25
    bl parse_oack
    cbnz x0, 90f
    mov x23, #0
    b 45f                       // as ACK 0
40:
    ld_be16 w2, x24, 2, w3
    cmp w2, w20
    b.ne 3b                     // duplicate or stray ACK: never resend on it
    mov x23, #0
    cbnz x22, 50f
45:
    address x0, pkt
    add x0, x0, #4
    ldg x1, blksize
    bl read_block
    tbnz x0, #63, 85f
    mov x26, x0
    add w20, w20, #1
    and w20, w20, #0xffff
    mov x0, #OP_DATA
    mov x1, x20
    bl put_header
    add x0, x26, #4
    bl tftp_send
    add x21, x21, x26
    ldg x2, blksize
    cmp x26, x2
    cset x22, lo
    b 3b
50:
    mov x0, x19
    bl fclose
    mov x0, x21
    bl report_success
    mov x0, #0
    leave
80:
    say "Illegal TFTP packet from the server.\r\n"
    bl dest_port
    mov x2, x0
    mov x0, #4
    address x1, msg_illegal
    bl send_error
    b 90f
85:
    say "Read error.\r\n"
    bl dest_port
    mov x2, x0
    mov x0, #0
    address x1, msg_read_error
    bl send_error
90:
    mov x0, x19
    bl fclose
    mov x0, #1
    leave

// Next input byte of the PUT file: x0 = byte, or -1 at end of file (or
// -2 on a read error).
file_getc:
    frame
    ldg x0, enc_back
    tbnz x0, #63, 1f
    mov x1, #-1
    stg x1, enc_back, x2
    unframe
1:
    ldg x2, fpos
    ldg x3, flen
    cmp x2, x3
    b.lo 2f
    ldg x0, file_handle
    address x1, fbuf
    mov x2, #FBUF_SIZE
    bl fread
    cbnz x1, 8f
    stg x0, flen, x1
    stg xzr, fpos, x1
    cbz x0, 7f
    mov x2, #0
2:
    address x1, fbuf
    ldrb w0, [x1, x2]
    add x2, x2, #1
    stg x2, fpos, x3
    unframe
7:
    mov x0, #-1
    unframe
8:
    mov x0, #-2
    unframe

// x0 = destination, x1 = block size: fills one DATA block from the file
// (netascii-encoded without -i). Returns x0 = bytes (short at the end),
// or negative on a read error.
read_block:
    enter
    mov x19, x0
    mov x20, x1
    mov x21, #0
1:
    cmp x21, x20
    b.hs 8f
    ldg x0, enc_pending
    tbnz x0, #63, 2f
    mov x1, #-1
    stg x1, enc_pending, x2
    b 6f
2:
    bl file_getc
    cmn x0, #2
    b.eq 9f
    tbnz x0, #63, 8f            // end of file
    ldg x2, octet
    cbnz x2, 6f
    cmp x0, #13
    b.ne 4f
    // CR: CR LF stays a line end, anything else makes it CR NUL.
    bl file_getc
    cmn x0, #2
    b.eq 9f
    cmp x0, #10
    b.eq 3f
    stg x0, enc_back, x2        // not LF: read again next time (or EOF)
    mov x0, #0
3:
    stg x0, enc_pending, x2
    mov x0, #13
    b 6f
4:
    cmp x0, #10                 // bare LF: CR LF
    b.ne 6f
    stg x0, enc_pending, x2
    mov x0, #13
6:
    strb w0, [x19, x21]
    add x21, x21, #1
    b 1b
8:
    mov x0, x21
    leave
9:
    mov x0, #-1
    leave

.section .rodata
word_get: .asciz "GET"
word_put: .asciz "PUT"
env_ip: .asciz "IP"
env_netmask: .asciz "NETMASK"
env_gateway: .asciz "GATEWAY"
mode_octet: .asciz "octet"
mode_netascii: .asciz "netascii"
opt_blksize: .asciz "blksize"
opt_blksize_value: .asciz "1432"
msg_unknown_tid: .asciz "Unknown transfer ID"
msg_bad_option: .asciz "Option not accepted"
msg_illegal: .asciz "Illegal TFTP operation"
msg_disk_full: .asciz "Disk full"
msg_read_error: .asciz "Read error"
msg_no_text: .asciz "(no message)"
link_up_text: .asciz ", link up\r\n"
link_down_text: .asciz ", link down\r\n"
usage_text:
    .ascii "Transfers files to and from a computer running a TFTP server.\r\n\r\n"
    .ascii "TFTP [-i] host[:port] GET source [destination]\r\n"
    .ascii "TFTP [-i] host[:port] PUT source [destination]\r\n\r\n"
    .ascii "  -i           Binary (octet) transfer; otherwise ASCII (netascii).\r\n"
    .ascii "  host         Server IPv4 address, such as 10.0.2.2 (port 69 by default).\r\n"
    .ascii "  GET          Copies the remote file source to the local destination.\r\n"
    .ascii "  PUT          Copies the local file source to the remote destination.\r\n\r\n"
    .ascii "Addresses come from the environment variables IP, NETMASK and GATEWAY\r\n"
    .ascii "(defaults 10.0.2.15, 255.255.255.0 and 10.0.2.2, QEMU user networking).\r\n"
    .asciz "\r\n"

.section .bss
.balign 16
.skip 2                         // frames start at 2 mod 16: IP header aligned
rx_frame: .skip PKT_MAX + 2
.balign 16
.skip 2
tx_frame: .skip PKT_MAX
.balign 16
pkt: .skip PKT_MAX
err_pkt: .skip 128
fbuf: .skip FBUF_SIZE
.balign 8
my_mac: .skip 8
hop_mac: .skip 8
my_ip: .skip 8
netmask: .skip 8
gateway: .skip 8
server_ip: .skip 8
server_port: .skip 8
local_port: .skip 8
peer_port: .skip 8
locked: .skip 8
arp_wanted: .skip 8
arp_done: .skip 8
ip_id: .skip 8
tick_ms: .skip 8
start_time: .skip 8
poll_count: .skip 8
octet: .skip 8
use_options: .skip 8
blksize: .skip 8
last_len: .skip 8
tries: .skip 8
timeout: .skip 8
deadline: .skip 8
remote_name: .skip 8
local_name: .skip 8
prev_cr: .skip 8
file_handle: .skip 8
fpos: .skip 8
flen: .skip 8
enc_pending: .skip 8
enc_back: .skip 8
