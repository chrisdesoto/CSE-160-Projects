#include "../../includes/packet.h"

interface LinkStateRouting {
    command error_t start();
    command void handleDV(pack* myMsg);
    command void handleNeighborChange(uint16_t lostNeighbor);
    command void printRouteTable();
}