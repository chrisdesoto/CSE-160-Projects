#include <Timer.h>
#include "../../includes/CommandMsg.h"
#include "../../includes/command.h"
#include "../../includes/channels.h"
#include "../../includes/socket.h"
#include "../../includes/tcp.h"
#include "../../includes/packet.h"
#include "../../includes/protocol.h"

module TransportAppP{
    provides interface TransportApp;

    uses interface SimpleSend as Sender;
    uses interface Random;
    uses interface Timer<TMilli> as AppTimer;
    uses interface Transport;
}

implementation{

    typedef struct server_t {
        uint8_t sockfd;
        uint8_t conns[MAX_NUM_OF_SOCKETS-1];
        uint8_t numConns;
        uint8_t buffer[1024];
        uint16_t bytesRead;
        uint16_t bytesWritten;
    } server_t;

    typedef struct client_t {
        uint8_t sockfd;
        uint16_t bytesWritten;
        uint16_t bytesTransferred;
        uint16_t counter;
        uint16_t transfer;
        uint8_t buffer[1024];
    } client_t;

    server_t server;
    client_t client;

    void handleServer();
    void handleClient();

    command void TransportApp.startServer(uint8_t port) {
        socket_addr_t addr;
        server.sockfd = call Transport.socket();
        if(server.sockfd > 0) {
            addr.addr = TOS_NODE_ID;
            addr.port = port;
            if(call Transport.bind(server.sockfd, &addr) == SUCCESS && !(call AppTimer.isRunning())) {
                server.bytesRead = 0;
                server.bytesWritten = 0;                
                call Transport.listen(server.sockfd);
                call AppTimer.startPeriodic(1024 + (uint16_t) (call Random.rand16()%1000));
            }
        }
    }

    command void TransportApp.startClient(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transfer) {
        socket_addr_t clientAddr;
        socket_addr_t serverAddr;
        clientAddr.addr = TOS_NODE_ID;
        clientAddr.port = srcPort;
        serverAddr.addr = dest;
        serverAddr.port = destPort;
        client.sockfd = call Transport.socket();
        if(client.sockfd == 0) {
            dbg(TRANSPORT_CHANNEL, "No available sockets. Exiting!");
            return;
        }
        if(call Transport.bind(client.sockfd, &clientAddr) == FAIL) {
            dbg(TRANSPORT_CHANNEL, "Failed to bind sockets. Exiting!");
            return;
        }
        if(call Transport.connect(client.sockfd, &serverAddr) == FAIL) {
            dbg(TRANSPORT_CHANNEL, "Failed to connect to server. Exiting!");
            return;
        }
        client.transfer = transfer;
        client.counter = 0;
        client.bytesWritten = 0;
        client.bytesTransferred = 0;
        if(!(call AppTimer.isRunning())) {
            call AppTimer.startPeriodic(5000 + (uint16_t) (call Random.rand16()%1000));
        }
    }

    command void TransportApp.closeClient(uint8_t srcPort, uint8_t destPort, uint8_t dest) {

    }

    event void AppTimer.fired() {
        handleServer();
        handleClient();
    }

    void handleServer() {
        uint8_t i, counter = 10, bytes = 0;
        uint8_t newFd = call Transport.accept(server.sockfd);
        uint16_t data, length;
        bool isRead = FALSE;
        if(newFd > 0) {
            if(server.numConns < MAX_NUM_OF_SOCKETS-1) {
                server.conns[server.numConns++] = newFd;
            }
        }
        /*
        if(server.sockfd > 0) {
            dbg(TRANSPORT_CHANNEL, "ServerApp: bytesWritten %u\n", server.bytesWritten);
            dbg(TRANSPORT_CHANNEL, "ServerApp: bytesRead %u\n", server.bytesRead);
        }
        */
        for(i = 0; i < server.numConns; i++) {
            length = 10;
            if(server.conns[i] != 0) {
                if(length > (1024 - server.bytesWritten)) {
                    length = 1024 - server.bytesWritten;
                }
                bytes += call Transport.read(server.conns[i], &server.buffer[server.bytesWritten], length);
                server.bytesWritten += bytes;
                //dbg(TRANSPORT_CHANNEL, "ServerApp: bytes read from socket %u\n", bytes);
                if(server.bytesWritten == 1024) {
                    dbg(TRANSPORT_CHANNEL, "ServerApp wrapping\n");
                    server.bytesWritten = 0;
                }
            }
        }
        if(server.bytesWritten != server.bytesRead) {
            while((((uint16_t)(server.bytesWritten - server.bytesRead)) >= 2) && ((1024 - server.bytesRead) >= 2)) {
                if(!isRead) {
                    dbg(TRANSPORT_CHANNEL, "Reading Data:");
                    isRead = TRUE;
                }
                //printf("|%u|", server.bytesRead);
                data = (((uint16_t)server.buffer[server.bytesRead+1]) << 8) | (uint16_t)server.buffer[server.bytesRead];
                printf("%u,", data);
                server.bytesRead += 2;
                if(server.bytesRead == 1024) {
                    server.bytesRead = 0;
                    break;
                }
            }
            if(isRead)
                printf("\n");
        }
    }

    void handleClient() {
        uint8_t counter = 10;
        uint16_t bytes = 0, bytesToTransfer;
        if(client.sockfd == 0)
            return;
        /*
        // Write data
        if(client.bytesTransferred < client.transfer) {
            //memcpy(client.buffer, (uint8_t* ) &client.bytesTransferred, 2);
            client.buffer[0] = client.bytesTransferred & 0xFF;
            client.buffer[1] = client.bytesTransferred >> 8;
            while(bytes < 2 && (counter > 0 || bytes == 1)) {
                //dbg(TRANSPORT_CHANNEL, "Attempting to write\n");
                bytes += call Transport.write(client.sockfd, client.buffer, 2);
                if(counter > 0)
                    counter--;
            }
            if(bytes == 2) {
                client.bytesTransferred++;
            }
        }*/
        if(client.bytesWritten < client.bytesTransferred) {
            bytesToTransfer = 1024 - client.bytesTransferred;
        } else {
            bytesToTransfer = client.bytesWritten - client.bytesTransferred;
        }
        /*
        dbg(TRANSPORT_CHANNEL, "bytesWritten %u\n", client.bytesWritten);
        dbg(TRANSPORT_CHANNEL, "bytesTransferred %u\n", client.bytesTransferred);
        dbg(TRANSPORT_CHANNEL, "bytesToTransfer %u\n", bytesToTransfer);
        */
        // Writing to buffer
        while(/*client.bytesWritten < (uint16_t)(client.bytesTransferred-1) && */client.counter < client.transfer) {
            if((client.bytesWritten & 1) == 0) {
                client.buffer[client.bytesWritten] = client.counter & 0xFF;
            } else {
                client.buffer[client.bytesWritten] = client.counter >> 8;
                client.counter++;
                dbg(TRANSPORT_CHANNEL, "Client writing data: %u\n", (uint16_t)client.buffer[client.bytesWritten] << 8 | (uint16_t)client.buffer[client.bytesWritten-1]);
            }
            client.bytesWritten++;
            if(client.bytesWritten == 1024 && ((1024 - client.bytesWritten) + client.bytesTransferred) > 0) {
                client.bytesWritten = 0;
            }
        }
        // Writing to socket
        if(client.bytesTransferred != client.bytesWritten) {
            bytes += call Transport.write(client.sockfd, &client.buffer[client.bytesTransferred], bytesToTransfer);
            client.bytesTransferred += bytes;
            //dbg(TRANSPORT_CHANNEL, "transferred %u bytes\n", bytes);
        }
        if(client.bytesTransferred == 1024)
            client.bytesTransferred = 0;
    }

}