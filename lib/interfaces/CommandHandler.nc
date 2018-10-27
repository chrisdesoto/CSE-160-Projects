interface CommandHandler{
   // Events
   event void ping(uint16_t destination, uint8_t *payload);
   event void printNeighbors();
   event void printRouteTable();
   event void printLinkState();
   event void printDistanceVector();
   event void printMessage(uint8_t *payload);
   event void setTestServer(uint16_t address, uint8_t port);
   event void setTestClient(uint16_t destination, uint8_t srcPort, uint8_t destPort, uint8_t *payload);
   event void setAppServer();
   event void setAppClient();
}
