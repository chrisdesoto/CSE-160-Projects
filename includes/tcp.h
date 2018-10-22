#ifndef __TCP_H__
#define __TCP_H__

#define TCP_PACKET_PAYLOAD_SIZE 7;

enum tcp_flags{
	DATA = 0,
	SYN = 1,
    ACK = 2,
	SYN_ACK = 3,
    FIN = 4
};

typedef nx_struct tcp_pack {
	nx_uint8_t srcPort;
	nx_uint8_t destPort;
	nx_uint16_t seq;
	nx_uint8_t flags;
	nx_uint8_t advertisedWindow;
	nx_uint16_t data[TCP_PACKET_PAYLOAD_SIZE];
} tcp_pack;


#endif