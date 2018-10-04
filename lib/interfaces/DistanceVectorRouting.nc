#include "../../includes/packet.h"

interface DistanceVectorRouting {
    command error_t start();
    command void ping(uint16_t destination, uint8_t *payload);
    command void routePacket(pack* myMsg);
    command void handleDV(pack* myMsg);
    command void handleNeighborChange(uint16_t lostNeighbor);
    command void printRouteTable();
}