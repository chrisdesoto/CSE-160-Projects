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
        uint8_t nextHop;
        uint8_t cost;
    } Route;

    typedef struct {
        uint8_t neighbor;
        uint8_t cost;
    } LSP;

    uint8_t linkState[LS_MAX_ROUTES][LS_MAX_ROUTES];
    Route routingTable[LS_MAX_ROUTES];
    uint16_t numKnownNodes = 0;
    uint16_t numRoutes = 0;
    uint16_t sequenceNum = 0;
    pack routePack;

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, void* payload, uint8_t length);
    void initilizeRoutingTable();
    bool updateState(pack* myMsg);
    bool updateRoute(uint8_t dest, uint8_t nextHop, uint8_t cost);
    void addRoute(uint8_t dest, uint8_t nextHop, uint8_t cost);
    void removeRoute(uint8_t dest);
    void sendLSP(uint8_t lostNeighbor);
    void handleForward(pack* myMsg);
    void djikstra();

    command error_t LinkStateRouting.start() {
        // Initialize routing table and neighbor state structures
        // Start one-shot
        dbg(ROUTING_CHANNEL, "Link State Routing Started on node %u!\n", TOS_NODE_ID);
        initilizeRoutingTable();
        call LSRTimer.startOneShot(40000);
   }

    event void LSRTimer.fired() {
        if(call LSRTimer.isOneShot()) {
            call LSRTimer.startPeriodic(30000 + (uint16_t) (call Random.rand16()%5000));
        } else {
            // Send flooding packet w/neighbor list
            sendLSP(0);
        }
    }

    command void LinkStateRouting.ping(uint16_t destination, uint8_t *payload) {
        makePack(&routePack, TOS_NODE_ID, destination, 0, PROTOCOL_PING, 0, payload, PACKET_MAX_PAYLOAD_SIZE);
        dbg(ROUTING_CHANNEL, "PING FROM %d TO %d\n", TOS_NODE_ID, destination);
        logPack(&routePack);
        call LinkStateRouting.routePacket(&routePack);
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
        if(routingTable[myMsg->dest].cost < LS_MAX_COST) {
            nextHop = routingTable[myMsg->dest].nextHop;
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
        if(myMsg->src == TOS_NODE_ID || call PacketsReceived.containsVal(myMsg->src, myMsg->seq)) {
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
        dbg(ROUTING_CHANNEL, "Neighbor lost %u\n", lostNeighbor);
        if(linkState[TOS_NODE_ID][lostNeighbor] != LS_MAX_COST) {
            linkState[TOS_NODE_ID][lostNeighbor] = LS_MAX_COST;
            linkState[lostNeighbor][TOS_NODE_ID] = LS_MAX_COST;
            numKnownNodes--;
            removeRoute(lostNeighbor);
        }
        sendLSP(lostNeighbor);
        djikstra();
    }

    command void LinkStateRouting.handleNeighborFound() {
        uint32_t* neighbors = call NeighborDiscovery.getNeighbors();
        uint16_t neighborsListSize = call NeighborDiscovery.getNeighborListSize();
        uint16_t i = 0;
        for(i = 0; i < neighborsListSize; i++) {
            linkState[TOS_NODE_ID][neighbors[i]] = 1;
            linkState[neighbors[i]][TOS_NODE_ID] = 1;
        }
        sendLSP(0);
        djikstra();
    }

    command void LinkStateRouting.printRouteTable() {
        uint16_t i;
        dbg(ROUTING_CHANNEL, "DEST  HOP  COST\n");
        for(i = 1; i < LS_MAX_ROUTES; i++) {
            if(routingTable[i].cost != LS_MAX_COST)
                dbg(ROUTING_CHANNEL, "%4d%5d%6d\n", i, routingTable[i].nextHop, routingTable[i].cost);
        }
    }

    void initilizeRoutingTable() {
        uint16_t i, j;
        for(i = 0; i < LS_MAX_ROUTES; i++) {
            routingTable[i].nextHop = 0;
            routingTable[i].cost = LS_MAX_COST;
        }
        for(i = 0; i < LS_MAX_ROUTES; i++) {
            linkState[i][0] = 0;
        }
        for(i = 0; i < LS_MAX_ROUTES; i++) {
            linkState[0][i] = 0;
        }
        for(i = 1; i < LS_MAX_ROUTES; i++) {
            for(j = 1; j < LS_MAX_ROUTES; j++) {
                linkState[i][j] = LS_MAX_COST;
            }
        }
        routingTable[TOS_NODE_ID].nextHop = TOS_NODE_ID;
        routingTable[TOS_NODE_ID].cost = 0;
        linkState[TOS_NODE_ID][TOS_NODE_ID] = 0;
        numKnownNodes++;
        numRoutes++;
    }

    bool updateState(pack* myMsg) {
        uint16_t i, j;
        LSP *lsp = (LSP *)myMsg->payload;
        bool isStateUpdated = FALSE;
        for(i = 0; i < 10; i++) {
            if(linkState[myMsg->src][lsp[i].neighbor] != lsp[i].cost) {
                if(linkState[myMsg->src][lsp[i].neighbor] == LS_MAX_COST) {
                    numKnownNodes++;
                } else if(lsp[i].cost == LS_MAX_COST) {
                    numKnownNodes--;
                }
                linkState[myMsg->src][lsp[i].neighbor] = lsp[i].cost;
                linkState[lsp[i].neighbor][myMsg->src] = lsp[i].cost;
                isStateUpdated = TRUE;
            }
        }
        return isStateUpdated;
    }

    void sendLSP(uint8_t lostNeighbor) {
        uint32_t* neighbors = call NeighborDiscovery.getNeighbors();
        uint16_t neighborsListSize = call NeighborDiscovery.getNeighborListSize();
        uint16_t i = 0, j = 0, counter = 0;
        LSP linkStatePayload[10];
        // Zero out the array
        for(i = 0; i < 10; i++) {
            linkStatePayload[i].neighbor = 0;
            linkStatePayload[i].cost = 0;
        }
        i = 0;
        // If neighbor lost -> send out infinite cost
        if(lostNeighbor != 0) {
            dbg(ROUTING_CHANNEL, "Sending out lost neighbor %u\n", lostNeighbor);
            linkStatePayload[counter].neighbor = lostNeighbor;
            linkStatePayload[counter].cost = LS_MAX_COST;
            i++;
            counter++;
        }
        // Add neighbors in groups of 10 and flood LSP to all neighbors
        for(; i < neighborsListSize; i++) {
            linkStatePayload[counter].neighbor = neighbors[i];
            linkStatePayload[counter].cost = 1;
            counter++;
            if(counter == 10 || i == neighborsListSize-1) {
                // Send LSP to each neighbor                
                makePack(&routePack, TOS_NODE_ID, 0, LS_TTL, PROTOCOL_LS, sequenceNum++, &linkStatePayload, sizeof(linkStatePayload));
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
        uint16_t i = 0, j = 0, k = 0;
        uint8_t currentNode = TOS_NODE_ID, minCost = LS_MAX_COST, nextNode = 0, prevNode = 0;
        uint8_t prev[LS_MAX_ROUTES];
        uint8_t cost[LS_MAX_ROUTES];
        bool visited[LS_MAX_ROUTES];
        uint16_t count = numKnownNodes;
        for(i = 0; i < LS_MAX_ROUTES; i++) {
            cost[i] = LS_MAX_COST;
            prev[i] = 0;
            visited[i] = FALSE;
        }
        cost[currentNode] = 0;
        prev[currentNode] = 0;
        while(TRUE) {
            for(i = 1; i < LS_MAX_ROUTES; i++) {
                if(i != currentNode && linkState[currentNode][i] < LS_MAX_COST && cost[currentNode] + linkState[currentNode][i] < cost[i]) {
                    cost[i] = cost[currentNode] + linkState[currentNode][i];
                    prev[i] = currentNode;
                }
            }
            visited[currentNode] = TRUE;            
            minCost = LS_MAX_COST;
            nextNode = 0;
            for(i = 1; i < LS_MAX_ROUTES; i++) {
                if(cost[i] < minCost && !visited[i]) {
                    minCost = cost[i];
                    nextNode = i;
                }
            }
            currentNode = nextNode;
            if(--count == 0) {
                break;
            }
        }
        // NEED: add route to table
        for(i = 1; i < LS_MAX_ROUTES; i++) {
            if(i == TOS_NODE_ID) {
                continue;
            }
            if(cost[i] != LS_MAX_COST) {
                prevNode = i;
                while(prev[prevNode] != TOS_NODE_ID) {
                    prevNode = prev[prevNode];
                }
                addRoute(i, prevNode, cost[i]);
            } else {
                removeRoute(i);
            }
        }
    }

    void addRoute(uint8_t dest, uint8_t nextHop, uint8_t cost) {
        if(cost < routingTable[dest].cost) {
            routingTable[dest].nextHop = nextHop;
            routingTable[dest].cost = cost;
            numRoutes++;
        }
    }

    void removeRoute(uint8_t dest) {
        routingTable[dest].nextHop = 0;
        routingTable[dest].cost = LS_MAX_COST;
        numRoutes--;
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