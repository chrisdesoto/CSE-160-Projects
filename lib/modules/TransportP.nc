#include <Timer.h>
#include "../../includes/CommandMsg.h"
#include "../../includes/command.h"
#include "../../includes/channels.h"
#include "../../includes/socket.h"
#include "../../includes/tcp.h"
#include "../../includes/packet.h"
#include "../../includes/protocol.h"

module TransportP{
    provides interface Transport;

    uses interface SimpleSend as Sender;
    uses interface Random;
    uses interface Timer<TMilli> as RetransmissionTimer;
    uses interface NeighborDiscovery;
    uses interface DistanceVectorRouting;
    uses interface Hashmap<uint8_t> as SocketMap;
}

implementation{
    pack ipPack;
    tcp_pack tcpPack;
    bool ports[NUM_SUPPORTED_PORTS];
    socket_store_t sockets[MAX_NUM_OF_SOCKETS];

    /*
    * Helper functions
    */

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, void* payload, uint8_t length) {
        Package->src = src;
        Package->dest = dest;
        Package->TTL = TTL;
        Package->seq = seq;
        Package->protocol = protocol;
        memcpy(Package->payload, payload, length);
    }

    uint16_t min(uint16_t a, uint16_t b) {
        if(a <= b)
            return a;
        else
            return b;
    }

    void addConnection(uint8_t fd, uint8_t conn) {
        uint8_t i;
        for(i = 0; i < MAX_NUM_OF_SOCKETS-1; i++) {
            if(sockets[fd-1].connectionQueue[i] == 0) {
                sockets[fd-1].connectionQueue[i] = conn;
                break;
            }
        }
    }

    uint8_t findSocket(uint8_t src, uint8_t srcPort, uint8_t dest, uint8_t destPort) {
        uint32_t socketId = (((uint32_t)src) << 24) | (((uint32_t)srcPort) << 16) | (((uint32_t)dest) << 8) | (((uint32_t)destPort));
        return call SocketMap.get(socketId);
    }

    void printSocket(uint8_t fd) {
        dbg(TRANSPORT_CHANNEL, "fd %u, socket %u\n", fd, fd-1);
        dbg(TRANSPORT_CHANNEL, "last read %u, last received %u, next expected %u\n", sockets[fd-1].lastRead, sockets[fd-1].lastRcvd, sockets[fd-1].nextExpected);
    }

    uint16_t calculateSendWindow(uint8_t fd) {
        if(sockets[fd-1].lastSent == sockets[fd-1].lastWritten)
            return 0;
        else if(sockets[fd-1].lastSent > sockets[fd-1].lastWritten)
            return sockets[fd-1].lastWritten + (SOCKET_BUFFER_SIZE - sockets[fd-1].lastSent);
        else
            return sockets[fd-1].lastWritten - sockets[fd-1].lastSent;
    }

    uint16_t calculateReceiveWindow(uint8_t fd) {
        if(sockets[fd-1].lastRead == sockets[fd-1].lastRcvd)
            return 0;
        else if(sockets[fd-1].lastRead > sockets[fd-1].lastRcvd)
            return sockets[fd-1].lastRcvd + (SOCKET_BUFFER_SIZE - sockets[fd-1].lastRead);
        else
            return sockets[fd-1].lastRcvd - sockets[fd-1].lastRead;
    }

    uint16_t calculateSendBufferSize(uint8_t fd) {
        if(sockets[fd-1].lastAck == sockets[fd-1].lastWritten)
            return SOCKET_BUFFER_SIZE - 1;
        else if(sockets[fd-1].lastAck > sockets[fd-1].lastWritten)
            return sockets[fd-1].lastAck - sockets[fd-1].lastWritten - 1;
        else
            return sockets[fd-1].lastAck + (SOCKET_BUFFER_SIZE - sockets[fd-1].lastWritten) - 1;
    }    

    uint16_t calculateReceiveBufferSize(uint8_t fd) {
        if(sockets[fd-1].lastRead == sockets[fd-1].lastRcvd)
            return SOCKET_BUFFER_SIZE - 1;
        else if(sockets[fd-1].lastRead > sockets[fd-1].lastRcvd)
            return sockets[fd-1].lastRead - sockets[fd-1].lastRcvd - 1;
        else
            return sockets[fd-1].lastRead + (SOCKET_BUFFER_SIZE - sockets[fd-1].lastRcvd) - 1;
    }

    void calculateRTT(uint8_t fd) {
        sockets[fd-1].RTT = ((TCP_RTT_ALPHA) * (sockets[fd-1].RTT) + (100-TCP_RTT_ALPHA) * (call RetransmissionTimer.getNow() - sockets[fd-1].RTX)) / 100;
        // dbg(TRANSPORT_CHANNEL, "RTT: %u\n", sockets[fd-1].RTT);
    }

    void calculateRTO(uint8_t fd) {
        sockets[fd-1].RTO = call RetransmissionTimer.getNow() + (2 * sockets[fd-1].RTT);
    }

    void sendTCPPacket(uint8_t fd, uint8_t flags, uint16_t* payload, bool retransmit) {
        uint8_t length, bytes = 0;
        uint16_t i;
        tcpPack.srcPort = sockets[fd-1].src.port;
        tcpPack.destPort = sockets[fd-1].dest.port;
        //tcpPack.seq = sockets[fd-1].nextExpected;
        tcpPack.flags = flags;
        tcpPack.advertisedWindow = sockets[fd-1].advertisedWindow;
        if(flags == DATA) {
            //dbg(TRANSPORT_CHANNEL, "Sending data packet\n");
            //dbg(TRANSPORT_CHANNEL, "Send window size: %u\n", calculateSendWindow(fd));
            length = min(calculateSendWindow(fd), TCP_PACKET_PAYLOAD_SIZE);
            length -= length & 1;
            if(length == 0 || sockets[fd-1].lastAck != sockets[fd-1].lastSent) {
                //dbg(TRANSPORT_CHANNEL, "Sending window %u or not acked\n", calculateSendWindow(fd));
                return;
            }
            while(bytes < length) {
                memcpy(tcpPack.payload+(bytes>>1), &sockets[fd-1].sendBuff[sockets[fd-1].lastSent], 2);
                bytes += 2;
                sockets[fd-1].lastSent += 2;
                if(sockets[fd-1].lastSent == SOCKET_BUFFER_SIZE) {
                    sockets[fd-1].lastSent = 0;
                }
            }
            tcpPack.length = length;
        }
        if(flags != ACK) {
            sockets[fd-1].RTX = call RetransmissionTimer.getNow();
            calculateRTO(fd);
        } else {
            tcpPack.ack = sockets[fd-1].stopAndWait;
        }
        if(flags == SYN_ACK) {
            tcpPack.ack = sockets[fd-1].stopAndWait ^ 1;
        }
        // Set stop and wait bit
        tcpPack.seq = sockets[fd-1].stopAndWait;
        // Flip the stop-and-wait bit
        makePack(&ipPack, TOS_NODE_ID, sockets[fd-1].dest.addr, BETTER_TTL, PROTOCOL_TCP, 0, &tcpPack, sizeof(tcp_pack));
        call DistanceVectorRouting.routePacket(&ipPack);
    }

    bool readInData(uint8_t fd, tcp_pack* tcp_rcvd) {
        uint16_t i = 0, bytesRead = 0;
        if(calculateReceiveBufferSize(fd) < tcp_rcvd->length) {
            dbg(TRANSPORT_CHANNEL, "Returning false. Can't fit packet.\n");
            //dbg(TRANSPORT_CHANNEL, "Returning false. Can't fit packet\n");
            //dbg(TRANSPORT_CHANNEL, "Returning false. Can't fit packet\n");
            // dbg(TRANSPORT_CHANNEL, "%u\n", ((tcp_rcvd->payload[i] & 0xFF) << 8) | tcp_rcvd->payload[i] >> 8);
            return FALSE;
        }
        if(sockets[fd-1].stopAndWait == tcp_rcvd->seq) {
            dbg(TRANSPORT_CHANNEL, "Incorrect seq num. Re-ACKing packet.\n");
            sendTCPPacket(fd, ACK, NULL, FALSE);
            return FALSE;
        }
        //dbg(TRANSPORT_CHANNEL, "Receive buffer size %u\n", calculateReceiveBufferSize(fd));        
        //dbg(TRANSPORT_CHANNEL, "Server reading packet %u data\n", tcp_rcvd->length);
        // for(i = 0; i < tcp_rcvd->length/2; i++) {
        //     dbg(TRANSPORT_CHANNEL, "%u\n", ((tcp_rcvd->payload[i] & 0xFF) << 8) | tcp_rcvd->payload[i] >> 8);
        // }
        while(bytesRead < tcp_rcvd->length && calculateReceiveBufferSize(fd) > 0) {
            memcpy(&sockets[fd-1].rcvdBuff[sockets[fd-1].lastRcvd], &tcp_rcvd->payload[bytesRead/2], 2);
            bytesRead += 2;
            sockets[fd-1].lastRcvd += 2;
            if(sockets[fd-1].lastRcvd >= SOCKET_BUFFER_SIZE && calculateReceiveBufferSize(fd) > 0) {
                //dbg(TRANSPORT_CHANNEL, "Resetting received %u. Receive buffer size %u\n", sockets[fd-1].lastRcvd, calculateReceiveBufferSize(fd));
                sockets[fd-1].lastRcvd = 0;
            } else if(sockets[fd-1].lastRcvd >= SOCKET_BUFFER_SIZE) {
                dbg(TRANSPORT_CHANNEL, "Returning false down here. Can't fit packet\n");
                sockets[fd-1].lastRcvd -= bytesRead;
                return FALSE;
            }
        }
        // Set new stop and wait bit
        sockets[fd-1].stopAndWait = tcp_rcvd->seq;
        sockets[fd-1].nextExpected = sockets[fd-1].lastRcvd + 1;
        return TRUE;
    }

    void zeroTCPPacket() {
        uint8_t i;
        for(i = 0; i < TCP_PACKET_PAYLOAD_LENGTH; i++) {
            tcpPack.payload[i] = 0;
        }
        tcpPack.srcPort = 0;
        tcpPack.destPort = 0;
        tcpPack.seq = 0;
        tcpPack.flags = 0;
        tcpPack.advertisedWindow = 0;
    }

    void zeroSocket(uint8_t fd) {
        uint8_t i;
        sockets[fd-1].flags = 0;
        sockets[fd-1].state = CLOSED;
        sockets[fd-1].src.port = 0;
        sockets[fd-1].src.addr = 0;
        sockets[fd-1].dest.port = 0;
        sockets[fd-1].dest.addr = 0;
        for(i = 0; i < MAX_NUM_OF_SOCKETS-1; i++) {
            sockets[fd-1].connectionQueue[i] = 0;
        }
        for(i = 0; i < SOCKET_BUFFER_SIZE; i++) {
            sockets[fd-1].sendBuff[i] = 0;
            sockets[fd-1].rcvdBuff[i] = 0;
        }
        sockets[fd-1].stopAndWait = 0;
        sockets[fd-1].lastWritten = 0;
        sockets[fd-1].lastAck = 0;
        sockets[fd-1].lastSent = 0;
        sockets[fd-1].sendSize = 0;
        sockets[fd-1].lastRead = 0;
        sockets[fd-1].lastRcvd = 0;
        sockets[fd-1].nextExpected = 0;
        sockets[fd-1].RTT = TCP_INITIAL_RTT;
        sockets[fd-1].advertisedWindow = 0;
        sockets[fd-1].effectiveWindow = 0;
    }

    uint8_t cloneSocket(uint8_t fd, uint16_t addr, uint8_t port) {
        uint8_t i;
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if(sockets[i].flags == 0) {
                sockets[i].src.port = sockets[fd-1].src.port;
                sockets[i].src.addr = sockets[fd-1].src.addr;
                sockets[i].dest.addr = addr;
                sockets[i].dest.port = port;
                return i+1;
            }
        }
        return 0;
    }

    void calcAdvWindow(socket_store_t* sock) {
        if(sock->nextExpected-1 >= sock->lastRead)
            sock->advertisedWindow = SOCKET_BUFFER_SIZE - ((sock->nextExpected-1) - sock->lastRead);
        else
            sock->advertisedWindow = SOCKET_BUFFER_SIZE - ((SOCKET_BUFFER_SIZE - (sock->nextExpected-1)) + sock->lastRead);
    }

    void calcEffWindow(socket_store_t* sock) {
        if(sock->lastSent >= sock->lastAck)
            sock->effectiveWindow = sock->advertisedWindow - (sock->lastSent - sock->lastAck);
        else
            sock->effectiveWindow = sock->advertisedWindow - ((SOCKET_BUFFER_SIZE - sock->lastSent) + sock->lastAck);
    }

    /*
    * Interface methods
    */

    command void Transport.start() {
        uint8_t i;
        call RetransmissionTimer.startOneShot(60*1024);
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            zeroSocket(i+1);
        }
    }

    event void RetransmissionTimer.fired() {
        uint8_t i;
        if(call RetransmissionTimer.isOneShot()) {
            dbg(TRANSPORT_CHANNEL, "TCP starting on node %u\n", TOS_NODE_ID);
            call RetransmissionTimer.startPeriodic(1024 + (uint16_t) (call Random.rand16()%1000));
        }
        // Iterate over sockets
            // If timeout -> retransmit
            // If ESTABLISHED -> attempt to send packets
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if(sockets[i].RTO < call RetransmissionTimer.getNow()) {
                //dbg(TRANSPORT_CHANNEL, "Retransmitting!\n");
                switch(sockets[i].state) {
                    case ESTABLISHED:
                        if(sockets[i].lastSent != sockets[i].lastAck && sockets[i].type == CLIENT) {
                            //dbg(TRANSPORT_CHANNEL, "Resending packets\n");
                            // Move pointer back to last acked
                            //dbg(TRANSPORT_CHANNEL, "lastSent %u\n", sockets[i].lastSent);
                            sockets[i].lastSent = sockets[i].lastAck;
                            //dbg(TRANSPORT_CHANNEL, "lastAck %u\n", sockets[i].lastAck);
                            dbg(TRANSPORT_CHANNEL, "Resending at %u\n", (((uint16_t)sockets[i].sendBuff[sockets[i].lastSent+1]) << 8) | (uint16_t)sockets[i].sendBuff[sockets[i].lastSent]);
                            // Resend data
                            sendTCPPacket(i+1, DATA, NULL, TRUE);
                            continue;
                        }
                        break;
                    case SYN_SENT:
                        dbg(TRANSPORT_CHANNEL, "Resending SYN\n");
                        // Send SYN
                        sendTCPPacket(i+1, SYN, NULL, TRUE);
                        break;
                    case SYN_RCVD:
                        // Send SYN_ACK
                        sendTCPPacket(i+1, SYN_ACK, NULL, TRUE);
                        break;
                    case CLOSE_WAIT:
                        dbg(TRANSPORT_CHANNEL, "Sending last FIN.\n");
                        sendTCPPacket(i+1, FIN, NULL, TRUE);                        
                        dbg(TRANSPORT_CHANNEL, "Going to LAST_ACK.\n");
                        sockets[i].state = LAST_ACK;
                        break;
                    case FIN_WAIT_1:
                    case LAST_ACK:
                        // Send FIN
                        sendTCPPacket(i+1, FIN, NULL, TRUE);
                        dbg(TRANSPORT_CHANNEL, "CONNECTION CLOSED!\n");
                        break;
                    case TIME_WAIT:
                        sockets[i].state = CLOSED;
                        dbg(TRANSPORT_CHANNEL, "CONNECTION CLOSED!\n");
                }
            }
            if(sockets[i].state == ESTABLISHED) {
                // Send data
                if(sockets[i].type == CLIENT) {
                    sendTCPPacket(i+1, DATA, NULL, FALSE);
                }
            }
        }
    }    

    /**
    * Get a socket if there is one available.
    * @Side Client/Server
    * @return
    *    socket_t - return a socket file descriptor which is a number
    *    associated with a socket. If you are unable to allocated
    *    a socket then return a NULL socket_t.
    */
    command socket_t Transport.socket() {
        uint8_t i;
        // For socket in socket store
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            // If socket not in use
            if(sockets[i].state == CLOSED) {
                sockets[i].state = OPENED;
                // Return idx+1
                return (socket_t) i+1;
            }
        }
        // No socket found -> Return 0
        return 0;
    }

    /**
    * Bind a socket with an address.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       you are binding.
    * @param
    *    socket_addr_t *addr: the source port and source address that
    *       you are biding to the socket, fd.
    * @Side Client/Server
    * @return error_t - SUCCESS if you were able to bind this socket, FAIL
    *       if you were unable to bind.
    */
    command error_t Transport.bind(socket_t fd, socket_addr_t *addr) {
        uint32_t socketId = 0;
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        // For given socket & address
        // If fd opened and port not in use
        if(sockets[fd-1].state == OPENED && !ports[addr->port]) {
            // Bind address and port to socket
            sockets[fd-1].src.addr = addr->addr;
            sockets[fd-1].src.port = addr->port;
            sockets[fd-1].state = NAMED;
            // Add the socket to the SocketMap
            socketId = (((uint32_t)addr->addr) << 24) | (((uint32_t)addr->port) << 16);
            call SocketMap.insert(socketId, fd);
            // Mark the port as used
            ports[addr->port] = TRUE;
            // Return SUCCESS
            return SUCCESS;
        } else {
           // Else return FAIL
            return FAIL;
        }
    }

    /**
    * Checks to see if there are socket connections to connect to and
    * if there is one, connect to it.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that is attempting an accept. remember, only do on listen. 
    * @side Server
    * @return socket_t - returns a new socket if the connection is
    *    accepted. this socket is a copy of the server socket but with
    *    a destination associated with the destination address and port.
    *    if not return a null socket.
    */
    command socket_t Transport.accept(socket_t fd) {
        uint8_t i, conn;
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS) {
            return 0;
        }
        // For given socket
        for(i = 0; i < MAX_NUM_OF_SOCKETS-1; i++) {
            // If connectionQueue is not empty
            if(sockets[fd-1].connectionQueue[i] != 0) {
                conn = sockets[fd-1].connectionQueue[i];
                while(++i < MAX_NUM_OF_SOCKETS-1 && sockets[fd-1].connectionQueue[i] != 0) {
                    sockets[fd-1].connectionQueue[i-1] = sockets[fd-1].connectionQueue[i];
                }
                sockets[fd-1].connectionQueue[i-1] = 0;
                // Return the fd representing the connection
                return (socket_t) conn;
            }
        }
        return 0;
    }

    /**
    * Write to the socket from a buffer. This data will eventually be
    * transmitted through your TCP implimentation.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that is attempting a write.
    * @param
    *    uint8_t *buff: the buffer data that you are going to wrte from.
    * @param
    *    uint16_t bufflen: The amount of data that you are trying to
    *       submit.
    * @Side For your project, only client side. This could be both though.
    * @return uint16_t - return the amount of data you are able to write
    *    from the pass buffer. This may be shorter then bufflen
    */
    command uint16_t Transport.write(socket_t fd, uint8_t *buff, uint16_t bufflen) {
        uint16_t bytesWritten = 0, data, maxAllowed;
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS || sockets[fd-1].state != ESTABLISHED) {
            return 0;
        }
        // Write all possible data to the given socket
        //dbg(TRANSPORT_CHANNEL, "lastSent %u lastWritten %u lastAck %u\n", sockets[fd-1].lastSent, sockets[fd-1].lastWritten, sockets[fd-1].lastAck);

        while(bytesWritten < bufflen && calculateSendBufferSize(fd) > 0) {
            //dbg(TRANSPORT_CHANNEL, "Send buffer size %u\n", calculateSendBufferSize(fd));
            //dbg(TRANSPORT_CHANNEL, "lastWritten preincrement %u\n", sockets[fd-1].lastWritten);
            memcpy(&sockets[fd-1].sendBuff[sockets[fd-1].lastWritten], buff+bytesWritten, 1);
            //dbg(TRANSPORT_CHANNEL, "lastWritten 0 %u\n", sockets[fd-1].lastWritten);
            bytesWritten++;
            sockets[fd-1].lastWritten++;
            //dbg(TRANSPORT_CHANNEL, "lastWritten postincrement %u\n", sockets[fd-1].lastWritten);
            if((sockets[fd-1].lastWritten & 1) == 0) {
                //dbg(TRANSPORT_CHANNEL, "Data written at %u to TCP buffer: %u\n", sockets[fd-1].lastWritten-2, ((uint16_t)sockets[fd-1].sendBuff[sockets[fd-1].lastWritten-1] << 8) | (uint16_t) sockets[fd-1].sendBuff[sockets[fd-1].lastWritten-2]);
            }
            if(sockets[fd-1].lastWritten >= SOCKET_BUFFER_SIZE && calculateSendBufferSize(fd) > 0) {
                // dbg(TRANSPORT_CHANNEL, "Client: buffer wrap\n");
                sockets[fd-1].lastWritten = 0;
            }
        }
        //if(bytesWritten > 0)
        //    dbg(TRANSPORT_CHANNEL, "%u bytes written to buffer\n", bytesWritten);
        // Return number of bytes written
        return bytesWritten;
    }

    /**
    * This will pass the packet so you can handle it internally.
    * @param
    *    pack *package: the TCP packet that you are handling.
    * @Side Client/Server 
    * @return uint16_t - return SUCCESS if you are able to handle this
    *    packet or FAIL if there are errors.
    */
    command error_t Transport.receive(pack* package) {
        uint8_t fd, newFd, src = package->src;
        tcp_pack* tcp_rcvd = (tcp_pack*) &package->payload;
        uint32_t socketId = 0;
        switch(tcp_rcvd->flags) {
            case DATA:
                // Find socket fd
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
                switch(sockets[fd-1].state) {
                    case SYN_RCVD:
                        // if(tcp_rcvd->ack == sockets[fd-1].nextExpected) {
                        //     dbg(TRANSPORT_CHANNEL, "CONNECTION ESTABLISHED!\n");
                        //     sockets[fd-1].state = ESTABLISHED;
                        // }
                        dbg(TRANSPORT_CHANNEL, "CONNECTION ESTABLISHED!\n");
                        sockets[fd-1].state = ESTABLISHED;
                    case ESTABLISHED:
                        //dbg(TRANSPORT_CHANNEL, "Receiving data on node %u\n", TOS_NODE_ID);
                        /*
                        dbg(TRANSPORT_CHANNEL, "Data 1: %u\n", tcp_rcvd->payload[0]);
                        dbg(TRANSPORT_CHANNEL, "Data 2: %u\n", tcp_rcvd->payload[1]);
                        dbg(TRANSPORT_CHANNEL, "Length: %u\n", tcp_rcvd->length);*/
                        // Process data
                        //dbg(TRANSPORT_CHANNEL, "Data received on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
                        if(readInData(fd, tcp_rcvd))
                            // Send ACK
                            sendTCPPacket(fd, ACK, NULL, FALSE);
                        else {

                        }
                        return SUCCESS;
                }
                break;
            case ACK:
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
                if(fd == 0)
                    break;
                //dbg(TRANSPORT_CHANNEL, "RTT then %u\n", sockets[fd-1].RTT);
                calculateRTT(fd);
                //dbg(TRANSPORT_CHANNEL, "RTT now %u\n", sockets[fd-1].RTT);
                // Handle setup, data, teardown
                switch(sockets[fd-1].state) {
                    case SYN_RCVD:
                        dbg(TRANSPORT_CHANNEL, "ACK received on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
                        // Set state
                        sockets[fd-1].state = ESTABLISHED;
                        dbg(TRANSPORT_CHANNEL, "CONNECTION ESTABLISHED!\n");
                        return SUCCESS;
                    case ESTABLISHED:
                        //dbg(TRANSPORT_CHANNEL, "ACK received on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
                        // Data ACK
                        if(tcp_rcvd->ack == sockets[fd-1].stopAndWait) {
                            sockets[fd-1].lastAck = sockets[fd-1].lastSent;
                            sockets[fd-1].stopAndWait ^= 1;
                        }
                        //dbg(TRANSPORT_CHANNEL, "lastAck %u\n", sockets[fd-1].lastAck);
                        return SUCCESS;
                    case FIN_WAIT_1:
                        dbg(TRANSPORT_CHANNEL, "ACK received on node %u via port %u. Going to FIN_WAIT_2.\n", TOS_NODE_ID, tcp_rcvd->destPort);
                        // Set state
                        sockets[fd-1].state = FIN_WAIT_2;
                        return SUCCESS;
                    case CLOSING:
                        // Set state
                        sockets[fd-1].state = TIME_WAIT;
                        return SUCCESS;
                    case LAST_ACK:
                        dbg(TRANSPORT_CHANNEL, "Received last ack. ZEROing socket.\n");
                        zeroSocket(fd);
                        // Set state
                        sockets[fd-1].state = CLOSED;
                        dbg(TRANSPORT_CHANNEL, "CONNECTION CLOSED!\n");
                        return SUCCESS;
                }
                break;
            case SYN:
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, 0, 0);
                if(fd > 0 && sockets[fd-1].state == LISTEN) {
                    dbg(TRANSPORT_CHANNEL, "SYN recieved on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
                    // Create new active socket
                    newFd = cloneSocket(fd, package->src, tcp_rcvd->srcPort);
                    if(newFd > 0) {
                        // Add new connection to fd connection queue
                        addConnection(fd, newFd);
                        // Send SYN_ACK
                        sendTCPPacket(newFd, SYN_ACK, NULL, FALSE);
                        dbg(TRANSPORT_CHANNEL, "SYN_ACK sent on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
                        // Set state
                        sockets[newFd-1].state = SYN_RCVD;
                        // Add the new fd to the socket map
                        socketId = (((uint32_t)TOS_NODE_ID) << 24) | (((uint32_t)tcp_rcvd->destPort) << 16) | (((uint32_t)src) << 8) | (((uint32_t)tcp_rcvd->srcPort));
                        call SocketMap.insert(socketId, newFd);
                        return SUCCESS;
                    }
                } else {
                    // Look up the active socket
                    fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
                    if(fd == 0)
                        break;
                    if(newFd > 0) {
                        // Send SYN_ACK
                        sendTCPPacket(newFd, SYN_ACK, NULL, FALSE);
                        // Set state
                        sockets[newFd-1].state = SYN_RCVD;
                        return SUCCESS;
                    }
                }
                break;
            case SYN_ACK:
                dbg(TRANSPORT_CHANNEL, "SYN_ACK received on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
                // Look up the socket
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
                if(sockets[fd-1].state == SYN_SENT) {
                    // Send ACK
                    sockets[fd-1].stopAndWait = tcp_rcvd->ack;
                    sendTCPPacket(fd, ACK, NULL, FALSE);
                    dbg(TRANSPORT_CHANNEL, "ACK sent on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
                    // Set state
                    sockets[fd-1].state = ESTABLISHED;
                    dbg(TRANSPORT_CHANNEL, "CONNECTION ESTABLISHED!\n");
                    return SUCCESS;
                }
                break;
            case FIN:
                // Look up the socket
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
                dbg(TRANSPORT_CHANNEL, "FIN Received\n");
                switch(sockets[fd-1].state) {
                    case ESTABLISHED:
                        dbg(TRANSPORT_CHANNEL, "Going to CLOSE_WAIT.\n");
                        // Send ACK
                        dbg(TRANSPORT_CHANNEL, "Sending ACK.\n");
                        sendTCPPacket(fd, ACK, NULL, FALSE);
                        sockets[fd-1].RTX = call RetransmissionTimer.getNow();
                        calculateRTO(fd);
                        // Set state
                        sockets[fd-1].state = CLOSE_WAIT;
                        return SUCCESS;
                    case FIN_WAIT_1:
                        // Send ACK
                        sendTCPPacket(fd, ACK, NULL, FALSE);
                        // Set state
                        sockets[fd-1].state = CLOSING;
                        return SUCCESS;
                    case FIN_WAIT_2:
                        // Send ACK
                        sendTCPPacket(fd, ACK, NULL, FALSE);
                        // Set state
                        sockets[fd-1].state = TIME_WAIT;
                        return SUCCESS;
                }
                break;
            case FIN_ACK:
                // Look up the socket
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
                switch(sockets[fd-1].state) {
                    case FIN_WAIT_1:
                        // Send ACK
                        sendTCPPacket(fd, ACK, NULL, FALSE);
                        // Go to time_wait
                        return SUCCESS;             
                }
                break;
        }
        return FAIL;
    }

    /**
    * Read from the socket and write this data to the buffer. This data
    * is obtained from your TCP implimentation.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that is attempting a read.
    * @param
    *    uint8_t *buff: the buffer that is being written.
    * @param
    *    uint16_t bufflen: the amount of data that can be written to the
    *       buffer.
    * @Side For your project, only server side. This could be both though.
    * @return uint16_t - return the amount of data you are able to read
    *    from the pass buffer. This may be shorter then bufflen
    */
    command uint16_t Transport.read(socket_t fd, uint8_t *buff, uint16_t bufflen) {
        uint16_t bytesRead = 0, data;
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS || sockets[fd-1].state != ESTABLISHED) {
            return 0;
        }
        // Read all possible data from the given socket
        //printSocket(fd);
        // while(bytesRead < bufflen && sockets[fd-1].lastRead < sockets[fd-1].lastRcvd) {
        //     //dbg(TRANSPORT_CHANNEL, "Odd lastRead\n");
        //     //dbg(TRANSPORT_CHANNEL, "Server: lastRead: %u\n", sockets[fd-1].lastRead);
        //     memcpy(buff, &sockets[fd-1].rcvdBuff[sockets[fd-1].lastRead], 1);
        //     if((sockets[fd-1].lastRead & 1) == 0) {
        //         data = ((uint16_t)*(buff-1) << 8) | (uint16_t)*(buff-2);
        //         //dbg(TRANSPORT_CHANNEL, "Server: Data on read: %u\n", data);
        //     }
        //     buff++;
        //     bytesRead++;
        //     sockets[fd-1].lastRead++;
        //     if(sockets[fd-1].lastRead == SOCKET_BUFFER_SIZE-1) {
        //         sockets[fd-1].lastRead = 0;
        //     }
        // }
        if(sockets[fd-1].lastRead >= SOCKET_BUFFER_SIZE && calculateReceiveWindow(fd) > 0) {
            sockets[fd-1].lastRead = 0;
        }
        while(bytesRead < bufflen && calculateReceiveWindow(fd) > 0) {
            memcpy(buff, &sockets[fd-1].rcvdBuff[sockets[fd-1].lastRead], 1);
            buff++;
            bytesRead++;
            sockets[fd-1].lastRead++;
            // if((sockets[fd-1].lastRead & 1) == 0) {
            //     data = ((uint16_t)*(buff-1) << 8) | (uint16_t)*(buff-2);
            //     dbg(TRANSPORT_CHANNEL, "Server at %u: Data on read: %u\n", sockets[fd-1].lastRead, data);
            // }
            if(sockets[fd-1].lastRead >= SOCKET_BUFFER_SIZE && calculateReceiveWindow(fd) > 0) {
                sockets[fd-1].lastRead = 0;
            }
        }


        //dbg(TRANSPORT_CHANNEL, "Server: bytesRead: %u\n", bytesRead);
        //dbg(TRANSPORT_CHANNEL, "Server: lastRead: %u\n", sockets[fd-1].lastRead);
        // Return number of bytes written
        return bytesRead;
    }

    /**
    * Attempts a connection to an address.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that you are attempting a connection with. 
    * @param
    *    socket_addr_t *addr: the destination address and port where
    *       you will atempt a connection.
    * @side Client
    * @return socket_t - returns SUCCESS if you are able to attempt
    *    a connection with the fd passed, else return FAIL.
    */
    command error_t Transport.connect(socket_t fd, socket_addr_t * dest) {
        uint32_t socketId = 0;
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS || sockets[fd-1].state != NAMED) {
            return FAIL;
        }
        // Remove the old socket from the 
        socketId = (((uint32_t)sockets[fd-1].src.addr) << 24) | (((uint32_t)sockets[fd-1].src.port) << 16);
        call SocketMap.remove(socketId);
        // Add the dest to the socket
        sockets[fd-1].dest.addr = dest->addr;
        sockets[fd-1].dest.port = dest->port;
        sockets[fd-1].type = CLIENT;
        // Send SYN
        sendTCPPacket(fd, SYN, NULL, FALSE);
        // Add new socket to SocketMap
        socketId |= (((uint32_t)dest->addr) << 8) | ((uint32_t)dest->port);
        call SocketMap.insert(socketId, fd);
        // Set SYN_SENT
        sockets[fd-1].state = SYN_SENT;
        dbg(TRANSPORT_CHANNEL, "SYN sent on node %u via port %u\n", TOS_NODE_ID, sockets[fd-1].src.port);
        return SUCCESS;
    }

    /**
    * Closes the socket.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that you are closing.
    * @side Client/Server
    * @return socket_t - returns SUCCESS if you are able to attempt
    *    a closure with the fd passed, else return FAIL.
    */
    command error_t Transport.close(socket_t fd) {
        uint32_t socketId = 0;
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        switch(sockets[fd-1].state) {
            case LISTEN:
                // Remove from SocketMap
                socketId = (((uint32_t)sockets[fd-1].src.addr) << 24) | (((uint32_t)sockets[fd-1].src.port) << 16);
                call SocketMap.remove(socketId);
                // Free the port
                ports[sockets[fd-1].src.port] = FALSE;
                // Zero the socket
                zeroSocket(fd);
                // Set CLOSED
                sockets[fd-1].state = CLOSED;
                return SUCCESS;
            case SYN_SENT:
                // Remove from SocketMap
                socketId = (((uint32_t)sockets[fd-1].src.addr) << 24) | (((uint32_t)sockets[fd-1].src.port) << 16) | (((uint32_t)sockets[fd-1].dest.addr) << 8) | ((uint32_t)sockets[fd-1].dest.port);
                call SocketMap.remove(socketId);
                // Zero the socket
                zeroSocket(fd);
                // Set CLOSED
                sockets[fd-1].state = CLOSED;
                return SUCCESS;
            case ESTABLISHED:
            case SYN_RCVD:
                dbg(TRANSPORT_CHANNEL, "Sending FIN\n");
                // Initiate FIN sequence
                sendTCPPacket(fd, FIN, NULL, FALSE);
                // Set timeout
                //sockets[fd-1].RTO = call RetransmissionTimer.getNow() + 2*sockets[fd-1].RTT;
                // Set FIN_WAIT_1
                dbg(TRANSPORT_CHANNEL, "Going to FIN_WAIT_1\n");
                sockets[fd-1].state = FIN_WAIT_1;
                return SUCCESS;
            case CLOSE_WAIT:
                // Continue FIN sequence
                sendTCPPacket(fd, FIN, NULL, FALSE);
                // Set timeout
                //sockets[fd-1].RTO = call RetransmissionTimer.getNow() + 2*sockets[fd-1].RTT;
                // Set LAST_ACK
                sockets[fd-1].state = LAST_ACK;
                return SUCCESS;
        }
        return FAIL;
    }

    /**
    * A hard close, which is not graceful. This portion is optional.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that you are hard closing.
    * @side Client/Server
    * @return socket_t - returns SUCCESS if you are able to attempt
    *    a closure with the fd passed, else return FAIL.
    */
    command error_t Transport.release(socket_t fd) {
        uint8_t i;
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        // Clear socket info
        zeroSocket(fd);
        return SUCCESS;
    }

    /**
    * Listen to the socket and wait for a connection.
    * @param
    *    socket_t fd: file descriptor that is associated with the socket
    *       that you are hard closing. 
    * @side Server
    * @return error_t - returns SUCCESS if you are able change the state 
    *   to listen else FAIL.
    */
    command error_t Transport.listen(socket_t fd) {        
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        // If socket is bound
        if(sockets[fd-1].state == NAMED) {
            // Set socket to LISTEN
            sockets[fd-1].state = LISTEN;
            // Add socket to SocketMap
            return SUCCESS;
        } else {
            return FAIL;
        }
    }

}