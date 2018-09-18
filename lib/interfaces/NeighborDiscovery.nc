

interface NeighborDiscovery{
   command error_t start();
   command error_t neighborReply(void* pack);
}
