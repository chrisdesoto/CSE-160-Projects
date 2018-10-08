#include <Timer.h>
#include "../../includes/channels.h"
#include "../../includes/packet.h"
#include "../../includes/protocol.h"

#define MAX_ROUTES  22
#define MAX_COST    17
#define DV_TTL       4
#define STRATEGY    "SPLIT_HORIZON"
//#define STRATEGY    "POISON_REVERSE"

module DistanceVectorRoutingP {
    provides interface DistanceVectorRouting;
    
    uses interface SimpleSend as Sender;
    uses interface NeighborDiscovery as NeighborDiscovery;
    uses interface Timer<TMilli> as DVRTimer;
    uses interface Random as Random;
}

implementation {

    typedef struct {
        uint8_t dest;
        uint8_t nextHop;
        uint8_t cost;
        uint8_t ttl;
    } Route;
    
    uint16_t numRoutes = 0;
    Route routingTable[MAX_ROUTES];
    pack routePack;

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, void *payload, uint8_t length);
    void initilizeRoutingTable();
    uint8_t findNextHop(uint8_t dest);
    void addRoute(uint8_t dest, uint8_t nextHop, uint8_t cost, uint8_t ttl);
    void removeRoute(uint8_t idx);
    void decrementTTLs();
    void inputNeighbors();
    void triggerUpdate();
    
    command error_t DistanceVectorRouting.start() {
        initilizeRoutingTable();
        call DVRTimer.startOneShot(30000);
        //dbg(ROUTING_CHANNEL, "Distance Vector Routing Started!\n");
    }

    event void DVRTimer.fired() {
        if(call DVRTimer.isOneShot()) {
            // Load initial neighbors into routing table
            call DVRTimer.startPeriodic(30000 + (uint16_t) (call Random.rand16()%5000));
        } else {
            // Decrement TTLs
            decrementTTLs();
            // Input neighbors into the routing table, if not there
            inputNeighbors();
            // Send out routing table
            triggerUpdate();
        }
    }

    command void DistanceVectorRouting.ping(uint16_t destination, uint8_t *payload) {
        makePack(&routePack, TOS_NODE_ID, destination, MAX_TTL, PROTOCOL_PING, 0, payload, PACKET_MAX_PAYLOAD_SIZE);
        dbg(ROUTING_CHANNEL, "PING FROM %d TO %d\n", TOS_NODE_ID, destination);
        logPack(&routePack);
        call DistanceVectorRouting.routePacket(&routePack);
    }

    command void DistanceVectorRouting.routePacket(pack* myMsg) {
        uint8_t nextHop;
        if(myMsg->dest == TOS_NODE_ID) {
            dbg(ROUTING_CHANNEL, "Packet has reached destination %d!!!\n", TOS_NODE_ID);
            return;
        }
        nextHop = findNextHop(myMsg->dest);
        if(nextHop == 0) {
            dbg(ROUTING_CHANNEL, "No route to destination. Dropping packet...\n");
            logPack(myMsg);
        } else {
            dbg(ROUTING_CHANNEL, "Node %d routing packet through %d\n", TOS_NODE_ID, nextHop);
            logPack(myMsg);
            call Sender.send(*myMsg, nextHop);
        }
    }

    // Update the routing table if needed
    command void DistanceVectorRouting.handleDV(pack* myMsg) {
        uint16_t i;
        bool routePresent = FALSE;
        Route* receivedRoute = (Route*) myMsg->payload;
        if(receivedRoute->dest != 0) {
            for(i = 0; i < numRoutes; i++) {
                if(receivedRoute->dest == routingTable[i].dest) {
                    // If route's next hop is myMsg->dest -> update
                    // If route costs less -> update
                    if(routingTable[i].nextHop == myMsg->src) {
                        routingTable[i].cost = (receivedRoute->cost+1 < MAX_COST) ? receivedRoute->cost+1 : MAX_COST;
                        routingTable[i].ttl = DV_TTL;
                        //dbg(ROUTING_CHANNEL, "Update to route: %d from neighbor: %d with new cost %d\n", routingTable[i].dest, routingTable[i].nextHop, routingTable[i].cost);
                    } else if(receivedRoute->cost + 1 <= MAX_COST && receivedRoute->cost + 1 <= routingTable[i].cost) {
                        routingTable[i].nextHop = myMsg->src;
                        routingTable[i].cost = receivedRoute->cost + 1;
                        routingTable[i].ttl = DV_TTL;
                        dbg(ROUTING_CHANNEL, "More optimal route found to dest: %d through %d at cost %d\n", routingTable[i].dest, routingTable[i].nextHop, routingTable[i].cost);
                    }
                    routePresent = TRUE;
                }
            }
            // If route not in table and there is space -> add it
            if(!routePresent && numRoutes != MAX_ROUTES) {
                addRoute(receivedRoute->dest, myMsg->src, receivedRoute->cost+1, DV_TTL);
            }
        }
    }

    command void DistanceVectorRouting.handleNeighborChange(uint16_t lostNeighbor) {
        // Neighbor change detected, update routing table and trigger DV update
        uint16_t i, j;
        if(lostNeighbor == 0)
            return;
        dbg(ROUTING_CHANNEL, "Neighbor discovery has lost neighbor %u, removing...\n", lostNeighbor);
        for(i = 1; i < numRoutes; i++) {
            if(routingTable[i].dest == lostNeighbor) {
                routingTable[i].cost = MAX_COST;
                break;
            }
        }
        triggerUpdate();
    }

    command void DistanceVectorRouting.printRouteTable() {
        uint8_t i;
        dbg(ROUTING_CHANNEL, "DEST  HOP  COST  TTL\n");
        for(i = 0; i < numRoutes; i++) {
            dbg(ROUTING_CHANNEL, "%4d%5d%6d%5d\n", routingTable[i].dest, routingTable[i].nextHop, routingTable[i].cost, routingTable[i].ttl);
        }
    }

    void initilizeRoutingTable() {
        addRoute(TOS_NODE_ID, TOS_NODE_ID, 0, DV_TTL);
    }

    uint8_t findNextHop(uint8_t dest) {
        uint16_t i;
        for(i = 1; i < numRoutes; i++) {
            if(routingTable[i].dest == dest) {
                return routingTable[i].nextHop;
            }
        }
        return 0;
    }

    void addRoute(uint8_t dest, uint8_t nextHop, uint8_t cost, uint8_t ttl) {
        // Add route to the end of the current list
        if(numRoutes != MAX_ROUTES) {
            routingTable[numRoutes].dest = dest;
            routingTable[numRoutes].nextHop = nextHop;
            routingTable[numRoutes].cost = cost;
            routingTable[numRoutes].ttl = ttl;
            numRoutes++;
        }
        //dbg(ROUTING_CHANNEL, "Added entry in routing table for node: %u\n", dest);
    }

    void removeRoute(uint8_t idx) {
        uint8_t j;
        // Move other entries left
        for(j = idx+1; j < numRoutes; j++) {
            routingTable[j-1].dest = routingTable[j].dest;
            routingTable[j-1].nextHop = routingTable[j].nextHop;
            routingTable[j-1].cost = routingTable[j].cost;
            routingTable[j-1].ttl = routingTable[j].ttl;
        }
        // Zero the j-1 entry
        routingTable[j-1].dest = 0;
        routingTable[j-1].nextHop = 0;
        routingTable[j-1].cost = MAX_COST;
        routingTable[j-1].ttl = 0;
        numRoutes--;        
    }

    void decrementTTLs() {
        uint8_t i, j;
        for(i = 1; i < numRoutes; i++) {
            // If valid entry in the routing table -> decrement the TTL
            if(routingTable[i].ttl != 0) {
                routingTable[i].ttl -= 1;
            }
            // If TTL is zero -> remove the route
            if(routingTable[i].ttl == 0) {
                dbg(ROUTING_CHANNEL, "Route stale, removing: %u\n", routingTable[i].dest);
                removeRoute(i);
            }
        }
    }

    void inputNeighbors() {
        uint32_t* neighbors = call NeighborDiscovery.getNeighbors();
        uint16_t neighborsListSize = call NeighborDiscovery.getNeighborListSize();
        uint8_t i, j;
        bool routeFound = FALSE, newNeighborfound = FALSE;
        for(i = 0; i < neighborsListSize; i++) {
            for(j = 1; j < numRoutes; j++) {
                // If neighbor found in routing table -> update table entry
                if(neighbors[i] == routingTable[j].dest) {
                    routingTable[j].nextHop = neighbors[i];
                    routingTable[j].cost = 1;
                    routingTable[j].ttl = DV_TTL;
                    routeFound = TRUE;
                    break;
                }
            }
            // If neighbor not already in the list and there is room -> add new neighbor
            if(!routeFound && numRoutes != MAX_ROUTES) {
                addRoute(neighbors[i], neighbors[i], 1, DV_TTL);
                newNeighborfound = TRUE;
            } else if(numRoutes == MAX_ROUTES) {
                dbg(ROUTING_CHANNEL, "Routing table full. Cannot add entry for node: %u\n", neighbors[i]);
            }
            routeFound = FALSE;
        }
    }

    void triggerUpdate() {
        // Send routes to all neighbors one at a time. Use split horizon, poison reverse
        uint32_t* neighbors = call NeighborDiscovery.getNeighbors();
        uint16_t neighborsListSize = call NeighborDiscovery.getNeighborListSize();
        uint8_t i, j;
        uint8_t tempCost;
        bool isSwapped = FALSE;
        // Alter route table for split horizon or poison reverse, keeping values in temp vars
        // Send packet with copy of routing table
        // Restore original route
        for(i = 0; i < neighborsListSize; i++) {
            for(j = 0; j < numRoutes; j++) {
                // Split Horizon/Poison Reverse
                if(neighbors[i] == routingTable[j].nextHop && strcmp(STRATEGY, "SPLIT_HORIZON") == 0) {
                    continue;
                } else if(neighbors[i] == routingTable[j].nextHop && strcmp(STRATEGY, "POISON_REVERSE") == 0) {
                    tempCost = routingTable[j].cost;
                    routingTable[j].cost = MAX_COST;
                    isSwapped = TRUE;
                }
                // Send packet
                makePack(&routePack, TOS_NODE_ID, neighbors[i], 1, PROTOCOL_DV, 0, &routingTable[j], sizeof(Route));
                call Sender.send(routePack, neighbors[i]);
                if(isSwapped) {
                    routingTable[j].cost = tempCost;
                }
                isSwapped = FALSE;
            }
        }
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