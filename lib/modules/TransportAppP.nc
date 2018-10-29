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

    typedef struct server_store_t {
        uint8_t socket;
        uint8_t conns[MAX_NUM_OF_SOCKETS-1];
    }

    typedef struct client_store_t {
        uint8_t socket;
        uint16_t transfer;
        uint16_t* buffer;
    }

    server_store_t server;
    client_store_t client;

    command void TransportApp.startServer(uint8_t port) {
        socket_addr_t addr;
        if(server.socket != 0)
            return;
        server.socket = call Transport.socket();
        if(server.socket != 0) {
            addr.addr = TOS_NODE_ID;
            addr.port = port;
            if(call Transport.bind(server.socket, addr) == SUCCESS) {
                AppTimer.startPeriodic(2048);
            }
        }
    }

    command void TransportApp.startClient(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transfer) {

    }

    command void TransportApp.closeClient(uint8_t srcPort, uint8_t destPort, uint8_t dest) {

    }

    event void AppTimer.fired() {
        uint8_t i, newFd = call Transport.accept(server.socket);
        if(newFd > 0) {
            addConnection(uint8_t newFd);
        }
        for(i = 0; i < MAX_NUM_OF_SOCKETS-1; i++) {
            // Read and print
        }
    }

}