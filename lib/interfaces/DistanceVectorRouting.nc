#include "../../includes/packet.h"

interface DistanceVectorRouting {
    command error_t start();
    command void handleDV(pack* myMsg);
    command void handleNeighborChange(uint16_t lostNeighbor);
    command void printRouteTable();
}