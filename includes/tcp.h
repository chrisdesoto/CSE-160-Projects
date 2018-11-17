#ifndef __TCP_H__
#define __TCP_H__

#include "protocol.h"
#include "channels.h"

#define NUM_SUPPORTED_PORTS 256
#define TCP_PACKET_PAYLOAD_SIZE 10
#define TCP_INITIAL_RTT 2048
#define TCP_INITIAL_RTO 1024
#define TCP_INITIAL_RTT_VAR 512
#define TCP_RTT_ALPHA 80
#define TCP_RTT_BETA 75
#define TCP_MIN_CWND 1
#define TCP_MAX_CWND 18
#define TCP_FT_DUP 3
#define TCP_DEADLOCK_ACK_RTO 4096

enum tcp_flags{
	DATA = 0,
    ACK = 1,
	SYN = 2,
	SYN_ACK = 3,
    FIN = 4,
    FIN_ACK = 5
};

typedef nx_struct tcp_pack {
	nx_uint8_t srcPort;
	nx_uint8_t destPort;
	nx_uint8_t seq;
	nx_uint8_t ack;
	nx_uint8_t flags;
	nx_uint8_t advertisedWindow;
	nx_uint8_t length;
	nx_uint8_t payload[TCP_PACKET_PAYLOAD_SIZE];
} tcp_pack;


#endif