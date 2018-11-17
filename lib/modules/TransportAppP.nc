#include <Timer.h>
#include "../../includes/CommandMsg.h"
#include "../../includes/command.h"
#include "../../includes/channels.h"
#include "../../includes/socket.h"
#include "../../includes/tcp.h"
#include "../../includes/packet.h"
#include "../../includes/protocol.h"

#define TCP_APP_BUFFER_SIZE 1024
#define TCP_APP_READ_SIZE 10

module TransportAppP{
    provides interface TransportApp;

    uses interface SimpleSend as Sender;
    uses interface Random;
    uses interface Timer<TMilli> as AppTimer;
    uses interface Transport;
    uses interface Hashmap<uint8_t> as ConnectionMap;
}

implementation{

    typedef struct server_t {
        uint8_t sockfd;
        uint8_t conns[MAX_NUM_OF_SOCKETS-1];
        uint8_t numConns;
        uint16_t bytesRead;
        uint16_t bytesWritten;
        uint8_t buffer[TCP_APP_BUFFER_SIZE];
    } server_t;

    typedef struct client_t {
        uint8_t sockfd;
        uint16_t bytesWritten;
        uint16_t bytesTransferred;
        uint16_t counter;
        uint16_t transfer;
        uint8_t buffer[TCP_APP_BUFFER_SIZE];
    } client_t;

    server_t server[MAX_NUM_OF_SOCKETS];
    client_t client[MAX_NUM_OF_SOCKETS];
    uint8_t numServers = 0;
    uint8_t numClients = 0;

    void handleServer();
    void handleClient();
    uint16_t getServerBufferOccupied(uint8_t idx);
    uint16_t getServerBufferAvailable(uint8_t idx);
    uint16_t getClientBufferOccupied(uint8_t idx);
    uint16_t getClientBufferAvailable(uint8_t idx);
    void zeroClient(uint8_t idx);
    void zeroServer(uint8_t idx);
    uint16_t min(uint16_t a, uint16_t b);

    command void TransportApp.startServer(uint8_t port) {
        uint8_t i;
        uint32_t connId;
        socket_addr_t addr;
        if(numServers >= MAX_NUM_OF_SOCKETS) {
            dbg(TRANSPORT_CHANNEL, "Cannot start server\n");
            return;
        }
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            // Skip occupied server structs
            if(server[i].sockfd != 0)
                continue;
            // Open a socket
            server[i].sockfd = call Transport.socket();
            if(server[i].sockfd > 0) {
                // Set up some structs
                addr.addr = TOS_NODE_ID;
                addr.port = port;
                // Bind the socket to the src address
                if(call Transport.bind(server[i].sockfd, &addr) == SUCCESS) {
                    // Add the bound socket index to the connection map
                    connId = ((uint32_t)addr.addr << 24) | ((uint32_t)addr.port << 16);
                    call ConnectionMap.insert(connId, i+1);
                    // Set up some state for the connection
                    server[i].bytesRead = 0;
                    server[i].bytesWritten = 0;
                    server[i].numConns = 0;
                    // Listen on the port and start a timer if needed
                    if(call Transport.listen(server[i].sockfd) == SUCCESS && !(call AppTimer.isRunning())) {
                        call AppTimer.startPeriodic(1024 + (uint16_t) (call Random.rand16()%1000));
                    }
                    numServers++;
                    return;
                }
            }
        }
    }

    command void TransportApp.startClient(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transfer) {
        uint8_t i;
        uint32_t connId;
        socket_addr_t clientAddr;
        socket_addr_t serverAddr;
        // Check if there is available space
        if(numClients >= MAX_NUM_OF_SOCKETS) {
            dbg(TRANSPORT_CHANNEL, "Cannot start client\n");
            return;
        }
        // Set up some structs
        clientAddr.addr = TOS_NODE_ID;
        clientAddr.port = srcPort;
        serverAddr.addr = dest;
        serverAddr.port = destPort;
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            // Skip occupied client structs
            if(client[i].sockfd != 0) {
                continue;
            }
            // Open a socket
            client[i].sockfd = call Transport.socket();
            if(client[i].sockfd == 0) {
                dbg(TRANSPORT_CHANNEL, "No available sockets. Exiting!");
                return;
            }
            // Bind the socket to the src address
            if(call Transport.bind(client[i].sockfd, &clientAddr) == FAIL) {
                dbg(TRANSPORT_CHANNEL, "Failed to bind sockets. Exiting!");
                return;
            }
            // Add the bound socket index to the connection map
            connId = ((uint32_t)TOS_NODE_ID << 24) | ((uint32_t)srcPort << 16);
            call ConnectionMap.insert(connId, i+1);
            // Connect to the remote server
            if(call Transport.connect(client[i].sockfd, &serverAddr) == FAIL) {
                dbg(TRANSPORT_CHANNEL, "Failed to connect to server. Exiting!");
                return;
            }
            // Remove the old connection and add the newly connected socket index
            call ConnectionMap.remove(connId);
            connId = ((uint32_t)TOS_NODE_ID << 24) | ((uint32_t)srcPort << 16) | ((uint32_t)dest << 16) | ((uint32_t)destPort << 16);
            call ConnectionMap.insert(connId, i+1);
            // Set up some state for the connection
            client[i].transfer = transfer;
            client[i].counter = 0;
            client[i].bytesWritten = 0;
            client[i].bytesTransferred = 0;
            // Start the timer if it isn't running
            if(!(call AppTimer.isRunning())) {
                call AppTimer.startPeriodic(1024 + (uint16_t) (call Random.rand16()%1000));
            }
            numClients++;
            return;
        }
    }

    command void TransportApp.closeClient(uint8_t srcPort, uint8_t destPort, uint8_t dest) {
        uint32_t sockIdx, connId;
        // Find the correct socket index
        connId = ((uint32_t)TOS_NODE_ID << 24) | ((uint32_t)srcPort << 16) | ((uint32_t)dest << 16) | ((uint32_t)destPort << 16);
        sockIdx = call ConnectionMap.get(connId);
        if(sockIdx == 0) {
            dbg(TRANSPORT_CHANNEL, "Client not found\n");
            return;
        }
        // Close the socket
        call Transport.close(client[sockIdx-1].sockfd);
        // Zero the client & decrement connections
        zeroClient(sockIdx-1);
        numClients--;
    }

    event void AppTimer.fired() {
        handleServer();
        handleClient();
    }

    void handleServer() {
        uint8_t i, j, bytes, newFd;
        uint16_t data, length;
        bool isRead = FALSE;
        bytes = 0;
        for(i = 0; i < numServers; i++) {
            if(server[i].sockfd == 0) {
                continue;
            }
            // Accept any new connections
            newFd = call Transport.accept(server[i].sockfd);
            if(newFd > 0) {
                if(server[i].numConns < MAX_NUM_OF_SOCKETS-1) {
                    server[i].conns[server[i].numConns++] = newFd;
                }
            }
            // Iterate over connections and read
            for(j = 0; j < server[i].numConns; j++) {
                if(server[i].conns[j] != 0) {
                    if(getServerBufferAvailable(i) > 0) {
                        length = min((TCP_APP_BUFFER_SIZE - server[i].bytesWritten), TCP_APP_READ_SIZE);
                        bytes += call Transport.read(server[i].conns[j], &server[i].buffer[server[i].bytesWritten], length);
                        server[i].bytesWritten += bytes;
                        if(server[i].bytesWritten == TCP_APP_BUFFER_SIZE) {
                            server[i].bytesWritten = 0;
                        }
                    }
                }
            }
            // Print out received data
            while(getServerBufferOccupied(i) >= 2) {
                if(!isRead) {
                    // dbg(TRANSPORT_CHANNEL, "Reading Data at %u: ", server[i].bytesRead);
                    isRead = TRUE;
                }
                if(server[i].bytesRead == TCP_APP_BUFFER_SIZE) {
                    server[i].bytesRead = 0;
                }
                data = (((uint16_t)server[i].buffer[server[i].bytesRead+1]) << 8) | (uint16_t)server[i].buffer[server[i].bytesRead];
                // printf("%u,", data);
                server[i].bytesRead += 2;
            }
            // if(isRead)
                // printf("\n");
        }
    }

    void handleClient() {        
        uint8_t i;
        uint16_t bytesTransferred, bytesToTransfer;
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if(client[i].sockfd == 0)
                continue;
            // Writing to buffer
            while(getClientBufferAvailable(i) > 0 && client[i].counter < client[i].transfer) {
                if(client[i].bytesWritten == TCP_APP_BUFFER_SIZE) {
                    client[i].bytesWritten = 0;
                }
                if((client[i].bytesWritten & 1) == 0) {
                    client[i].buffer[client[i].bytesWritten] = client[i].counter & 0xFF;
                } else {
                    client[i].buffer[client[i].bytesWritten] = client[i].counter >> 8;
                    client[i].counter++;
                }
                client[i].bytesWritten++;
            }
            // Writing to socket
            if(getClientBufferOccupied(i) > 0) {
                bytesToTransfer = min((TCP_APP_BUFFER_SIZE - client[i].bytesTransferred), (client[i].bytesWritten - client[i].bytesTransferred));
                bytesTransferred = call Transport.write(client[i].sockfd, &client[i].buffer[client[i].bytesTransferred], bytesToTransfer);
                client[i].bytesTransferred += bytesTransferred;
            }
            if(client[i].bytesTransferred == TCP_APP_BUFFER_SIZE)
                client[i].bytesTransferred = 0;
        }
    }

    void zeroClient(uint8_t idx) {
        client[idx].sockfd = 0;
        client[idx].bytesWritten = 0;
        client[idx].bytesTransferred = 0;
        client[idx].counter = 0;
        client[idx].transfer = 0;
    }

    void zeroServer(uint8_t idx) {
        uint8_t i;
        server[idx].sockfd = 0;
        server[idx].bytesRead = 0;
        server[idx].bytesWritten = 0;
        server[idx].numConns = 0;
        for(i = 0; i < MAX_NUM_OF_SOCKETS-1; i++) {
            server[idx].conns[i] = 0;
        }
    }

    uint16_t getServerBufferOccupied(uint8_t idx) {
        if(server[idx].bytesRead == server[idx].bytesWritten) {
            return 0;
        } else if(server[idx].bytesRead < server[idx].bytesWritten) {
            return server[idx].bytesWritten - server[idx].bytesRead;
        } else {
            return (TCP_APP_BUFFER_SIZE - server[idx].bytesRead) + server[idx].bytesWritten;
        }
    }

    uint16_t getServerBufferAvailable(uint8_t idx) {
        return TCP_APP_BUFFER_SIZE - getServerBufferOccupied(idx) - 1;
    }


    uint16_t getClientBufferOccupied(uint8_t idx) {
        if(client[idx].bytesTransferred == client[idx].bytesWritten) {
            return 0;
        } else if(client[idx].bytesTransferred < client[idx].bytesWritten) {
            return client[idx].bytesWritten - client[idx].bytesTransferred;
        } else {
            return (TCP_APP_BUFFER_SIZE - client[idx].bytesTransferred) + client[idx].bytesWritten;
        }
    }

    uint16_t getClientBufferAvailable(uint8_t idx) {
        return TCP_APP_BUFFER_SIZE - getClientBufferOccupied(idx) - 1;
    }

    uint16_t min(uint16_t a, uint16_t b) {
        if(a <= b)
            return a;
        else
            return b;
    }

}