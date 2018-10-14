#include "../../includes/packet.h"

interface LinkStateRouting {
    command error_t start();
    command void routePacket(pack* myMsg);
    command void handleLS(pack* myMsg);
    command void handleNeighborLost(uint16_t lostNeighbor);
    command void handleNeighborFound();
    command void printRouteTable();
}