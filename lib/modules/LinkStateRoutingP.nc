#include <Timer.h>
#include "../../includes/channels.h"
#include "../../includes/packet.h"
#include "../../includes/protocol.h"
#include "../../includes/ls_protocol.h"

module LinkStateRoutingP {
    provides interface LinkStateRouting;
    
    uses interface SimpleSend as Sender;
    uses interface MapList<uint16_t, uint16_t> as PacketsReceived;
    uses interface NeighborDiscovery as NeighborDiscovery;
    uses interface Flooding as Flooding;
    uses interface Timer<TMilli> as LSRTimer;
    uses interface Random as Random;
}

implementation {

    typedef struct {
        uint8_t dest;
        uint8_t nextHop;
        uint8_t cost;
    } Route;

    typedef struct {
        uint8_t neighbor;
        uint8_t cost;
    } LSP;

    uint8_t neighborState[LS_MAX_ROUTES][LS_MAX_ROUTES];
    uint16_t numRoutes = 0;
    Route routingTable[LS_MAX_ROUTES];
    uint16_t sequenceNum = 0;
    pack routePack;

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, void* payload, uint8_t length);
    void initilizeRoutingTable();
    bool updateState(pack* myMsg);
    void sendLSP();
    void handleForward(pack* myMsg);
    void djikstra();

    command error_t LinkStateRouting.start() {
        // Initialize routing table and neighbor state structures
        // Start one-shot
        initilizeRoutingTable();
        call LSRTimer.startOneShot(40000);
        dbg(ROUTING_CHANNEL, "Link State Routing Started on node %u!\n", TOS_NODE_ID);
   }

    event void LSRTimer.fired() {
        if(call LSRTimer.isOneShot()) {
            call LSRTimer.startPeriodic(30000 + (uint16_t) (call Random.rand16()%5000));
        } else {
            // Send flooding packet w/neighbor list
            sendLSP();
        }
    }

    command void LinkStateRouting.routePacket(pack* myMsg) {
        // Look up value in table and forward
        uint8_t nextHop;
        if(myMsg->dest == TOS_NODE_ID && myMsg->protocol == PROTOCOL_PING) {
            dbg(ROUTING_CHANNEL, "PING Packet has reached destination %d!!!\n", TOS_NODE_ID);
            makePack(&routePack, myMsg->dest, myMsg->src, 0, PROTOCOL_PINGREPLY, 0,(uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
            call LinkStateRouting.routePacket(&routePack);
            return;
        } else if(myMsg->dest == TOS_NODE_ID && myMsg->protocol == PROTOCOL_PINGREPLY) {
            dbg(ROUTING_CHANNEL, "PING_REPLY Packet has reached destination %d!!!\n", TOS_NODE_ID);
            return;
        }
        if((nextHop = routingTable[myMsg->dest].nextHop) < LS_MAX_COST) {
            dbg(ROUTING_CHANNEL, "Node %d routing packet through %d\n", TOS_NODE_ID, nextHop);
            logPack(myMsg);
            call Sender.send(*myMsg, nextHop);
        } else {
            dbg(ROUTING_CHANNEL, "No route to destination. Dropping packet...\n");
            logPack(myMsg);
        }
    }

    command void LinkStateRouting.handleLS(pack* myMsg) {
        // Check seq number
        if(call PacketsReceived.containsVal(myMsg->src, myMsg->seq)) {
            return;
        } else {
            call PacketsReceived.insertVal(myMsg->src, myMsg->seq);
        }
        // If state changed -> rerun djikstra
        if(updateState(myMsg)) {
            djikstra();
        }
        // Forward to all neighbors
        call Sender.send(*myMsg, AM_BROADCAST_ADDR);
    }

    command void LinkStateRouting.handleNeighborLost(uint16_t lostNeighbor) {
        neighborState[TOS_NODE_ID][lostNeighbor] = LS_MAX_COST;
        sendLSP();
        djikstra();
    }

    command void LinkStateRouting.handleNeighborFound() {
        uint32_t* neighbors = call NeighborDiscovery.getNeighbors();
        uint16_t neighborsListSize = call NeighborDiscovery.getNeighborListSize();
        uint8_t i = 0;
        for(i = 0; i < neighborsListSize; i++) {
            neighborState[TOS_NODE_ID][neighbors[i]] = 1;
        }
        sendLSP();
        djikstra();
    }

    command void LinkStateRouting.printRouteTable() {
        uint8_t i;
        dbg(ROUTING_CHANNEL, "DEST  HOP  COST\n");
        for(i = 0; i < numRoutes; i++) {
            dbg(ROUTING_CHANNEL, "%4d%5d%6d%5d\n", routingTable[i].dest, routingTable[i].nextHop, routingTable[i].cost);
        }
    }

    void initilizeRoutingTable() {
        uint8_t i, j;
        for(i = 0; i < LS_MAX_ROUTES; i++) {
            routingTable[i].dest = 0;
            routingTable[i].nextHop = 0;
            routingTable[i].cost = 0;
        }
        for(i = 0; i < LS_MAX_ROUTES; i++) {
            for(j = 0; j < LS_MAX_ROUTES; j++) {
                neighborState[i][j] = LS_MAX_COST;
            }
        }
        routingTable[TOS_NODE_ID].dest = TOS_NODE_ID;
        routingTable[TOS_NODE_ID].nextHop = TOS_NODE_ID;
        routingTable[TOS_NODE_ID].cost = 0;
        neighborState[TOS_NODE_ID][TOS_NODE_ID] = 0;
    }

    bool updateState(pack* myMsg) {
        uint8_t i, j;
        LSP *lsp = (LSP *)myMsg->payload;
        bool isStateUpdated = FALSE;
        for(i = 0; i < 10; i++) {
            if(neighborState[myMsg->src][lsp[i].neighbor] != lsp[i].cost) {
                neighborState[myMsg->src][lsp[i].neighbor] = lsp[i].cost;
                isStateUpdated = TRUE;
            }
        }
        return isStateUpdated;
    }

    void sendLSP() {
        uint32_t* neighbors = call NeighborDiscovery.getNeighbors();
        uint16_t neighborsListSize = call NeighborDiscovery.getNeighborListSize();
        uint8_t i = 0, j = 0, counter = 0;
        LSP linkStatePayload[10];
        // Zero out the array
        for(i = 0; i < 10; i++) {
            linkStatePayload[i].neighbor = 0;
            linkStatePayload[i].cost = 0;
        }
        // Add neighbors in groups of 10 and flood LSP to all neighbors
        for(i = 0; i < neighborsListSize; i++) {
            linkStatePayload[counter].neighbor = neighbors[i];
            linkStatePayload[counter].cost = 1;
            counter++;
            if(counter == 10 || i == neighborsListSize-1) {
                // Send LSP to each neighbor                
                makePack(&routePack, TOS_NODE_ID, neighbors[j], LS_TTL, PROTOCOL_LS, sequenceNum++, &linkStatePayload, sizeof(linkStatePayload));
                call Sender.send(routePack, AM_BROADCAST_ADDR);
                // Zero the array
                while(counter > 0) {
                    counter--;
                    linkStatePayload[i].neighbor = 0;
                    linkStatePayload[i].cost = 0;
                }
            }
        }
    }

    void djikstra() {
        
    }

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, void* payload, uint8_t length) {
        Package->src = src;
        Package->dest = dest;
        Package->TTL = TTL;
        Package->seq = seq;
        Package->protocol = protocol;
        memcpy(Package->payload, payload, length);
    }                            
}