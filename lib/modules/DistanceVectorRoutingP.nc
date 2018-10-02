#include <Timer.h>
#include "../../includes/channels.h"
#include "../../includes/packet.h"
#include "../../includes/protocol.h"
#include "../../includes/channels.h"
module DistanctVectorRoutingP {
    provides interface DistanctVectorRouting;
    
    uses interface SimpleSend as Sender;
    uses interface NeighborDiscovery as NeighborDiscovery;
}

implementation {

    typedef struct {
        uint16_t dest;
        uint16_t nextHop;
        uint16_t cost;
        uint16_t ttl;
    } Route;
    
    uint16_t MAX_ROUTES = 22;
    uint16_t numRoutes = 0;
    Route routingTable[MAX_ROUTES];

    

}