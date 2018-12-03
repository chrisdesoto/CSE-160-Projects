#include <string.h>
#include <Timer.h>
#include "../../includes/CommandMsg.h"
#include "../../includes/command.h"
#include "../../includes/channels.h"
#include "../../includes/socket.h"
#include "../../includes/tcp.h"
#include "../../includes/packet.h"
#include "../../includes/protocol.h"

#define CHAT_USERNAME_MAX_LENGTH 128
#define CHAT_APP_MAX_CONNS 5
#define CHAT_APP_BUFFER_SIZE 256
#define CHAT_APP_SERVER_ID 1
#define CHAT_APP_SERVER_PORT 41

module ChatAppP{
    provides interface ChatApp;

    uses interface SimpleSend as Sender;
    uses interface Random;
    uses interface Timer<TMilli> as ChatTimer;
    uses interface Transport;
    uses interface Hashmap<uint8_t> as ConnectionMap;
}

implementation{

    enum conn_type {
        OFF,
        SERVER,
        CLIENT
    };

    enum msg_type {
        HELLO,
        MSG,
        WHISPER,
        LISTUSR
    };

    typedef struct chat_conn_t {
        uint8_t readFd;
        uint8_t writeFd;
        uint8_t sendRead;
        uint8_t sendWritten;
        char sendBuffer[CHAT_APP_BUFFER_SIZE];
        uint8_t rcvdRead;
        uint8_t rcvdWritten;
        char rcvdBuffer[CHAT_APP_BUFFER_SIZE];
        char username[CHAT_USERNAME_MAX_LENGTH];
    } chat_conn_t;

    typedef struct chat_app_t {
        enum conn_type type;
        uint8_t numOfConns;
        uint8_t listenSockFd;
        chat_conn_t connections[CHAT_APP_MAX_CONNS];
    } chat_app_t;

    chat_app_t chatApp;

    uint32_t min(uint32_t a, uint32_t b) {
        if(a <= b)
            return a;
        else
            return b;
    }    

    // SERVER
    bool startsWith(char* a, char* b) {
        uint8_t len = strlen(b);
        while(len-- != 0) {
            if(a[len] != b[len]) {
                return FALSE;
            }
        }
        return TRUE;
    }

    // SERVER
    void processCommand(uint8_t idx) {
        char usrList[1024];
        uint8_t i, j;        
        // Check msg type
        // If HELLO
        if(startsWith(&chatApp.connections[idx].rcvdBuffer[chatApp.connections[idx].rcvdRead%CHAT_APP_BUFFER_SIZE], "hello ")) {
            // Add username to connection
            i = 0;
            while(chatApp.connections[idx].rcvdBuffer[(chatApp.connections[idx].rcvdRead+6+i)%CHAT_APP_BUFFER_SIZE] != '\r') {
                chatApp.connections[idx].username[i] = chatApp.connections[idx].rcvdBuffer[(chatApp.connections[idx].rcvdRead+6+i)%CHAT_APP_BUFFER_SIZE];
                i++;
            }
            chatApp.connections[idx].username[i] = '\0';
            dbg(CHAT_CHANNEL, "SERVER: Received hello from %s\n", chatApp.connections[idx].username);
            chatApp.connections[idx].rcvdRead += 6 + i + 2;
        // If MSG
        } else if(startsWith(&chatApp.connections[idx].rcvdBuffer[chatApp.connections[idx].rcvdRead%CHAT_APP_BUFFER_SIZE], "msg ")) {
            // Broadcast msg to all other chat clients
            dbg(CHAT_CHANNEL, "SERVER: Received msg from %s\n", chatApp.connections[idx].username);
            for(i = 0; i < CHAT_APP_MAX_CONNS; i++) {
                if(chatApp.connections[i].writeFd > 0 && idx != i) {
                    j = 0;
                    while(TRUE) {
                        chatApp.connections[i].sendBuffer[(chatApp.connections[i].sendWritten++)%CHAT_APP_BUFFER_SIZE] = chatApp.connections[idx].rcvdBuffer[(chatApp.connections[idx].rcvdRead+j)%CHAT_APP_BUFFER_SIZE];
                        if(j > 0 && chatApp.connections[idx].rcvdBuffer[(chatApp.connections[idx].rcvdRead+j)%CHAT_APP_BUFFER_SIZE] == '\n' && chatApp.connections[idx].rcvdBuffer[(chatApp.connections[idx].rcvdRead+j-1)%CHAT_APP_BUFFER_SIZE] == '\r') {
                            break;
                        }
                        j++;
                    }
                    dbg(CHAT_CHANNEL, "SERVER: Broadcasting to %s\n", /*&chatApp.connections[i].sendBuffer[(chatApp.connections[i].sendRead)%CHAT_APP_BUFFER_SIZE],*/ &chatApp.connections[i].username);
                }
            }
            chatApp.connections[idx].rcvdRead += j + 1;
        // If WHISPER
        } else if(startsWith(&chatApp.connections[idx].rcvdBuffer[chatApp.connections[idx].rcvdRead%CHAT_APP_BUFFER_SIZE], "whisper ")) {
            // Send only to enumerated user
            dbg(CHAT_CHANNEL, "SERVER: Received whisper from %s\n", chatApp.connections[idx].username);
            for(i = 0; i < CHAT_APP_MAX_CONNS; i++) {                
                if(chatApp.connections[i].writeFd > 0 && startsWith(&chatApp.connections[idx].rcvdBuffer[(chatApp.connections[idx].rcvdRead+8)%CHAT_APP_BUFFER_SIZE], &chatApp.connections[i].username)) {
                    dbg(CHAT_CHANNEL, "SERVER: Found user %s\n", chatApp.connections[i].username);
                    j = 0;
                    while(TRUE) {
                        chatApp.connections[i].sendBuffer[(chatApp.connections[i].sendWritten++)%CHAT_APP_BUFFER_SIZE] = chatApp.connections[idx].rcvdBuffer[(chatApp.connections[idx].rcvdRead+j)%CHAT_APP_BUFFER_SIZE];
                        if(j > 0 && chatApp.connections[idx].rcvdBuffer[(chatApp.connections[idx].rcvdRead+j)%CHAT_APP_BUFFER_SIZE] == '\n' && chatApp.connections[idx].rcvdBuffer[(chatApp.connections[idx].rcvdRead+j-1)%CHAT_APP_BUFFER_SIZE] == '\r') {
                            break;
                        }
                        j++;
                    }
                }
            }
            chatApp.connections[idx].rcvdRead += j + 1;
        // If LISTUSR
        } else if(startsWith(&chatApp.connections[idx].rcvdBuffer[chatApp.connections[idx].rcvdRead%CHAT_APP_BUFFER_SIZE], "listusr\r\n")) {
            // List all users currenly connected
            dbg(CHAT_CHANNEL, "SERVER: Received listusr from %s\n", chatApp.connections[idx].username);
            usrList[0] = '\0';
            strcat(usrList, "usrListReply");
            for(i = 0; i < CHAT_APP_MAX_CONNS; i++) {
                if(chatApp.connections[i].readFd > 0 && chatApp.connections[i].username[0] != '\0') {
                    strcat(usrList, " ");
                    strcat(usrList, chatApp.connections[i].username);
                }
            }
            strcat(usrList, "\r\n");
            j = 0;
            while(j < strlen(usrList)) {
                chatApp.connections[idx].sendBuffer[(chatApp.connections[idx].sendWritten++)%CHAT_APP_BUFFER_SIZE] = usrList[j++];
            }
            chatApp.connections[idx].rcvdRead += 9;
        }
    }

    uint16_t getRcvdBufferAvailable(uint8_t i) {
        if(chatApp.connections[i].rcvdRead <= chatApp.connections[i].rcvdWritten)
            return CHAT_APP_BUFFER_SIZE - (chatApp.connections[i].rcvdWritten%CHAT_APP_BUFFER_SIZE) + (chatApp.connections[i].rcvdRead%CHAT_APP_BUFFER_SIZE) - 1;
        else
            return (chatApp.connections[i].rcvdRead%CHAT_APP_BUFFER_SIZE) - (chatApp.connections[i].rcvdWritten%CHAT_APP_BUFFER_SIZE) - 1;
    }

    uint16_t getRcvdBufferOccupied(uint8_t i) {
        if(chatApp.connections[i].rcvdRead <= chatApp.connections[i].rcvdWritten)
            return (chatApp.connections[i].rcvdWritten%CHAT_APP_BUFFER_SIZE) - (chatApp.connections[i].rcvdRead%CHAT_APP_BUFFER_SIZE);
        else
            return CHAT_APP_BUFFER_SIZE - (chatApp.connections[i].rcvdRead%CHAT_APP_BUFFER_SIZE) + (chatApp.connections[i].rcvdWritten%CHAT_APP_BUFFER_SIZE);
    }

    uint16_t getSendBufferAvailable(uint8_t i) {
        if(chatApp.connections[i].sendRead <= chatApp.connections[i].sendWritten)
            return CHAT_APP_BUFFER_SIZE - (chatApp.connections[i].sendWritten%CHAT_APP_BUFFER_SIZE) + (chatApp.connections[i].sendRead%CHAT_APP_BUFFER_SIZE) - 1;
        else
            return (chatApp.connections[i].sendRead%CHAT_APP_BUFFER_SIZE) - (chatApp.connections[i].sendWritten%CHAT_APP_BUFFER_SIZE) - 1;
    }

    uint16_t getSendBufferOccupied(uint8_t i) {
        if(chatApp.connections[i].sendRead <= chatApp.connections[i].sendWritten)
            return (chatApp.connections[i].sendWritten%CHAT_APP_BUFFER_SIZE) - (chatApp.connections[i].sendRead%CHAT_APP_BUFFER_SIZE);
        else
            return CHAT_APP_BUFFER_SIZE - (chatApp.connections[i].sendRead%CHAT_APP_BUFFER_SIZE) + (chatApp.connections[i].sendWritten%CHAT_APP_BUFFER_SIZE);
    }

    uint8_t findFreeConn() {
        uint8_t i = 0;
        for(i = 0; i < CHAT_APP_MAX_CONNS; i++) {
            if(chatApp.connections[i].readFd == 0) {
                return i;
            }
        }
        return 255;
    }

    event void ChatTimer.fired() {
        uint8_t i;
        uint8_t newReadFd, bytes;
        socket_addr_t addr;
        // If chatApp.type == SERVER
        if(chatApp.type == SERVER) {
            // Accept new connections
            newReadFd = call Transport.accept(chatApp.listenSockFd);
            if(newReadFd > 0) {
                for(i = 0; i < CHAT_APP_MAX_CONNS; i++) {
                    if(chatApp.connections[i].readFd == 0) {
                        chatApp.connections[i].readFd = newReadFd;
                        chatApp.connections[i].writeFd = call Transport.socket();
                        if(chatApp.connections[i].writeFd == 0) {
                            // Error
                            dbg(CHAT_CHANNEL, "Failed to obtain socket. Exiting!");
                            break;
                        }
                        addr.addr = TOS_NODE_ID;
                        addr.port = 100+i;
                        if(call Transport.bind(chatApp.connections[i].writeFd, &addr) == FAIL) {
                            dbg(CHAT_CHANNEL, "Failed to bind sockets. Exiting!");
                            break;
                        }
                        // Get connection info and open a connection to the client
                        addr.addr = call Transport.getConnectionDest(newReadFd);
                        addr.port = CHAT_APP_SERVER_PORT;
                        // dbg(CHAT_CHANNEL, "newReadFd %u\n", newReadFd);
                        dbg(CHAT_CHANNEL, "Connecting back to client %u\n", addr.addr);
                        if(call Transport.connect(chatApp.connections[i].writeFd, &addr) == FAIL) {
                            dbg(CHAT_CHANNEL, "Failed to connect to server. Exiting!");
                            break;
                        }
                        chatApp.connections[i].sendRead = 0;
                        chatApp.connections[i].sendWritten = 0;
                        break;
                    }
                }
            }
            // Read on file descriptors
            for(i = 0; i < CHAT_APP_MAX_CONNS; i++) {
                if(chatApp.connections[i].readFd != 0) {
                    // Read data in and check for termination \r\n
                    bytes = 1;
                    while(getRcvdBufferAvailable(i) > 0 && bytes > 0) {
                        bytes = call Transport.read(chatApp.connections[i].readFd, &chatApp.connections[i].rcvdBuffer[chatApp.connections[i].rcvdWritten % CHAT_APP_BUFFER_SIZE], 1);
                        // If termination found call method to process command received
                        if(chatApp.connections[i].rcvdBuffer[chatApp.connections[i].rcvdWritten % CHAT_APP_BUFFER_SIZE] == '\n' && chatApp.connections[i].rcvdBuffer[(chatApp.connections[i].rcvdWritten-1) % CHAT_APP_BUFFER_SIZE] == '\r') {
                            chatApp.connections[i].rcvdBuffer[chatApp.connections[i].rcvdWritten+1 % CHAT_APP_BUFFER_SIZE] = '\0';
                            // dbg(CHAT_CHANNEL, "Processing %s", (char*)&chatApp.connections[i].rcvdBuffer[chatApp.connections[i].rcvdRead%CHAT_APP_BUFFER_SIZE]);
                            processCommand(i);
                        }
                        chatApp.connections[i].rcvdWritten += bytes;
                    }
                }
                // Write to fd!
                if(chatApp.connections[i].writeFd != 0) {
                    bytes = 1;
                    while(getSendBufferOccupied(i) > 0 && bytes > 0) {
                        bytes = call Transport.write(chatApp.connections[i].writeFd, &chatApp.connections[i].sendBuffer[chatApp.connections[i].sendRead % CHAT_APP_BUFFER_SIZE], 1);
                        // if(bytes > 0)
                        //     dbg(CHAT_CHANNEL, "SERVER: Writing %d to socket\n", chatApp.connections[i].sendBuffer[chatApp.connections[i].sendRead % CHAT_APP_BUFFER_SIZE]);
                        chatApp.connections[i].sendRead += bytes;
                    }
                }
            }
        // Else chatApp.type == CLIENT
        } else {
            // Accept new connections
            newReadFd = call Transport.accept(chatApp.listenSockFd);
            if(newReadFd > 0 && chatApp.connections[0].readFd == 0) {
                dbg(CHAT_CHANNEL, "CLIENT: server return connection is set up with fd %u\n", newReadFd);
                chatApp.connections[0].readFd = newReadFd;
                chatApp.connections[0].rcvdRead = 0;
                chatApp.connections[0].rcvdWritten = 0;
            } else {
                // Write outgoing command to writeFd from sendBuffer
                if(getSendBufferOccupied(0) > 0) {
                    // dbg(CHAT_CHANNEL, "CLIENT node %u: writing to fd, %u\n", TOS_NODE_ID, getSendBufferOccupied(0));
                    bytes = call Transport.write(chatApp.connections[0].writeFd, &chatApp.connections[0].sendBuffer[chatApp.connections[0].sendRead % CHAT_APP_BUFFER_SIZE], getSendBufferOccupied(0));
                    chatApp.connections[0].sendRead += bytes;
                }
                // Read on file descriptor and check for termination \r\n
                bytes = 1;
                while(getRcvdBufferAvailable(0) > 0 && bytes > 0) {
                    bytes = call Transport.read(chatApp.connections[0].readFd, &chatApp.connections[0].rcvdBuffer[chatApp.connections[0].rcvdWritten % CHAT_APP_BUFFER_SIZE], 1);
                    // dbg(CHAT_CHANNEL, "CLIENT: Reading in %u bytes\n", bytes);
                    // Print message if termination
                    if(chatApp.connections[0].rcvdBuffer[chatApp.connections[0].rcvdWritten % CHAT_APP_BUFFER_SIZE] == '\n' && chatApp.connections[0].rcvdBuffer[(chatApp.connections[0].rcvdWritten-1) % CHAT_APP_BUFFER_SIZE] == '\r') {
                        chatApp.connections[0].rcvdBuffer[chatApp.connections[0].rcvdWritten % CHAT_APP_BUFFER_SIZE] = '\0';
                        dbg(CHAT_CHANNEL, "CLIENT: %s\n", &chatApp.connections[0].rcvdBuffer[chatApp.connections[0].rcvdRead % CHAT_APP_BUFFER_SIZE]);
                        chatApp.connections[0].rcvdRead = chatApp.connections[0].rcvdWritten + 1;
                    }
                    chatApp.connections[0].rcvdWritten += bytes;                    
                }
            }
        }
    }

    command void ChatApp.startChatServer() {
        uint8_t i;
        socket_addr_t addr;
        if(chatApp.type == CLIENT || chatApp.listenSockFd > 0) {
            dbg(CHAT_CHANNEL, "Cannot start server\n");
            return;
        }
        chatApp.type = SERVER;
        chatApp.listenSockFd = call Transport.socket();
        if(chatApp.listenSockFd > 0) {
            // Listen on port 41
            addr.addr = TOS_NODE_ID;
            addr.port = CHAT_APP_SERVER_PORT;
            // Bind the socket to the src address
            if(call Transport.bind(chatApp.listenSockFd, &addr) == SUCCESS) {
                // Listen on the port and start a timer if needed
                if(call Transport.listen(chatApp.listenSockFd) == SUCCESS && !(call ChatTimer.isRunning())) {
                    call ChatTimer.startPeriodic(1024 + (uint16_t) (call Random.rand16()%1000));
                }
            }
        }
    }
    
    // CLIENT
    void handleHello(uint8_t clientPort) {
        uint8_t i;
        socket_addr_t addr;
        if(chatApp.type != OFF || chatApp.listenSockFd > 0) {
            dbg(CHAT_CHANNEL, "Cannot start client\n");
            return;
        }
        // Listen on port 41
        chatApp.type = CLIENT;
        chatApp.listenSockFd = call Transport.socket();
        if(chatApp.listenSockFd > 0) {
                // Listen on port 41
                addr.addr = TOS_NODE_ID;
                addr.port = CHAT_APP_SERVER_PORT;
                // Bind the socket to the src address
                if(call Transport.bind(chatApp.listenSockFd, &addr) == SUCCESS) {
                    // Listen on the port and start a timer if needed
                    if(call Transport.listen(chatApp.listenSockFd) == SUCCESS && !(call ChatTimer.isRunning())) {
                        dbg(CHAT_CHANNEL, "Node %u listening on port 41\n", TOS_NODE_ID);
                        call ChatTimer.startPeriodic(1024 + (uint16_t) (call Random.rand16()%1000));
                    }
                } else {
                    dbg(CHAT_CHANNEL, "Failed to bind socket\n");
                }
        } else {
            dbg(CHAT_CHANNEL, "Failed to obtain socket\n");
        }
        // Start client connection to node 1 on port 41
        addr.port = clientPort;
        chatApp.connections[0].writeFd = call Transport.socket();
        if(chatApp.connections[0].writeFd == 0) {
            dbg(CHAT_CHANNEL, "No available sockets. Exiting!");
            return;
        }
        // Bind the socket to the src address
        if(call Transport.bind(chatApp.connections[0].writeFd, &addr) == FAIL) {
            dbg(CHAT_CHANNEL, "Failed to bind sockets. Exiting!");
            return;
        }
        addr.addr = CHAT_APP_SERVER_ID;
        addr.port = CHAT_APP_SERVER_PORT;
        // Connect to the remote server
        if(call Transport.connect(chatApp.connections[0].writeFd, &addr) == FAIL) {
            dbg(CHAT_CHANNEL, "Failed to connect to server. Exiting!");
            return;
        }
        // Set up state
        chatApp.connections[0].sendRead = 0;
        chatApp.connections[0].sendWritten = 0;
        // Start the timer if it isn't running
        if(!(call ChatTimer.isRunning())) {
            call ChatTimer.startPeriodic(1024 + (uint16_t) (call Random.rand16()%1000));
        }
    }

    command void ChatApp.chat(char* message) {
        uint16_t len = strlen(message);
        uint8_t i = len-3;
        uint8_t port = 0;
        uint8_t count = 1;

        dbg(CHAT_CHANNEL, "CLIENT: Sending %s", message);
        if(message[len-1] != '\n' || message[len-2] != '\r') {
            dbg(CHAT_CHANNEL, "Malformed chat message: incorrectly terminated\n");
            return;
        }
        if(startsWith(message, "hello ")) {
            if(len < 12) {
                dbg(CHAT_CHANNEL, "Malformed chat message: hello too short\n");
                return;
            }
            dbg(CHAT_CHANNEL, "Handling hello!\n");
            // String to int to get port
            while(message[i] != ' ') {
                if(message[i] < '0' || message[i] > '9') {
                    dbg(CHAT_CHANNEL, "Malformed chat message: client port non-numeric\n");
                    return;
                }
                port += (message[i]-'0') * (count);
                count *= 10;
                i--;
            }
            handleHello(port);
            // Truncate msg to exclude port
            message[i] = '\r';
            message[i+1] = '\n';
            len = i+1;
            i = 0;
            while(i <= len) {
                memcpy(&chatApp.connections[0].sendBuffer[chatApp.connections[0].sendWritten++ % CHAT_APP_BUFFER_SIZE], message+i, 1);
                i++;
            }
        } else if(startsWith(message, "msg ") || startsWith(message, "whisper ") || startsWith(message, "listusr\r\n")) {
            if(chatApp.type != CLIENT) {
                dbg(CHAT_CHANNEL, "Malformed chat message: say hello first\n");
                return;
            }
            // dbg(CHAT_CHANNEL, "Handling msg/whisper/listusr: %s", message);
            i = 0;
            while(i <= len-1) {                
                memcpy(&chatApp.connections[0].sendBuffer[chatApp.connections[0].sendWritten++ % CHAT_APP_BUFFER_SIZE], message+i, 1);
                // dbg(CHAT_CHANNEL, "Char written: %d\n", chatApp.connections[0].sendBuffer[(chatApp.connections[0].sendWritten-1) % CHAT_APP_BUFFER_SIZE]);
                i++;
            }
        } else {
            dbg(CHAT_CHANNEL, "Malformed chat message: incorrect command format\n");
        }
    }
    
    
}