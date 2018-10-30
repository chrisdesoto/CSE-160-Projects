#include "../includes/packet.h"
#include "../../includes/socket.h"


interface TransportApp{
    command void startServer(uint8_t port);
    command void startClient(uint8_t dest, uint8_t srcPort, uint8_t destPort, uint16_t transfer);
    command void closeClient(uint8_t srcPort, uint8_t destPort, uint8_t dest);
}