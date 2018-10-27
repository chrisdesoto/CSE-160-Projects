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
}

implementation{
    pack ipPack;
    tcp_pack tcpPack;
    bool ports[NUM_SUPPORTED_PORTS];
    socket_store_t sockets[MAX_NUM_OF_SOCKETS];

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, void *payload, uint8_t length);
    void sendTCPPacket(uint8_t fd, uint8_t flags, uint16_t* payload);

    command void Transport.start() {
        //call RetransmissionTimer.startOneShot(60*1024);
    }

    event void RetransmissionTimer.fired() {
        if(call RetransmissionTimer.isOneShot()) {
            call RetransmissionTimer.startPeriodic(1024);
        }
        // Iterate over sockets
            // If timeout -> retransmit
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
            return FAIL;
        }
        // For given socket
        for(i = 0; i < MAX_NUM_OF_SOCKETS-1; i++) {
            // If connectionQueue is not empty
            if(sockets[fd-1].connectionQueue[i] != 0) {
                conn = sockets[fd-1].connectionQueue[i];
                while(++i < MAX_NUM_OF_SOCKETS-1 && sockets[fd-1].connectionQueue[i] != 0) {
                    sockets[fd-1].connectionQueue[i-1] = sockets[fd-1].connectionQueue[i];
                }
                if(i == MAX_NUM_OF_SOCKETS-1) {
                    sockets[fd-1].connectionQueue[i-1] = 0;
                }
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
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        // Write to given socket until last written == last ack OR counter == bufflen
        // Return number of bytes written
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
        // Find corresponding socket
        // If socket found
            // Handle packet
        // Else drop packet
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
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        // Read to given socket until last read == last received
        // Return number of bytes written
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
    command error_t Transport.connect(socket_t fd, socket_addr_t * addr) {
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        // Initiate SYN sequence
        // Send SYN
        sendTCPPacket(fd, SYN, NULL);
        // Set timeout
        sockets[fd-1].RTX = call RetransmissionTimer.getNow() + 2*sockets[fd-1].RTT;
        // Set SYN-SENT
        sockets[fd-1].state = SYN_SENT;
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
        // Check for valid socket
        if(fd == 0 || fd > MAX_NUM_OF_SOCKETS) {
            return FAIL;
        }
        // Initite FIN sequence
        sendTCPPacket(fd, FIN, NULL);
        // Set timeout
        sockets[fd-1].RTX = call RetransmissionTimer.getNow() + 2*sockets[fd-1].RTT;
        // Set FIN_WAIT_1
        sockets[fd-1].state = FIN_WAIT_1;
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
        sockets[fd-1].lastWritten = 0;
        sockets[fd-1].lastAck = 0;
        sockets[fd-1].lastSent = 0;
        sockets[fd-1].lastRead = 0;
        sockets[fd-1].lastRcvd = 0;
        sockets[fd-1].nextExpected = 0;
        sockets[fd-1].RTT = 0;
        sockets[fd-1].advertisedWindow = 0;
        sockets[fd-1].effectiveWindow = 0;
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
        if(sockets[fd-1].state == OPENED) {
            // Set socket to LISTEN
            sockets[fd-1].state = LISTEN;
            return SUCCESS;
        } else {
            return FAIL;
        }
    }

    void sendTCPPacket(uint8_t fd, uint8_t flags, uint16_t* payload) {
        tcpPack.srcPort = sockets[fd-1].src.port;
        tcpPack.destPort = sockets[fd-1].dest.port;
        tcpPack.seq = sockets[fd-1].nextExpected;
        tcpPack.flags = flags;
        tcpPack.advertisedWindow = sockets[fd-1].advertisedWindow;
        if(flags == DATA)
            memcpy(tcpPack.payload, payload, TCP_PACKET_PAYLOAD_SIZE);
        makePack(&ipPack, TOS_NODE_ID, sockets[fd-1].dest.addr, BETTER_TTL, PROTOCOL_TCP, 0, &tcpPack, sizeof(tcp_pack));
        call DistanceVectorRouting.routePacket(&ipPack);
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

    uint8_t cloneSocket(socket_store_t* sock, uint16_t addr, uint8_t port, uint16_t rtt) {
        uint8_t i;
        for(i = 0; i < MAX_NUM_OF_SOCKETS; i++) {
            if(sockets[i].flags == 0) {
                sockets[i].state = SYN_RCVD;
                sockets[i].src.port = sock->src.port;
                sockets[i].src.addr = sock->src.addr;
                sockets[i].dest.addr = addr;
                sockets[i].dest.port = port;
                sockets[i].RTT = rtt;
            }
        }
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

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, void* payload, uint8_t length) {
        Package->src = src;
        Package->dest = dest;
        Package->TTL = TTL;
        Package->seq = seq;
        Package->protocol = protocol;
        memcpy(Package->payload, payload, length);
    }        

}