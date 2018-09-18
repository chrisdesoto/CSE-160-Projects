/**
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date   2013/09/03
 *
 */

#include <Timer.h>
//#include "includes/CommandMsg.h"
//#include "includes/packet.h"

configuration NeighborDiscoveryC {
    provides interface NeighborDiscovery;
}

implementation {
    components MainC;
    components Node;
    components NeighborDiscoveryP;
    NeighborDiscovery = NeighborDiscoveryP;
    
    //components new TimerMilliC() as NeighborDiscoveryTimer;    
    //NeighborDiscoveryP.NeighborDiscoveryTimer -> NeighborDiscoveryTimer;

    //components RandomC as Random;
    //NeighborDiscoveryP.Random -> Random;
}
