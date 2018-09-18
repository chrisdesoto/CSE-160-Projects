

//#include "includes/channels.h"
module NeighborDiscoveryP {

    provides interface NeighborDiscovery;

    //uses interface Timer<TMilli> as NeighborDiscoveryTimer;
    //uses interface Random as Random;

}

implementation {

    command error_t NeighborDiscovery.start() {
        dbg(GENERAL_CHANNEL, "ND\n");
    }

    command error_t NeighborDiscovery.neighborReply(void *pack) {
        dbg(GENERAL_CHANNEL, "ND\n");
    }

}