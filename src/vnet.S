// SPDX-License-Identifier: MIT
// virtio-net (virtio 1.x "modern" PCI transport) and the packet driver
// service E1h. Polled like everything else in native mode: no interrupts,
// one receive queue with posted buffers, one transmit queue.
//
// Two steps, around ExitBootServices:
//   vnet_probe  (firmware still up) finds the device by PCI ECAM, parses its
//               virtio capabilities and allocates the DMA pages. It does not
//               touch the device, which the firmware's own driver may own.
//   vnet_init   (firmware gone) resets the device, negotiates features and
//               starts both queues.
// Any failure leaves vnet_present = 0: no network, nothing else changes.
// Firmware mode never runs vnet_init, so E1h reports "no driver" there.

.equ VNET_QSIZE, 16             // entries per queue (power of two)
.equ VNET_BUF, 2048             // one buffer: 12-byte header + 1514 + slack
.equ VNET_HDR, 12               // virtio_net_hdr with num_buffers (VERSION_1)
.equ VNET_MIN_FRAME, 14
.equ VNET_MAX_FRAME, 1514
.equ VNET_PAGES, 10
// Offsets in the DMA area (all rings 16-byte aligned, buffers 2 KiB).
.equ VNET_RX_DESC, 0x0000
.equ VNET_RX_AVAIL, 0x0100
.equ VNET_RX_USED, 0x0200
.equ VNET_TX_DESC, 0x0400
.equ VNET_TX_AVAIL, 0x0500
.equ VNET_TX_USED, 0x0600
.equ VNET_TX_BUF, 0x1000
.equ VNET_RX_BUF, 0x2000        // VNET_QSIZE buffers up to 0xa000
// Feature bits.
.equ VIRTIO_NET_F_MAC, 5
.equ VIRTIO_NET_F_STATUS, 16
// Error codes returned by E1h.
.equ VNET_ERR_NONET, 50         // "network request not supported"
.equ VNET_ERR_PARAM, 87
.equ VNET_ERR_DEVICE, 21

.section .text

// Before ExitBootServices. Returns x0 = 0 if a device was found.
vnet_probe:
    enter
    stv xzr, vnet_found, x2
    stv xzr, vnet_present, x2
    ldv x2, plat_ecam           // no PCI (Raspberry Pi 3): no network
    cbz x2, 9f
    ldv x19, plat_bus_start
1:
    ldv x2, plat_bus_end
    cmp x19, x2
    b.hi 9f
    mov x20, #0
2:
    cmp x20, #32
    b.hs 8f
    mov x21, #0
3:
    cmp x21, #8
    b.hs 7f
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bl plat_pci_cfg
    mov x22, x0
    ldr w2, [x22]
    mov w3, #0xffff
    and w4, w2, w3
    cmp w4, w3
    b.eq 6f                     // nothing at this function
    mov w3, #0x1af4
    cmp w4, w3
    b.ne 5f
    lsr w4, w2, #16
    mov w3, #0x1041             // modern virtio-net
    cmp w4, w3
    b.eq 4f
    mov w3, #0x1000             // transitional: subsystem id 1 is net
    cmp w4, w3
    b.ne 5f
    ldrh w3, [x22, #0x2e]
    cmp w3, #1
    b.ne 5f
4:
    mov x0, x22
    bl vnet_caps
    cbnz x0, 5f
    mov x0, #VNET_PAGES
    bl plat_alloc_pages
    cbz x0, 9f
    stv x0, vnet_mem, x2
    stv x22, vnet_pci, x2
    mov x2, #1
    stv x2, vnet_found, x3
    mov x0, #0
    leave
5:
    cbnz x21, 6f
    ldrb w2, [x22, #14]         // header type: functions 1-7 only for
    tbz w2, #7, 7f              // multi-function devices
6:
    add x21, x21, #1
    b 3b
7:
    add x20, x20, #1
    b 2b
8:
    add x19, x19, #1
    b 1b
9:
    mov x0, #1
    leave

// x0 = PCI config address. Records the common, notify and device-specific
// configuration windows. Returns x0 = 0 when all three were found.
vnet_caps:
    enter
    mov x19, x0
    ldrh w2, [x19, #6]
    tbz w2, #4, 9f              // no capability list
    stv xzr, vnet_common, x2
    stv xzr, vnet_notify, x2
    stv xzr, vnet_device, x2
    ldrb w20, [x19, #0x34]
    mov x24, #48                // loop guard against a cyclic list
1:
    and x20, x20, #0xfc
    cbz x20, 4f
    subs x24, x24, #1
    b.eq 4f
    add x21, x19, x20
    ldrb w2, [x21]
    cmp w2, #0x09               // vendor-specific: virtio_pci_cap
    b.ne 3f
    ldrb w22, [x21, #3]         // cfg_type
    ldrb w0, [x21, #4]          // BAR
    bl vio_bar                  // reads the BAR of the device in x19
    cbz x0, 3f
    ldr w2, [x21, #8]           // offset within the BAR
    add x0, x0, x2
    cmp x22, #1
    b.ne 2f
    stv x0, vnet_common, x2
    b 3f
2:
    cmp x22, #2
    b.ne 21f
    stv x0, vnet_notify, x2
    ldr w2, [x21, #16]
    stv x2, vnet_notify_mul, x3
    b 3f
21:
    cmp x22, #4
    b.ne 3f
    ldr w2, [x21, #12]          // length: MAC and status need 8 bytes
    cmp w2, #8
    b.lo 3f
    stv x0, vnet_device, x2
3:
    ldrb w20, [x21, #1]
    b 1b
4:
    ldv x2, vnet_common
    cbz x2, 9f
    ldv x2, vnet_notify
    cbz x2, 9f
    ldv x2, vnet_device
    cbz x2, 9f
    mov x0, #0
    leave
9:
    mov x0, #1
    leave

// Returns x0 = cntvct deadline x0 milliseconds from now.
vnet_deadline:
    mrs x1, cntfrq_el0
    mul x1, x1, x0
    mov x2, #1000
    udiv x1, x1, x2
    isb
    mrs x0, cntvct_el0
    add x0, x0, x1
    ret

// After ExitBootServices. Starts the device found by vnet_probe.
vnet_init:
    enter
    ldv x2, vnet_found
    cbz x2, 9f
    ldv x2, vnet_pci
    ldrh w3, [x2, #4]
    orr w3, w3, #6              // memory space + bus master (again: the
    strh w3, [x2, #4]           // firmware may have cleared them on exit)
    ldv x19, vnet_common
    ldv x20, vnet_mem
    dsb sy
    strb wzr, [x19, #20]        // device_status = reset
    mov x0, #100
    bl vnet_deadline
    mov x21, x0
1:
    ldrb w2, [x19, #20]
    cbz w2, 2f
    isb
    mrs x3, cntvct_el0
    cmp x3, x21
    b.hs 8f
    yield
    b 1b
2:
    mov w2, #3                  // ACKNOWLEDGE | DRIVER
    strb w2, [x19, #20]
    mov w2, #1
    str w2, [x19, #0]           // device_feature_select = 1
    ldr w3, [x19, #4]
    tbz w3, #0, 8f              // VIRTIO_F_VERSION_1 required
    str wzr, [x19, #0]
    ldr w22, [x19, #4]          // features 0-31
    mov w3, #(1 << VIRTIO_NET_F_MAC)
    orr w3, w3, #(1 << VIRTIO_NET_F_STATUS)
    and w22, w22, w3            // only MAC and STATUS of the low word;
    str wzr, [x19, #8]          // no merged buffers: a 12-byte header
    str w22, [x19, #12]
    str w2, [x19, #8]
    str w2, [x19, #12]          // VERSION_1 of the high word
    mov w2, #11                 // | FEATURES_OK
    strb w2, [x19, #20]
    ldrb w2, [x19, #20]
    tbz w2, #3, 8f
    stv x22, vnet_features, x2
    // Clear the rings and buffers.
    mov x0, x20
    mov x1, #(VNET_PAGES * 4096)
    bl fat_zero_bytes
    // Queue 0: receive.
    mov x0, #0
    add x1, x20, #VNET_RX_DESC
    bl vnet_queue
    cbz x0, 8f
    stv x0, vnet_rx_notify, x2
    // Queue 1: transmit.
    mov x0, #1
    add x1, x20, #VNET_TX_DESC
    bl vnet_queue
    cbz x0, 8f
    stv x0, vnet_tx_notify, x2
    // Every receive descriptor owns one buffer; all are posted.
    add x2, x20, #VNET_RX_DESC
    add x3, x20, #VNET_RX_BUF
    add x5, x20, #VNET_RX_AVAIL
    mov x4, #0
3:
    str x3, [x2]                // addr
    mov w6, #VNET_BUF
    str w6, [x2, #8]            // len
    mov w6, #2                  // WRITE: the device fills it
    strh w6, [x2, #12]
    strh wzr, [x2, #14]
    add x7, x5, #4
    strh w4, [x7, x4, lsl #1]   // avail.ring[i] = i
    add x2, x2, #16
    add x3, x3, #VNET_BUF
    add x4, x4, #1
    cmp x4, #VNET_QSIZE
    b.lo 3b
    dmb sy
    mov w6, #VNET_QSIZE
    strh w6, [x5, #2]           // avail.idx
    stv xzr, vnet_rx_seen, x2
    mov w6, #1                  // VIRTQ_AVAIL_F_NO_INTERRUPT: we poll
    strh w6, [x5]
    add x6, x20, #VNET_TX_AVAIL
    mov w7, #1
    strh w7, [x6]
    stv xzr, vnet_tx_next, x2
    // The MAC address: from the device, or a locally administered one.
    bl vnet_read_mac
    mov w2, #15                 // | DRIVER_OK
    strb w2, [x19, #20]
    dsb sy
    ldv x2, vnet_rx_notify
    strh wzr, [x2]              // receive buffers are available
    mov x2, #3                  // own address and broadcast
    stv x2, vnet_mode, x3
    address x2, vnet_stats
    stp xzr, xzr, [x2]
    str xzr, [x2, #16]
    mov x2, #1
    stv x2, vnet_present, x3
    mov x0, #0
    leave
8:
    mov w2, #0x80               // FAILED
    strb w2, [x19, #20]
9:
    mov x0, #1
    leave

// x0 = queue index, x1 = its ring area (descriptors; avail at +256, used at
// +512). x19 = common config. Returns x0 = the queue's notify address, or 0.
vnet_queue:
    strh w0, [x19, #22]         // queue_select
    ldrh w2, [x19, #24]         // queue_size: the device's maximum
    cmp w2, #VNET_QSIZE
    b.lo 9f
    mov w2, #VNET_QSIZE
    strh w2, [x19, #24]
    // 64-bit fields as two 32-bit writes: the transport only promises
    // 32-bit accesses.
    str w1, [x19, #32]          // queue_desc
    lsr x2, x1, #32
    str w2, [x19, #36]
    add x2, x1, #0x100
    str w2, [x19, #40]          // queue_driver (avail)
    lsr x2, x2, #32
    str w2, [x19, #44]
    add x2, x1, #0x200
    str w2, [x19, #48]          // queue_device (used)
    lsr x2, x2, #32
    str w2, [x19, #52]
    ldrh w2, [x19, #30]         // queue_notify_off
    ldv x3, vnet_notify_mul
    mul x2, x2, x3
    ldv x3, vnet_notify
    add x0, x2, x3
    mov w2, #1
    strh w2, [x19, #28]         // queue_enable
    ret
9:
    mov x0, #0
    ret

// Copies the MAC from device config (stable across config_generation),
// or makes up a locally administered one if the device offers none or
// never gives a stable read.
vnet_read_mac:
    address x9, vnet_mac
    ldv x10, vnet_features
    tbz x10, #VIRTIO_NET_F_MAC, 3f
    ldv x11, vnet_device
    mov x12, #4                 // attempts
1:
    ldrb w13, [x19, #21]        // config_generation
    mov x2, #0
2:
    ldrb w3, [x11, x2]
    strb w3, [x9, x2]
    add x2, x2, #1
    cmp x2, #6
    b.lo 2b
    ldrb w14, [x19, #21]
    cmp w13, w14
    b.ne 5f
    ret
5:
    subs x12, x12, #1
    b.ne 1b                     // never stable: fall back, no torn MAC
3:
    isb
    mrs x2, cntvct_el0
    mov w3, #0x02               // locally administered, unicast
    strb w3, [x9]
    strb wzr, [x9, #1]
    str w2, [x9, #2]
    ret

// Link state: x0 = 1 up, 0 down (always up without VIRTIO_NET_F_STATUS).
vnet_link:
    mov x0, #1
    ldv x1, vnet_features
    tbz x1, #VIRTIO_NET_F_STATUS, 1f
    ldv x1, vnet_device
    ldrh w0, [x1, #6]
    and x0, x0, #1
1:
    ret

// ---------------------------------------------------------------------------
// E1h: packet driver services. x0 = subfunction (ABI.md).
net_services:
    ldv x9, vnet_present
    cbz x9, net_no_driver
    cbz x0, net_info
    cmp x0, #1
    b.eq net_get_mac
    cmp x0, #2
    b.eq net_send
    cmp x0, #3
    b.eq net_receive
    cmp x0, #4
    b.eq net_mode
    cmp x0, #5
    b.eq net_statistics
    mov x0, #1                  // bad subfunction
    mov x1, #1
    ret
net_no_driver:
    mov x0, #VNET_ERR_NONET
    mov x1, #1
    ret
net_bad_parameter:
    mov x0, #VNET_ERR_PARAM
    mov x1, #1
    ret
net_device_error:
    mov x0, #VNET_ERR_DEVICE
    mov x1, #1
    ret

net_info:
    frame
    bl vnet_link
    mov x2, #1500               // MTU
    mov x3, #1                  // class 1: Ethernet (DIX), as in the
    ldv x4, vnet_mode           // packet driver specification
    mov x1, #0
    unframe

net_get_mac:
    cbz x1, net_bad_parameter
    address x9, vnet_mac
    mov x2, #0
1:
    ldrb w3, [x9, x2]
    strb w3, [x1, x2]
    add x2, x2, #1
    cmp x2, #6
    b.lo 1b
    mov x0, #6
    mov x1, #0
    ret

// Waits (bounded) until the device has consumed every transmit request.
// Returns x0 = 0, or 1 on timeout. Clobbers x0-x7.
vnet_tx_drain:
    frame
    mov x0, #200
    bl vnet_deadline
    mov x6, x0
    ldv x4, vnet_mem
    add x4, x4, #VNET_TX_USED
    ldv x5, vnet_tx_next
1:
    ldrh w2, [x4, #2]           // used.idx
    cmp w2, w5, uxth
    b.eq 2f
    isb
    mrs x3, cntvct_el0
    cmp x3, x6
    b.hs 3f
    yield
    b 1b
2:
    dmb sy
    mov x0, #0
    unframe
3:
    mov x0, #1
    unframe

// x1 = frame (Ethernet header first), x2 = length 14-1514.
net_send:
    cbz x1, net_bad_parameter
    cmp x2, #VNET_MIN_FRAME
    b.lo net_bad_parameter
    cmp x2, #VNET_MAX_FRAME
    b.hi net_bad_parameter
    frame
    stp x1, x2, [sp, #-16]!
    bl vnet_tx_drain            // the single buffer must be free
    ldp x1, x2, [sp], #16
    cbnz x0, 9f
    ldv x9, vnet_mem
    add x10, x9, #VNET_TX_BUF
    stp xzr, xzr, [x10]         // virtio_net_hdr: no offloads
    add x11, x10, #VNET_HDR
    mov x3, #0
1:
    ldrb w4, [x1, x3]
    strb w4, [x11, x3]
    add x3, x3, #1
    cmp x3, x2
    b.lo 1b
    mov x5, x2
2:
    cmp x5, #60                 // pad runts to the Ethernet minimum
    b.hs 3f
    strb wzr, [x11, x5]
    add x5, x5, #1
    b 2b
3:
    add x12, x9, #VNET_TX_DESC  // descriptor 0, always
    str x10, [x12]
    add w5, w5, #VNET_HDR
    str w5, [x12, #8]
    str wzr, [x12, #12]         // flags 0, next 0
    add x12, x9, #VNET_TX_AVAIL
    ldv x13, vnet_tx_next
    and x14, x13, #(VNET_QSIZE - 1)
    add x15, x12, #4
    strh wzr, [x15, x14, lsl #1]
    add x13, x13, #1
    and x13, x13, #0xffff
    stv x13, vnet_tx_next, x14
    dmb sy
    strh w13, [x12, #2]         // avail.idx
    dsb sy
    ldv x14, vnet_tx_notify
    mov w15, #1
    strh w15, [x14]             // notify queue 1
    str x2, [sp, #-16]!
    bl vnet_tx_drain
    ldr x2, [sp], #16
    cbnz x0, 9f
    address x9, vnet_stats
    ldr x10, [x9, #8]
    add x10, x10, #1
    str x10, [x9, #8]
    mov x0, x2
    mov x1, #0
    unframe
9:
    mov x0, #VNET_ERR_DEVICE
    mov x1, #1
    unframe

// x1 = buffer, x2 = capacity. Non-blocking: x0 = bytes stored (0 when no
// frame is waiting), x2 = the frame's full length.
net_receive:
    cbz x1, net_bad_parameter
    cbz x2, net_bad_parameter
    ldv x9, vnet_mem
    mov x17, #(2 * VNET_QSIZE)  // at most this many frames inspected
1:
    add x10, x9, #VNET_RX_USED
    ldv x11, vnet_rx_seen
    ldrh w12, [x10, #2]         // used.idx
    cmp w12, w11, uxth
    b.eq 8f
    dmb sy
    and x12, x11, #(VNET_QSIZE - 1)
    add x13, x10, #4
    add x13, x13, x12, lsl #3
    ldr w14, [x13]              // used element: id
    ldr w15, [x13, #4]          //               length written
    add x11, x11, #1
    and x11, x11, #0xffff
    stv x11, vnet_rx_seen, x12
    cmp w14, #VNET_QSIZE        // a bad id cannot be re-posted: drop the
    b.hs 7f                     // device rather than corrupt memory
    sub x15, x15, #VNET_HDR
    mov x16, #0                 // bytes delivered
    cmp x15, #VNET_MIN_FRAME
    b.lt 5f
    cmp x15, #VNET_MAX_FRAME
    b.gt 5f
    // Receive filter on the destination address.
    add x3, x9, #VNET_RX_BUF
    add x3, x3, x14, lsl #11
    add x3, x3, #VNET_HDR       // the frame
    ldv x4, vnet_mode
    cmp x4, #6
    b.eq 4f                     // promiscuous
    cmp x4, #1
    b.eq 5f                     // receiver off
    ldrb w5, [x3]
    tbz w5, #0, 3f              // unicast
    cmp x4, #4                  // multicast modes take every group address
    b.hs 4f
    cmp x4, #3
    b.lo 5f
    ldr w5, [x3]                // broadcast?
    ldrh w6, [x3, #4]
    mov w7, #0xffff
    cmp w6, w7
    b.ne 5f
    cmn w5, #1
    b.ne 5f
    b 4f
3:
    address x5, vnet_mac
    ldr w6, [x3]
    ldr w7, [x5]
    cmp w6, w7
    b.ne 5f
    ldrh w6, [x3, #4]
    ldrh w7, [x5, #4]
    cmp w6, w7
    b.ne 5f
4:
    cmp x15, x2
    csel x16, x15, x2, lo       // truncate to the capacity
    mov x5, #0
41:
    cmp x5, x16
    b.hs 42f
    ldrb w6, [x3, x5]
    strb w6, [x1, x5]
    add x5, x5, #1
    b 41b
42:
    mov x4, #1                  // delivered
    b 6f
5:
    mov x4, #0                  // filtered out or malformed
6:
    // Re-post the buffer.
    add x5, x9, #VNET_RX_AVAIL
    ldrh w6, [x5, #2]
    and x7, x6, #(VNET_QSIZE - 1)
    add x8, x5, #4
    strh w14, [x8, x7, lsl #1]
    dmb sy
    add w6, w6, #1
    strh w6, [x5, #2]
    dsb sy
    ldv x5, vnet_rx_notify
    strh wzr, [x5]
    address x5, vnet_stats
    cbz x4, 61f
    ldr x6, [x5]
    add x6, x6, #1
    str x6, [x5]
    mov x0, x16
    mov x2, x15
    mov x1, #0
    ret
61:
    ldr x6, [x5, #16]
    add x6, x6, #1
    str x6, [x5, #16]
    subs x17, x17, #1
    b.ne 1b
8:
    mov x0, #0
    mov x2, #0
    mov x1, #0
    ret
7:
    stv xzr, vnet_present, x2   // the device broke the queue protocol
    b net_device_error

// x1 = 0 to query, or the receive mode 1-6. x0 = mode in effect, x2 = the
// previous mode.
net_mode:
    ldv x2, vnet_mode
    cbz x1, 1f
    cmp x1, #6
    b.hi net_bad_parameter
    stv x1, vnet_mode, x3
1:
    ldv x0, vnet_mode
    mov x1, #0
    ret

net_statistics:
    address x9, vnet_stats
    ldr x0, [x9]                // frames received (delivered)
    ldr x2, [x9, #8]            // frames sent
    ldr x3, [x9, #16]           // frames dropped by the filter or malformed
    mov x1, #0
    ret

.section .bss
.balign 8
vnet_found: .skip 8
vnet_present: .skip 8
vnet_pci: .skip 8
vnet_common: .skip 8
vnet_notify: .skip 8
vnet_notify_mul: .skip 8
vnet_device: .skip 8
vnet_mem: .skip 8
vnet_features: .skip 8
vnet_rx_notify: .skip 8
vnet_tx_notify: .skip 8
vnet_rx_seen: .skip 8           // used.idx consumed so far (16-bit)
vnet_tx_next: .skip 8           // avail.idx published so far (16-bit)
vnet_mode: .skip 8
vnet_mac: .skip 8
vnet_stats: .skip 24
