/**
 * This class provides the TCP App functionality for nodes on the network.
 *
 * @author Chris DeSoto
 * @date   2018/10/27
 *
 */

#include <Timer.h>
#include "../../includes/CommandMsg.h"
#include "../includes/packet.h"
#include "../includes/socket.h"

configuration TransportAppC {
    provides interface TransportApp;
}

implementation {
    components TransportAppP;
    TransportApp = TransportAppP;

    components new SimpleSendC(AM_PACK);
    TransportAppP.Sender -> SimpleSendC;

    components new TimerMilliC() as AppTimer;
    TransportP.AppTimer -> AppTimer;

    components RandomC as Random;
    TransportAppP.Random -> Random;

    components TransportC as Transport;
    TransportAppP.Transport -> Transport;
}