# Zig TCP Proxy

This project is a simple multithreaded TCP proxy server written in Zig. It listens for incoming TCP connections on a specified port, then forwards all traffic between the client and a destination server. The proxy uses efficient polling to relay data in both directions.

## Features
- Listens on `127.0.0.1:8080` by default
- Forwards all traffic to `127.0.0.1:8081`
- Handles each client connection in a separate thread
- Uses `poll` to efficiently forward data in both directions (client <-> destination)
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

## How it works
- The main loop accepts incoming connections and spawns a thread for each client.
- Each thread opens a connection to the destination server.
- The thread uses `poll` to wait for data on either the client or destination socket.
- When data is available, it is read from one socket and written to the other.
- The proxy inspects the data for specific keywords and drops the connection if a match is found.
- The connection is closed when either side disconnects or a keyword is detected.

## Requirements
- Zig 0.14.0 or newer
- Linux (uses POSIX sockets and poll)

## License
MIT
