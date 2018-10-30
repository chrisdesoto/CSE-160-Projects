/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date    2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/protocol.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"
#include "includes/socket.h"

module Node {
    uses interface Boot;
    uses interface SplitControl as AMControl;
    uses interface Receive;
    uses interface Transport;
    uses interface TransportApp;
    uses interface CommandHandler;
    uses interface Flooding;
    uses interface NeighborDiscovery as NeighborDiscovery;
    uses interface DistanceVectorRouting as DistanceVectorRouting;
    uses interface LinkStateRouting as LinkStateRouting;
}

implementation {

    event void Boot.booted() {
        call AMControl.start();
        dbg(GENERAL_CHANNEL, "Booted\n");
        call NeighborDiscovery.start();
        call DistanceVectorRouting.start();
        call Transport.start();
        //call LinkStateRouting.start();
    }

    event void AMControl.startDone(error_t err) {
        if(err == SUCCESS) {
            dbg(GENERAL_CHANNEL, "Radio On\n");
        } else {
            //Retry until successful
            call AMControl.start();
        }
    }

    event void AMControl.stopDone(error_t err) {}

    event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
        pack* myMsg = (pack*) payload;
        if(len!=sizeof(pack)) {
            dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
        } else if(myMsg->protocol == PROTOCOL_LS) {
            call LinkStateRouting.handleLS(myMsg);
        } else if(myMsg->protocol == PROTOCOL_DV) {
            call DistanceVectorRouting.handleDV(myMsg);
        } else if(myMsg->dest == 0) {
            call NeighborDiscovery.handleNeighbor(myMsg);
        } else {
            //call LinkStateRouting.routePacket(myMsg);
            call DistanceVectorRouting.routePacket(myMsg);
            //call Flooding.handleFlooding(myMsg);
        }
        return msg;
    }

    event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
        //call LinkStateRouting.ping(destination, payload);
        call DistanceVectorRouting.ping(destination, payload);
        //call Flooding.ping(destination, payload);
    }

    event void CommandHandler.printNeighbors() {
        call NeighborDiscovery.printNeighbors();
    }

    event void CommandHandler.printRouteTable() {
        call DistanceVectorRouting.printRouteTable();
    }

    event void CommandHandler.printLinkState() {
        call LinkStateRouting.printRouteTable();
    }

    event void CommandHandler.printDistanceVector() {}

    event void CommandHandler.printMessage(uint8_t *payload) {
        //dbg(GENERAL_CHANNEL, "%s\n", payload);
    }

    event void CommandHandler.setTestServer(uint8_t port) {
        /*
        socket_addr_t src;        
        uint8_t fd = call Transport.socket();
        src.addr = TOS_NODE_ID;
        src.port = port;
        call Transport.bind(fd, &src);
        call Transport.listen(fd);
        */
        call TransportApp.startServer(port);
        dbg(TRANSPORT_CHANNEL, "Node %u listening on port %u\n", TOS_NODE_ID, port);
    }

    event void CommandHandler.setTestClient(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transfer) {
        /*
        socket_addr_t srcAddr;
        socket_addr_t destAddr;
        uint8_t fd;
        srcAddr.addr = TOS_NODE_ID;
        srcAddr.port = srcPort;
        destAddr.addr = dest;
        destAddr.port = destPort;        
        fd = call Transport.socket();
        call Transport.bind(fd, &srcAddr);
        call Transport.connect(fd, &destAddr);
        */
        call TransportApp.startClient(dest, srcPort, destPort, transfer);
        dbg(TRANSPORT_CHANNEL, "Node %u creating connection from port %u to port %u on node %u. Transferring bytes: %u\n", TOS_NODE_ID, srcPort, dest, destPort, transfer);
    }

    event void CommandHandler.setClientClose(uint8_t dest, uint8_t srcPort, uint8_t destPort) {}

    event void CommandHandler.setAppServer() {}

    event void CommandHandler.setAppClient() {}

}
