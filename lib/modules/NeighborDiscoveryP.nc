


generic module NeighborDiscoveryP(){

    provides interface NeighborDiscovery;

    uses interface Timer<TMilli> as NeighborDiscoveryTimer;
    uses interface Random as Random;

}

implementation {


    command error_t NeighborDiscovery.start() {

    }

}