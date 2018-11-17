from TestSim import TestSim


def main():
    # Get simulation ready to run.
    s = TestSim()

    # Before we do anything, lets simulate the network off.
    s.runTime(1)

    # Load the the layout of the network.
    s.loadTopo("long_line.topo")

    # Add a noise model to all of the motes.
    s.loadNoise("no_noise.txt")

    # Turn on all of the sensors.
    s.bootAll()

    # Add the main channels. These channels are declared in includes/channels.h
    s.addChannel(s.COMMAND_CHANNEL)
    s.addChannel(s.GENERAL_CHANNEL)
#    s.addChannel(s.HASHMAP_CHANNEL)
#    s.addChannel(s.MAPLIST_CHANNEL)
#    s.addChannel(s.FLOODING_CHANNEL)
#    s.addChannel(s.NEIGHBOR_CHANNEL)
#    s.addChannel(s.ROUTING_CHANNEL)
    s.addChannel(s.TRANSPORT_CHANNEL)

    s.runTime(40)

    s.cmdTestServer(1, 50)
    s.runTime(10)

    s.cmdTestClient(2, 1, 25, 50, 100)
    s.runTime(50)

if __name__ == '__main__':
    main()
