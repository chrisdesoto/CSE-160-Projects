/**
 * This class provides the TCP Transport functionality for nodes on the network.
 *
 * @author Chris DeSoto
 * @date   2013/10/21
 *
 */

#include <Timer.h>
#include "../../includes/CommandMsg.h"
#include "../includes/packet.h"

configuration TransportC {
    provides interface Transport;
}

implementation {
    components TransportP;
    Transport = TransportP;

    components new SimpleSendC(AM_PACK);
    TransportP.Sender -> SimpleSendC;

    components NeighborDiscoveryC;
    TransportP.NeighborDiscovery -> NeighborDiscoveryC;

    components DistanceVectorRoutingC;
    TransportP.DistanceVectorRouting -> DistanceVectorRoutingC;

    components new TimerMilliC() as RetransmissionTimer;
    TransportP.RetransmissionTimer -> RetransmissionTimer;

    components RandomC as Random;
    TransportP.Random -> Random;
}
