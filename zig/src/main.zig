const std = @import("std");

// Native C structs and constants declared manually to bypass @cImport
const sockaddr = extern struct {
    sa_family: u16,
    sa_data: [14]u8,
};

const sockaddr_un = extern struct {
    sun_family: u16,
    sun_path: [108]u8,
};

const pollfd = extern struct {
    fd: c_int,
    events: i16,
    revents: i16,
};

const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;

const POLLIN: i16 = 0x0001;
const POLLERR: i16 = 0x0008;
const POLLHUP: i16 = 0x0010;

const MSG_PEEK: c_int = 2;
const MSG_DONTWAIT: c_int = 0x40;

extern fn socket(domain: c_int, socket_type: c_int, protocol: c_int) c_int;
extern fn bind(sockfd: c_int, addr: *const sockaddr, addrlen: u32) c_int;
extern fn listen(sockfd: c_int, backlog: c_int) c_int;
extern fn accept(sockfd: c_int, addr: ?*sockaddr, addrlen: ?*u32) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern fn close(fd: c_int) c_int;
extern fn unlink(pathname: [*:0]const u8) c_int;
extern fn poll(fds: [*]pollfd, nfds: usize, timeout: c_int) c_int;
extern fn recv(sockfd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
extern fn usleep(usec: c_uint) c_int;

pub fn main(init: std.process.Init) !void {
    _ = init;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const socket_path = "/tmp/jemach.sock";
    _ = unlink(socket_path);

    const server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) {
        std.debug.print("Failed to create socket\n", .{});
        return error.SocketCreationFailed;
    }
    defer _ = close(server_fd);

    var addr: sockaddr_un = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.sun_family = @intCast(AF_UNIX);

    const path_len = @min(socket_path.len, addr.sun_path.len - 1);
    @memcpy(addr.sun_path[0..path_len], socket_path[0..path_len]);
    addr.sun_path[path_len] = 0;

    const bind_res = bind(server_fd, @ptrCast(&addr), @sizeOf(sockaddr_un));
    if (bind_res < 0) {
        std.debug.print("Failed to bind socket\n", .{});
        return error.BindFailed;
    }

    if (listen(server_fd, 128) < 0) {
        std.debug.print("Failed to listen on socket\n", .{});
        return error.ListenFailed;
    }

    std.debug.print("jEMach Broker listening on {s} (using extern C sockets)\n", .{socket_path});

    var subscribers: std.ArrayList(c_int) = .empty;
    defer {
        for (subscribers.items) |sub_fd| {
            _ = close(sub_fd);
        }
        subscribers.deinit(allocator);
    }

    var cached_state: std.ArrayList(u8) = .empty;
    defer cached_state.deinit(allocator);

    var poll_fds: std.ArrayList(pollfd) = .empty;
    defer poll_fds.deinit(allocator);

    while (true) {
        poll_fds.clearRetainingCapacity();

        try poll_fds.append(allocator, .{
            .fd = server_fd,
            .events = POLLIN,
            .revents = 0,
        });

        for (subscribers.items) |sub_fd| {
            try poll_fds.append(allocator, .{
                .fd = sub_fd,
                .events = POLLIN,
                .revents = 0,
            });
        }

        const poll_num = poll(poll_fds.items.ptr, poll_fds.items.len, -1);
        if (poll_num < 0) {
            std.debug.print("Poll error\n", .{});
            _ = usleep(100 * 1000);
            continue;
        }

        if (poll_num == 0) continue;

        // Check for new connection on server socket
        if (poll_fds.items[0].revents & POLLIN != 0) {
            var client_addr: sockaddr = undefined;
            var client_addr_len: u32 = @sizeOf(sockaddr);
            const client_fd = accept(server_fd, &client_addr, &client_addr_len);
            if (client_fd < 0) {
                std.debug.print("Accept error\n", .{});
                continue;
            }

            var buffer: [1024]u8 = undefined;
            const bytes_read = read(client_fd, &buffer, buffer.len);
            if (bytes_read <= 0) {
                _ = close(client_fd);
                continue;
            }

            const header = buffer[0..@intCast(bytes_read)];
            if (std.mem.startsWith(u8, header, "SUB\n") or std.mem.startsWith(u8, header, "SUB\r\n")) {
                try subscribers.append(allocator, client_fd);
                std.debug.print("New subscriber registered (total: {d})\n", .{subscribers.items.len});

                if (cached_state.items.len > 0) {
                    _ = write(client_fd, cached_state.items.ptr, cached_state.items.len);
                }
            } else {
                var pub_payload: std.ArrayList(u8) = .empty;
                defer pub_payload.deinit(allocator);

                try pub_payload.appendSlice(allocator, header);

                while (true) {
                    var read_buf: [4096]u8 = undefined;
                    const n = read(client_fd, &read_buf, read_buf.len);
                    if (n <= 0) break;
                    try pub_payload.appendSlice(allocator, read_buf[0..@intCast(n)]);

                    if (pub_payload.items.len > 512 * 1024) {
                        std.debug.print("Publisher payload too large, dropping.\n", .{});
                        break;
                    }
                }
                _ = close(client_fd);

                if (pub_payload.items.len > 0) {
                    cached_state.clearRetainingCapacity();
                    try cached_state.appendSlice(allocator, pub_payload.items);

                    if (cached_state.items[cached_state.items.len - 1] != '\n') {
                        try cached_state.append(allocator, '\n');
                    }

                    var i: usize = 0;
                    while (i < subscribers.items.len) {
                        const sub_fd = subscribers.items[i];
                        const write_res = write(sub_fd, cached_state.items.ptr, cached_state.items.len);
                        if (write_res < 0) {
                            std.debug.print("Subscriber disconnected on write, removing.\n", .{});
                            _ = close(sub_fd);
                            _ = subscribers.swapRemove(i);
                            continue;
                        }
                        i += 1;
                    }
                }
            }
        }

        var i: usize = 0;
        while (i < subscribers.items.len) {
            const poll_idx = i + 1;
            const revents = poll_fds.items[poll_idx].revents;
            if (revents & (POLLHUP | POLLERR) != 0 or
                (revents & POLLIN != 0 and isSocketClosed(subscribers.items[i]))) {
                std.debug.print("Subscriber socket closed, removing (idx: {d})\n", .{i});
                _ = close(subscribers.items[i]);
                _ = subscribers.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }
}

fn isSocketClosed(fd: c_int) bool {
    var buf: [1]u8 = undefined;
    const rc = recv(fd, &buf, buf.len, MSG_PEEK | MSG_DONTWAIT);
    return rc == 0;
}
