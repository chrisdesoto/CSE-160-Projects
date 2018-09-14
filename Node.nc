/*
 * ANDES Lab - University of California, Merced
 * This class provides the basic functions of a network node.
 *
 * @author UCM ANDES Lab
 * @date    2013/09/03
 *
 */
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/protocol.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

module Node{
    uses interface Boot;

    uses interface SplitControl as AMControl;
    uses interface Receive;

    uses interface SimpleSend as Sender;

    uses interface CommandHandler;

    uses interface MapList<uint16_t, uint16_t> as MapList;
}

implementation{
    pack sendPackage;
    uint16_t sequenceNum = 0;
    // Prototypes
    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

    event void Boot.booted(){
        call AMControl.start();
        dbg(GENERAL_CHANNEL, "Booted\n");
    }

    event void AMControl.startDone(error_t err){
        if(err == SUCCESS){
            dbg(GENERAL_CHANNEL, "Radio On\n");
        }else{
            //Retry until successful
            call AMControl.start();
        }
    }

    event void AMControl.stopDone(error_t err){}

    event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
        //dbg(GENERAL_CHANNEL, "Packet Received\n");
        pack* myMsg=(pack*) payload;
        if(len!=sizeof(pack)) {
            dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len); 
        } else if((call MapList.containsVal(myMsg->src, myMsg->seq))) {                
            dbg(GENERAL_CHANNEL, "Packet Seen Already. Dropping...\n");
        } else if(myMsg->TTL == 0) {
            dbg(GENERAL_CHANNEL, "TTL expired...\n");
        } else if(TOS_NODE_ID == myMsg->dest) {
            call MapList.insertVal(myMsg->src, myMsg->seq);
            dbg(GENERAL_CHANNEL, "Packet Payload Reached Destination\n");
            logPack(myMsg);
        } else {
            myMsg->TTL -= 1;
            call MapList.insertVal(myMsg->src, myMsg->seq);
            call Sender.send(*myMsg, AM_BROADCAST_ADDR);
        }
        return msg;
    }

    bool packageSeen(uint16_t src, uint16_t seq) {

    }


    event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
        dbg(GENERAL_CHANNEL, "PING EVENT \n");
        dbg(GENERAL_CHANNEL, "SENDER %d\n", TOS_NODE_ID);
        dbg(GENERAL_CHANNEL, "DEST %d\n", destination);
        makePack(&sendPackage, TOS_NODE_ID, destination, 19, PROTOCOL_PING, sequenceNum, payload, PACKET_MAX_PAYLOAD_SIZE);
        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
        sequenceNum++;
    }

    event void CommandHandler.printNeighbors(){}

    event void CommandHandler.printRouteTable(){}

    event void CommandHandler.printLinkState(){}

    event void CommandHandler.printDistanceVector(){}

    event void CommandHandler.setTestServer(){}

    event void CommandHandler.setTestClient(){}

    event void CommandHandler.setAppServer(){}

    event void CommandHandler.setAppClient(){}

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
        Package->src = src;
        Package->dest = dest;
        Package->TTL = TTL;
        Package->seq = seq;
        Package->protocol = protocol;
        memcpy(Package->payload, payload, length);
    }
}
