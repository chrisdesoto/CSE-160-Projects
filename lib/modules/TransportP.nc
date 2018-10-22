#include "../../includes/CommandMsg.h"
#include "../../includes/command.h"
#include "../../includes/channels.h"
#include "../../includes/socket.h"
#include "../../includes/tcp.h"

module TransportP{
   provides interface Transport;
}

implementation{
    pack ipPack;
    tcp_pack tcpPack;
    socket_store_t[MAX_NUM_OF_SOCKETS] sockets;

}