#include "../includes/packet.h"
#include "../../includes/socket.h"


interface ChatApp{
    command void startChatServer();
    command void chat(char* msg);
    // command void chatHello(char* username, uint8_t clientPort);
    // command void chatMsg(char* msg);
    // command void chatWhisper(char* username, char* msg);
    // command void chatListUsr();
}