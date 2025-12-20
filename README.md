# Zig TCP Proxy

Simple multithreaded TCP proxy server written in Zig.

## Features
- Uses `epoll` to efficiently forward data in both directions (client <-> destination)
- Prints connection and forwarding events to the console
- Monitors for specific keywords in the data stream and drops the connection if a keyword is detected

## Usage

1. **Build the proxy:**
   ```sh
   zig build
   ```

2. **Run the proxy:**
   ```sh
   zig build run
   ```
   The server will listen on `127.0.0.1:8080` and forward to `127.0.0.1:8081`.

3. **Test the proxy:**
   - Start a TCP server on port 8081 (e.g., with `nc -l 8081`)
   - Connect a client to the proxy (e.g., with `nc 127.0.0.1 8080`)
   - Data sent by the client will be forwarded to the destination, and vice versa.
   - If a monitored keyword is detected in the data, the proxy will immediately drop the connection.

## Requirements
- Zig 0.14.0 or newer
- Linux (uses POSIX sockets and epoll)

## License
MIT
