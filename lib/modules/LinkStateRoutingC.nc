/**
 * This class provides the Link State Routing functionality for nodes on the network.
 *
 * @author Chris DeSoto
 * @date   2013/09/30
 *
 */

#include <Timer.h>
#include "../../includes/CommandMsg.h"
#include "../../includes/packet.h"

configuration LinkStateRoutingC {
    provides interface LinkStateRouting;
}

implementation {
    components LinkStateRoutingP;
    LinkStateRouting = LinkStateRoutingP;

    components new SimpleSendC(AM_PACK);
    LinkStateRoutingP.Sender -> SimpleSendC;

    components NeighborDiscoveryC;
    LinkStateRoutingP.NeighborDiscovery -> NeighborDiscoveryC;

    components new TimerMilliC() as LSRTimer;
    LinkStateRoutingP.LSRTimer -> LSRTimer;

    components RandomC as Random;
    LinkStateRoutingP.Random -> Random;
}
