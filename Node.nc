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

module Node {
    uses interface Boot;
    uses interface SplitControl as AMControl;
    uses interface Receive;
    uses interface CommandHandler;
    uses interface Flooding;
    uses interface NeighborDiscovery as NeighborDiscovery;
}

implementation {

    event void Boot.booted() {
        call AMControl.start();
        dbg(GENERAL_CHANNEL, "Booted\n");
        call NeighborDiscovery.start();
    }

    event void AMControl.startDone(error_t err) {
        if(err == SUCCESS) {
            dbg(GENERAL_CHANNEL, "Radio On\n");
        }else{
            //Retry until successful
            call AMControl.start();
        }
    }

    event void AMControl.stopDone(error_t err) {}

    event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len) {
        pack* myMsg = (pack*) payload;
        if(len!=sizeof(pack)) {
                dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
        } else if(myMsg->dest == 0) {
            call NeighborDiscovery.handleNeighbor(myMsg);
        } else {
            call Flooding.handleFlooding(myMsg);
        }
        return msg;
    }

    event void CommandHandler.ping(uint16_t destination, uint8_t *payload) {
        call Flooding.ping(destination, payload);
    }

    event void CommandHandler.printNeighbors() {
        call NeighborDiscovery.printNeighbors();
    }

    event void CommandHandler.printRouteTable() {}

    event void CommandHandler.printLinkState() {}

    event void CommandHandler.printDistanceVector() {}

    event void CommandHandler.setTestServer() {}

    event void CommandHandler.setTestClient() {}

    event void CommandHandler.setAppServer() {}

    event void CommandHandler.setAppClient() {}

}
