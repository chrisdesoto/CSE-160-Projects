/**
 * This class provides the Chat App functionality for nodes on the network.
 *
 * @author Chris DeSoto
 * @date   2018/11/29
 *
 */

#include <Timer.h>
#include "../../includes/CommandMsg.h"
#include "../includes/packet.h"
#include "../includes/socket.h"

configuration ChatAppC {
    provides interface ChatApp;
}

implementation {
    components ChatAppP;
    ChatApp = ChatAppP;

    components new SimpleSendC(AM_PACK);
    ChatAppP.Sender -> SimpleSendC;

    components new TimerMilliC() as ChatTimer;
    ChatAppP.ChatTimer -> ChatTimer;

    components RandomC as Random;
    ChatAppP.Random -> Random;

    components TransportC as Transport;
    ChatAppP.Transport -> Transport;

    components new HashmapC(uint8_t, 20);
    ChatAppP.ConnectionMap -> HashmapC;
}