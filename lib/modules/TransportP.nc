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
    uses interface Timer<TMilli> as TransmissionTimer;
    uses interface NeighborDiscovery;
    uses interface DistanceVectorRouting;
    uses interface Hashmap<uint8_t> as SocketMap;
}

implementation{
    pack ipPack;
    tcp_pack tcpPack;
    bool ports[NUM_SUPPORTED_PORTS];
    socket_store_t sockets[MAX_NUM_OF_SOCKETS];
    uint16_t dropCounter = 10;

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

    uint32_t min(uint32_t a, uint32_t b) {
        if(a <= b)
            return a;
        else
            return b;
    }

    uint32_t max(uint32_t a, uint32_t b) {
        if(a <= b)
            return b;
        else
            return a;
    }    

    uint32_t absDiff(uint32_t a, uint32_t b) {
        if(a < b)
            return b - a;
        else
            return a - b;
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

    uint16_t getReceiverReadable(uint8_t fd) {
        uint16_t lastRead, nextExpected;
        lastRead = sockets[fd-1].lastRead % SOCKET_BUFFER_SIZE;
        nextExpected = sockets[fd-1].nextExpected % SOCKET_BUFFER_SIZE;
        if(lastRead < nextExpected)
            return nextExpected - lastRead - 1;
        else
            return SOCKET_BUFFER_SIZE - lastRead + nextExpected - 1;        
    }

    uint16_t getSenderDataInFlight(uint8_t fd) {
        uint16_t lastAck, lastSent;
        lastAck = sockets[fd-1].lastAck % SOCKET_BUFFER_SIZE;
        lastSent = sockets[fd-1].lastSent % SOCKET_BUFFER_SIZE;
        if(lastAck <= lastSent)
            return lastSent - lastAck;
        else
            return SOCKET_BUFFER_SIZE - lastAck + lastSent;
    }

    uint16_t getSendBufferOccupied(uint8_t fd) {
        uint8_t lastSent, lastWritten;
        lastSent = sockets[fd-1].lastSent % SOCKET_BUFFER_SIZE;
        lastWritten = sockets[fd-1].lastWritten % SOCKET_BUFFER_SIZE;
        if(lastSent <= lastWritten)
            return lastWritten - lastSent;
        else
            return lastWritten + (SOCKET_BUFFER_SIZE - lastSent);
    }

    uint16_t getReceiveBufferOccupied(uint8_t fd) {
        uint8_t lastRead, lastRcvd;
        lastRead = sockets[fd-1].lastRead % SOCKET_BUFFER_SIZE;
        lastRcvd = sockets[fd-1].lastRcvd % SOCKET_BUFFER_SIZE;
        if(lastRead <= lastRcvd)
            return lastRcvd - lastRead;
        else
            return lastRcvd + (SOCKET_BUFFER_SIZE - lastRead);
    }

    uint16_t getSendBufferAvailable(uint8_t fd) {
        uint8_t lastAck, lastWritten;
        lastAck = sockets[fd-1].lastAck % SOCKET_BUFFER_SIZE;
        lastWritten = sockets[fd-1].lastWritten % SOCKET_BUFFER_SIZE;
        if(lastAck <= lastWritten)
            return lastAck + (SOCKET_BUFFER_SIZE - lastWritten) - 1;
        else
            return lastAck - lastWritten - 1;
    }

    uint16_t getReceiveBufferAvailable(uint8_t fd) {
        uint8_t lastRead, lastRcvd;
        lastRead = sockets[fd-1].lastRead % SOCKET_BUFFER_SIZE;
        lastRcvd = sockets[fd-1].lastRcvd % SOCKET_BUFFER_SIZE;
        if(lastRead <= lastRcvd)
            return lastRead + (SOCKET_BUFFER_SIZE - lastRcvd) - 1;
        else
            return lastRead - lastRcvd - 1;
    }

    uint8_t calcAdvWindow(uint8_t fd) {
        return SOCKET_BUFFER_SIZE - getReceiverReadable(fd) - 1;
    }

    uint8_t calcEffWindow(uint8_t fd) {
        return sockets[fd-1].advertisedWindow - getSenderDataInFlight(fd);
    }

    uint8_t calcCongWindow(uint8_t fd) {
        return (sockets[fd-1].cwnd * TCP_PACKET_PAYLOAD_SIZE) + ((sockets[fd-1].cwndRemainder * TCP_PACKET_PAYLOAD_SIZE) / sockets[fd-1].cwnd);
    }

    void calcRTT(uint8_t fd, uint16_t ack) {
        uint32_t now = call TransmissionTimer.getNow();
        if(sockets[fd-1].RTT_SEQ == ack && sockets[fd-1].IS_VALID_RTT) {
            // dbg(TRANSPORT_CHANNEL, "RTT: %u, RTT_VAR: %u, Now %u, RTX %u\n", sockets[fd-1].RTT, sockets[fd-1].RTT_VAR, now, sockets[fd-1].RTX);
            sockets[fd-1].RTT = ((TCP_RTT_ALPHA) * (sockets[fd-1].RTT) + (100-TCP_RTT_ALPHA) * (now - sockets[fd-1].RTX)) / 100;
            sockets[fd-1].RTT_VAR = ((TCP_RTT_BETA) * (sockets[fd-1].RTT_VAR) + (100-TCP_RTT_BETA) * absDiff(sockets[fd-1].RTT_VAR, now - sockets[fd-1].RTX)) / 100;
            // dbg(TRANSPORT_CHANNEL, "RTT: %u, RTT_VAR: %u\n", sockets[fd-1].RTT, sockets[fd-1].RTT_VAR);
        } else if(sockets[fd-1].RTT_SEQ == ack) {
            // dbg(TRANSPORT_CHANNEL, "Received ack but RTT invalid.\n");
            sockets[fd-1].IS_VALID_RTT = TRUE;
        }
    }

    void calcRTO(uint8_t fd) {
        sockets[fd-1].RTT_SEQ = sockets[fd-1].lastSent + 1;
        sockets[fd-1].RTX = call TransmissionTimer.getNow();
        sockets[fd-1].RTO = sockets[fd-1].RTX + sockets[fd-1].RTT + (4 * sockets[fd-1].RTT_VAR);
    }

    uint8_t sendTCPPacket(uint8_t fd, uint8_t flags) {
        uint8_t length, bytes = 0;
        uint8_t* payload = (uint8_t*)tcpPack.payload;
        // Set up packet info
        tcpPack.srcPort = sockets[fd-1].src.port;
        tcpPack.destPort = sockets[fd-1].dest.port;
        tcpPack.flags = flags;
        tcpPack.advertisedWindow = calcAdvWindow(fd);
        tcpPack.ack = sockets[fd-1].nextExpected;
        // Send initial sequence number or next expected
        if(flags == SYN) {
            tcpPack.seq = sockets[fd-1].lastSent;
        } else {
            tcpPack.seq = sockets[fd-1].lastSent + 1;
        }
        if(flags == DATA) {
            // dbg(TRANSPORT_CHANNEL, "Sending seq: %u\n", tcpPack.seq);
            // Choose the min of the effective window, the number of bytes available to send, and the max packet size
            length = min(min(calcEffWindow(fd), calcCongWindow(fd) - getSenderDataInFlight(fd)), min(getSendBufferOccupied(fd), TCP_PACKET_PAYLOAD_SIZE));
            if(length == 0) {
                return 0;
            }
            while(bytes < length) {
                memcpy(payload+bytes, &sockets[fd-1].sendBuff[(++sockets[fd-1].lastSent) % SOCKET_BUFFER_SIZE], 1);
                bytes += 1;
            }
            tcpPack.length = length;
        }
        if(flags == ACK) {
            dbg(TRANSPORT_CHANNEL, "Sending ACK: %u\n", tcpPack.ack);
        }
        makePack(&ipPack, TOS_NODE_ID, sockets[fd-1].dest.addr, BETTER_TTL, PROTOCOL_TCP, 0, &tcpPack, sizeof(tcp_pack));
        call DistanceVectorRouting.routePacket(&ipPack);
        return bytes;
    }

    void sendWindow(uint8_t fd) {
        uint16_t bytesRemaining = min(calcCongWindow(fd), min(getSendBufferOccupied(fd), calcEffWindow(fd)));
        uint8_t bytesSent;
        bool firstPacket = TRUE;
        while(bytesRemaining > 0 && bytesSent > 0 && calcCongWindow(fd) > getSenderDataInFlight(fd)) {
            if(firstPacket)
                dbg(TRANSPORT_CHANNEL, "Data in flight %u, CWND %u, SSTHRESH %u, EWND %u\n", getSenderDataInFlight(fd), calcCongWindow(fd), sockets[fd-1].ssthresh, calcEffWindow(fd));
            bytesSent = sendTCPPacket(fd, DATA);
            bytesRemaining -= bytesSent;
            if(firstPacket && bytesSent > 0) {
                calcRTO(fd);
                firstPacket = FALSE;
            }
        }
    }

    bool handleFT(uint8_t fd, uint16_t ack) {
        if(sockets[fd-1].dupAck.seq == ack) {
            sockets[fd-1].dupAck.count++;
            if(sockets[fd-1].dupAck.count == TCP_FT_DUP) {
                dbg(TRANSPORT_CHANNEL, "Fast retransmit: %u\n", sockets[fd-1].lastAck + 1);
                // cwnd = cwnd / 2
                sockets[fd-1].cwnd = max(sockets[fd-1].cwnd >> 1, TCP_MIN_CWND);
                sockets[fd-1].cwndRemainder >>= 1;
                // ssthresh = cwnd / 2
                sockets[fd-1].ssthresh = calcCongWindow(fd);
                // AIMD
                sockets[fd-1].cwndStrategy = AIMD;
                // Retransmit
                sockets[fd-1].lastSent = sockets[fd-1].lastAck;                
                sendWindow(fd);
                sockets[fd-1].dupAck.count = 0;
                return TRUE;
            }
        } else {
            sockets[fd-1].dupAck.seq = ack;
            sockets[fd-1].dupAck.count = 1;
        }
        return FALSE;
    }

    void readInData(uint8_t fd, tcp_pack* tcp_rcvd) {
        uint16_t bytesRead = 0;
        uint8_t* payload = (uint8_t*)tcp_rcvd->payload;
        if(getReceiveBufferAvailable(fd) < tcp_rcvd->length || sockets[fd-1].nextExpected != tcp_rcvd->seq || tcp_rcvd->flags != DATA) {
            // dbg(TRANSPORT_CHANNEL, "Dropping packet. Can't fit data in buffer OR incorrect seq num. Length: %u. Adv Window: %u, Buffer Available: %u\n", tcp_rcvd->length, sockets[fd-1].advertisedWindow, getReceiveBufferAvailable(fd));
            return;
        }
        // dbg(TRANSPORT_CHANNEL, "Reading in data with sequence number %u.\n", tcp_rcvd->seq);
        while(bytesRead < tcp_rcvd->length && getReceiveBufferAvailable(fd) > 0) {
            memcpy(&sockets[fd-1].rcvdBuff[(++sockets[fd-1].lastRcvd) % SOCKET_BUFFER_SIZE], payload+bytesRead, 1);
            bytesRead += 1;
        }
        // dbg(TRANSPORT_CHANNEL, "Last Received %u.\n", sockets[fd-1].lastRcvd);
        sockets[fd-1].nextExpected = sockets[fd-1].lastRcvd + 1;
        // dbg(TRANSPORT_CHANNEL, "Next Expected %u.\n", sockets[fd-1].nextExpected);
        sockets[fd-1].advertisedWindow = calcAdvWindow(fd);
        // dbg(TRANSPORT_CHANNEL, "Advertised window %u.\n", sockets[fd-1].advertisedWindow);
        if(sockets[fd-1].advertisedWindow == 0) {
            // dbg(TRANSPORT_CHANNEL, "Setting Timeout. Adv Win. %u.\n", sockets[fd-1].advertisedWindow);
            sockets[fd-1].deadlockAck = TRUE;
            sockets[fd-1].RTO = call TransmissionTimer.getNow() + TCP_DEADLOCK_ACK_RTO;
        }
    }

    void printSenderInfo(uint8_t fd) {
        dbg(TRANSPORT_CHANNEL, "fd %u, socket %u\n", fd, fd-1);
        dbg(TRANSPORT_CHANNEL, "Last Acked %u.\n", sockets[fd-1].lastAck);
        dbg(TRANSPORT_CHANNEL, "Last Sent %u.\n", sockets[fd-1].lastSent);
        dbg(TRANSPORT_CHANNEL, "Last Writtin %u.\n", sockets[fd-1].lastWritten);
        dbg(TRANSPORT_CHANNEL, "Effective window %u.\n", calcEffWindow(fd));
    }

    void printReceiverInfo(uint8_t fd) {
        dbg(TRANSPORT_CHANNEL, "fd %u, socket %u\n", fd, fd-1);
        dbg(TRANSPORT_CHANNEL, "Last Read %u.\n", sockets[fd-1].lastRead);
        dbg(TRANSPORT_CHANNEL, "Last Received %u.\n", sockets[fd-1].lastRcvd);
        dbg(TRANSPORT_CHANNEL, "Next Expected %u.\n", sockets[fd-1].nextExpected);
        dbg(TRANSPORT_CHANNEL, "Advertised window %u.\n", sockets[fd-1].advertisedWindow);
    }    

    void zeroTCPPacket() {
        uint8_t i;
        for(i = 0; i < TCP_PACKET_PAYLOAD_SIZE; i++) {
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
        i = (uint8_t)(call Random.rand16() % (SOCKET_BUFFER_SIZE<<1));
        sockets[fd-1].lastWritten = i;
        sockets[fd-1].lastAck = i;
        sockets[fd-1].lastSent = i;
        sockets[fd-1].lastRead = 0;
        sockets[fd-1].lastRcvd = 0;
        sockets[fd-1].nextExpected = 0;
        sockets[fd-1].RTT = TCP_INITIAL_RTT;
        sockets[fd-1].RTT_VAR = TCP_INITIAL_RTT_VAR;
        sockets[fd-1].RTO = TCP_INITIAL_RTO;
        sockets[fd-1].RTT_SEQ = i;
        sockets[fd-1].RTX = 0;
        sockets[fd-1].IS_VALID_RTT = TRUE;
        sockets[fd-1].advertisedWindow = SOCKET_BUFFER_SIZE - 1;
        sockets[fd-1].cwnd = TCP_MIN_CWND;
        sockets[fd-1].cwndRemainder = 0;
        sockets[fd-1].cwndStrategy = SLOW_START;
        sockets[fd-1].ssthresh = TCP_MAX_CWND*TCP_PACKET_PAYLOAD_SIZE;
        sockets[fd-1].dupAck.seq = 0;
        sockets[fd-1].dupAck.count = 0;
        sockets[fd-1].deadlockAck = FALSE;
    }

    uint8_t cloneSocket(uint8_t fd, uint16_t addr, uint8_t port) {
        uint8_t i;
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if(sockets[i].state == CLOSED) {
                sockets[i].src.port = sockets[fd-1].src.port;
                sockets[i].src.addr = sockets[fd-1].src.addr;
                sockets[i].dest.addr = addr;
                sockets[i].dest.port = port;
                return i+1;
            }
        }
        return 0;
    }

    /*
    * Interface methods
    */

    command void Transport.start() {
        uint8_t i;
        call TransmissionTimer.startOneShot(60*1024);
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            zeroSocket(i+1);
        }
    }

    event void TransmissionTimer.fired() {
        uint8_t i;
        if(call TransmissionTimer.isOneShot()) {
            dbg(TRANSPORT_CHANNEL, "TCP starting on node %u\n", TOS_NODE_ID);
            call TransmissionTimer.startPeriodic(512 + (uint16_t) (call Random.rand16()%100));
        }
        // Iterate over sockets
            // If timeout -> retransmit
            // If ESTABLISHED -> attempt to send packets
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if(sockets[i].RTO < call TransmissionTimer.getNow()) {
                // dbg(TRANSPORT_CHANNEL, "Retransmitting!\n");
                switch(sockets[i].state) {
                    case ESTABLISHED:
                        if(sockets[i].lastSent != sockets[i].lastAck && sockets[i].type == CLIENT && getSenderDataInFlight(i+1) > 0) {
                            dbg(TRANSPORT_CHANNEL, "Resending at %u. Data in flight %u\n", sockets[i].lastSent+1, getSenderDataInFlight(i+1));
                            // Go back N
                            sockets[i].lastSent = sockets[i].lastAck;
                            // Adjust ssthresh, cwnd
                            sockets[i].ssthresh = (max(sockets[i].cwnd >> 1,TCP_MIN_CWND) * TCP_PACKET_PAYLOAD_SIZE) + (sockets[i].cwndRemainder >> 1);
                            sockets[i].cwnd = TCP_MIN_CWND;
                            sockets[i].cwndRemainder = 0;
                            if(calcCongWindow(i+1) < sockets[i].ssthresh)
                                sockets[i].cwndStrategy = SLOW_START;
                            else
                                sockets[i].cwndStrategy = AIMD;
                            // Resend window
                            sendWindow(i+1);
                            // Double the RTO
                            sockets[i].RTO += sockets[i].RTT + (4 * sockets[i].RTT_VAR);
                            // Don't calc RTT on retransmission
                            sockets[i].IS_VALID_RTT = FALSE;
                            continue;
                        } else if(sockets[i].type == SERVER && sockets[i].deadlockAck) {
                            // dbg(TRANSPORT_CHANNEL, "Sending ACK. Adv. Win. %u\n", calcAdvWindow(i+1));
                            sendTCPPacket(i+1, ACK);
                            sockets[i].RTO = call TransmissionTimer.getNow() + TCP_DEADLOCK_ACK_RTO;                            
                        }
                        break;
                    case SYN_SENT:
                        // Resend SYN
                        sendTCPPacket(i+1, SYN);
                        calcRTO(i+1);
                        break;
                    case SYN_RCVD:
                        // Resend SYN_ACK
                        sendTCPPacket(i+1, SYN_ACK);
                        calcRTO(i+1);
                        break;
                    case CLOSE_WAIT:
                        // Resend FIN
                        dbg(TRANSPORT_CHANNEL, "Sending last FIN. Going to LAST_ACK.\n");
                        sendTCPPacket(i+1, FIN);
                        sockets[i].state = LAST_ACK;
                        // Set final RTO
                        sockets[i].RTO = call TransmissionTimer.getNow() + (4 * sockets[i].RTT);
                        break;
                    case FIN_WAIT_1:
                    case LAST_ACK:
                        // Resend FIN
                        sendTCPPacket(i+1, FIN);
                        calcRTO(i+1);
                        break;
                    case TIME_WAIT:
                        // Timeout! Close the connection
                        sockets[i].state = CLOSED;
                        dbg(TRANSPORT_CHANNEL, "CONNECTION CLOSED!\n");
                }
            }
            if(sockets[i].state == ESTABLISHED && sockets[i].type == CLIENT) {
                // Send window
                sendWindow(i+1);
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
        // Check socket state and port
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
        }
        return FAIL;
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
        uint16_t bytesWritten = 0;
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS || sockets[fd-1].state != ESTABLISHED) {
            return 0;
        }
        // Write all possible data to the given socket
        while(bytesWritten < bufflen && getSendBufferAvailable(fd) > 0) {
            memcpy(&sockets[fd-1].sendBuff[++sockets[fd-1].lastWritten % SOCKET_BUFFER_SIZE], buff+bytesWritten, 1);
            bytesWritten++;
        }
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
                // if(--dropCounter == 0) {
                //     dbg(TRANSPORT_CHANNEL, "Dropping tenth packet\n");
                //     dropCounter = 10;
                //     return SUCCESS;
                // }
                // Find socket fd
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);                
                switch(sockets[fd-1].state) {
                    case SYN_RCVD:
                        dbg(TRANSPORT_CHANNEL, "CONNECTION ESTABLISHED!\n");
                        sockets[fd-1].state = ESTABLISHED;
                    case ESTABLISHED:
                        if(sockets[fd-1].deadlockAck && tcp_rcvd->seq == sockets[fd-1].nextExpected)
                            sockets[fd-1].deadlockAck = FALSE;
                        //dbg(TRANSPORT_CHANNEL, "Data received on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
                        readInData(fd, tcp_rcvd);
                        // Send ACK
                        sendTCPPacket(fd, ACK);                        
                        return SUCCESS;
                }
                break;
            case ACK:
                // Find socket fd
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
                if(fd == 0)
                    break;
                // Calculate RTT
                calcRTT(fd, tcp_rcvd->ack);
                //dbg(TRANSPORT_CHANNEL, "RTT now %u\n", sockets[fd-1].RTT);
                switch(sockets[fd-1].state) {
                    case SYN_RCVD:
                        dbg(TRANSPORT_CHANNEL, "ACK received on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
                        // Set state
                        sockets[fd-1].state = ESTABLISHED;
                        dbg(TRANSPORT_CHANNEL, "CONNECTION ESTABLISHED!\n");
                        return SUCCESS;
                    case ESTABLISHED:
                        // Handle Fast Retransmit
                        if(!handleFT(fd, tcp_rcvd->ack)) {
                            // Increase cwnd based on cwndStrategy
                            switch(sockets[fd-1].cwndStrategy) {
                                case SLOW_START:
                                    // Add packet to cwnd
                                    sockets[fd-1].cwnd++;
                                    // Check if cwnd >= ssthresh
                                    if(calcCongWindow(fd) >= sockets[fd-1].ssthresh) {
                                        sockets[fd-1].cwndStrategy = AIMD;
                                    }
                                break;
                                case AIMD:
                                    // Check if cwnd at max
                                    if(sockets[fd-1].cwnd < TCP_MAX_CWND) {
                                        // Increment cwndRemainder
                                        sockets[fd-1].cwndRemainder++;
                                    }
                                    // Check if cwnd == cwndRemainder
                                    if(sockets[fd-1].cwnd == sockets[fd-1].cwndRemainder) {
                                        sockets[fd-1].cwnd++;
                                        sockets[fd-1].cwndRemainder = 0;
                                    }
                            }
                        }
                        // dbg(TRANSPORT_CHANNEL, "ACK received. Adv. Win. %u\n", tcp_rcvd->advertisedWindow);
                        // Adjust last ack and adv window
                        sockets[fd-1].lastAck = tcp_rcvd->ack - 1;
                        sockets[fd-1].advertisedWindow = tcp_rcvd->advertisedWindow;
                        return SUCCESS;
                    case FIN_WAIT_1:
                        dbg(TRANSPORT_CHANNEL, "ACK received on node %u via port %u. Going to FIN_WAIT_2.\n", TOS_NODE_ID, tcp_rcvd->destPort);
                        // Set state
                        sockets[fd-1].state = FIN_WAIT_2;
                        return SUCCESS;
                    case CLOSING:
                        dbg(TRANSPORT_CHANNEL, "Received last ack. Going to TIME_WAIT.\n");
                        // Set state
                        sockets[fd-1].state = TIME_WAIT;
                        sockets[fd-1].RTO = call TransmissionTimer.getNow() + (4 * sockets[fd-1].RTT);
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
                // Check of connection already exists
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, package->src, tcp_rcvd->srcPort);
                if(fd != 0)
                    break;
                // Find socket fd
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, 0, 0);                
                if(fd == 0)
                    break;
                switch(sockets[fd-1].state) {
                    case LISTEN:
                        // Create new active socket
                        newFd = cloneSocket(fd, package->src, tcp_rcvd->srcPort);
                        if(newFd > 0) {
                            // Add new connection to fd connection queue
                            addConnection(fd, newFd);
                            // Set state
                            dbg(TRANSPORT_CHANNEL, "SYN recieved on node %u via port %u with seq %u\n", TOS_NODE_ID, tcp_rcvd->destPort, tcp_rcvd->seq);
                            sockets[newFd-1].state = SYN_RCVD;
                            sockets[newFd-1].lastRead = tcp_rcvd->seq;
                            sockets[newFd-1].lastRcvd = tcp_rcvd->seq;
                            sockets[newFd-1].nextExpected = tcp_rcvd->seq + 1;
                            // Send SYN_ACK
                            sendTCPPacket(newFd, SYN_ACK);
                            dbg(TRANSPORT_CHANNEL, "SYN_ACK sent on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
                            // Add the new fd to the socket map
                            socketId = (((uint32_t)TOS_NODE_ID) << 24) | (((uint32_t)tcp_rcvd->destPort) << 16) | (((uint32_t)src) << 8) | (((uint32_t)tcp_rcvd->srcPort));
                            call SocketMap.insert(socketId, newFd);
                            return SUCCESS;
                        }                        
                }
                break;
            case SYN_ACK:                
                // Look up the socket
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
                if(fd == 0)
                    break;
                if(sockets[fd-1].state == SYN_SENT) {
                    dbg(TRANSPORT_CHANNEL, "SYN_ACK received on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
                    // Set the advertised window
                    sockets[fd-1].advertisedWindow = tcp_rcvd->advertisedWindow;              
                    sockets[fd-1].state = ESTABLISHED;
                    // Calculate RTT
                    calcRTT(fd, tcp_rcvd->ack);                    
                    // Send ACK
                    sendTCPPacket(fd, ACK);
                    calcRTO(fd);
                    dbg(TRANSPORT_CHANNEL, "ACK sent on node %u via port %u\n", TOS_NODE_ID, tcp_rcvd->destPort);
                    dbg(TRANSPORT_CHANNEL, "CONNECTION ESTABLISHED!\n");
                    return SUCCESS;
                }
                break;
            case FIN:
                // Find socket fd
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);                
                switch(sockets[fd-1].state) {
                    case ESTABLISHED:
                        dbg(TRANSPORT_CHANNEL, "FIN received. Going to CLOSE_WAIT. Sending ACK.\n");
                        // Send ACK
                        sendTCPPacket(fd, ACK);                        
                        // Set state
                        calcRTO(fd);
                        sockets[fd-1].state = CLOSE_WAIT;
                        return SUCCESS;
                    case FIN_WAIT_1:
                        dbg(TRANSPORT_CHANNEL, "Last FIN received. Sending ACK. Going to TIME_WAIT.\n");
                        // Send ACK
                        sendTCPPacket(fd, ACK);
                        // sockets[fd-1].state = CLOSING;                        
                        // Set state
                        sockets[fd-1].state = TIME_WAIT;
                        sockets[fd-1].RTO = call TransmissionTimer.getNow() + (4 * sockets[fd-1].RTT);
                        return SUCCESS;
                    case FIN_WAIT_2:
                    case TIME_WAIT:
                        // Send ACK
                        sendTCPPacket(fd, ACK);
                        // If not already in TIME_WAIT set state and new timeout
                        if(sockets[fd-1].state != TIME_WAIT) {
                            sockets[fd-1].state = TIME_WAIT;
                            sockets[fd-1].RTO = call TransmissionTimer.getNow() + (4 * sockets[fd-1].RTT);
                        }
                        return SUCCESS;
                }
                break;
            case FIN_ACK:
                // Find socket fd
                fd = findSocket(TOS_NODE_ID, tcp_rcvd->destPort, src, tcp_rcvd->srcPort);
                switch(sockets[fd-1].state) {
                    case FIN_WAIT_1:
                        // Send ACK
                        sendTCPPacket(fd, ACK);
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
        uint16_t bytesRead = 0;
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS || sockets[fd-1].state != ESTABLISHED) {
            return 0;
        }
        // Read all possible data from the given socket
        while(bytesRead < bufflen && getReceiverReadable(fd) > 0) {
            memcpy(buff, &sockets[fd-1].rcvdBuff[(++sockets[fd-1].lastRead) % SOCKET_BUFFER_SIZE], 1);
            buff++;
            bytesRead++;
        }
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
        sendTCPPacket(fd, SYN);
        calcRTO(fd);
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
                // Initiate FIN sequence
                sendTCPPacket(fd, FIN);
                // Set FIN_WAIT_1
                dbg(TRANSPORT_CHANNEL, "Sending FIN. Going to FIN_WAIT_1\n");
                sockets[fd-1].state = FIN_WAIT_1;
                return SUCCESS;
            case CLOSE_WAIT:
                // Continue FIN sequence
                sendTCPPacket(fd, FIN);
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
        // Check for valid socket
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