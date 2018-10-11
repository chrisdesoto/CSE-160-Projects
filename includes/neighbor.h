
#ifndef PACKET_H
#define PACKET_H

typedef struct {    
    uint16_t TTL;
    uint16_t Sn;
    uint32_t EWMA;
} Neighbor;

#endif