/**
 * MapList
 * This module provides a MapList with an array of buckets (t, List<s>).
 * Size is constrained to the upper bound of uint16_t
 *
 * @author Chris DeSoto
 * @date   2018/09/10
 *
 */
#include "../../includes/channels.h"
generic module MapListC(typedef t @integer(), typedef s @integer(), uint16_t n, uint16_t k) {
    provides interface MapList<t, s>;
}

implementation{
    uint16_t HASH_MAX_SIZE = n;
    uint16_t LIST_MAX_SIZE = k;

    // This index is reserved for empty values.
    uint16_t EMPTY_KEY = 0;

    typedef struct List {
        s container[k];
        uint16_t size;
    } List;

    typedef struct MapListEntry {
        struct List list;
        t key;
    } MapListEntry;

    MapListEntry map[n];
    uint16_t numofVals = 0;

    // Hashing Functions
    uint16_t hash2(uint16_t key) {
        return key%13;
    }
    uint16_t hash3(uint16_t key) {
        return 1+key%11;
    }

    uint16_t hash(uint16_t key, uint16_t i) {
        return (hash2(k)+ i*hash3(k))%HASH_MAX_SIZE;
    }

/*******************************************************  
**  List functions
********************************************************/

    // Prototyping
    void insertBack(List* l, s val);
    void insertFront(List* l, s val);
    void removeBack(List* l);
    void removeFront(List* l);
    s front(List* l);
    s back(List* l);
    bool isEmpty(List* l);
    s get(List* l, uint16_t position);
    bool removeValFromList(List* l, s val);
    bool contains(List* l, s val);
    void print(List* l);

    // Implementation
	void insertBack(List* l, s val) {
		// Check to see if we have room for the input.
		if(l->size == LIST_MAX_SIZE) {
            removeFront(l);
        }
        // Put it in.
        l->container[l->size-1] = val;
        l->size++;
	}

	void insertFront(List* l, s val) {
        uint16_t i;
		// Check to see if we have room for the input.
		if(l->size == LIST_MAX_SIZE) {
            removeBack(l);
        }
        // Shift everything to the right.
        for(i = l->size-2; i > 0; i--) {
            l->container[i+1] = l->container[i];
        }
        l->container[1] = l->container[0];
        l->container[0] = val;
        l->size++;
	}

	void removeBack(List* l) {
        if(!isEmpty(l)) {
            l->size--;
        }
	}

	void removeFront(List* l) {
		uint16_t i;
		if(!isEmpty(l)) {
			// Move everything to the left.
			for(i = 0; i < l->size-2; i++) {
				l->container[i] = l->container[i+1];
			}
			l->size--;
		}
	}

	// This is similar to peek head.
	s front(List* l) {
		return l->container[0];
	}

	// Peek tail
	s back(List* l) {
		return l->container[l->size-1];
	}

	bool isEmpty(List* l) {
		if(l->size == 0)
			return TRUE;
		else
			return FALSE;
	}

	s get(List* l, uint16_t position) {
		return l->container[position];
	}

	bool removeValFromList(List* l, s val) {
        uint16_t i;    uint16_t j;
        if(isEmpty(l))
            return FALSE;
        for(i = l->size-1; i >= 0; i--) {
            // If we find the key matches 
            if(l->container[i] == val) {
                // Move everything to the left
                for(j = i+1; j < l->size-1; j++) {
                    l->container[j-1] = l->container[j];
                }
                // Decrement the size
                l->size--;
                return TRUE;
            }
            if(i == 0)
                return FALSE;
        }
        return FALSE;
	}

	bool contains(List* l, s val) {
        uint16_t i;
        //dbg(MAPLIST_CHANNEL,"Checking list for val: %d\n", val);
        if(!isEmpty(l)) {
            for(i = 0; i < l->size; i++) {
                if(l->container[i] == val) {
                    //dbg(MAPLIST_CHANNEL,"List val: %d already present\n", l->container[i]);
                    return TRUE;
                }
            }
        }
		return FALSE;
	}

    void print(List* l) {
        uint16_t i;
        if(isEmpty(l)) {
            dbg(MAPLIST_CHANNEL,"List empty\n");
            return;
        }
        dbg(MAPLIST_CHANNEL,"Printing list. Size: %d\n", l->size);
        for(i = 0; i < l->size; i++) {
            dbg(MAPLIST_CHANNEL,"List val: %d in MapList\n", l->container[i]);
        }
    }

/*******************************************************  
**  MapList methods
********************************************************/

    command void MapList.insertVal(t key, s val) {
        uint16_t i=0;	uint16_t j=0;
        do {
            // Generate a hash.
            j=hash(key, i);
            // If the bucket is free or if we found the correct bucket
            if(map[j].key == 0 || map[j].key == key) {
                if(isEmpty(&map[j].list)) {
                    numofVals++;
                }
                // Push the val onto back of the list
                insertBack(&map[j].list, val);
                // Make sure the correct key is assigned to the bucket
                if(map[j].key == 0) {
                    map[j].key = key;
                }
                dbg(MAPLIST_CHANNEL,"Inserted val into MapList, size: %d\n", map[j].list.size);
                break;
            }
            i++;
        // This will allow a total of HASH_MAX_SIZE misses. It can be greater,
        // But it is unlikely to occur.
        } while(i < HASH_MAX_SIZE);
    }

    command void MapList.removeVal(t key, s val) {
        uint16_t i=0;	uint16_t j=0;
        do {
            j=hash(key, i);
            if(map[j].key == key) {
                removeValFromList(&map[j].list, val);
                if(isEmpty(&map[j].list)) {
                    map[j].key = 0;
                    numofVals--;                    
                }
                dbg(MAPLIST_CHANNEL,"Removed val: %d into MapList\n", val);
            }
            i++;
        } while(i < HASH_MAX_SIZE);
    }    

    command bool MapList.containsList(t key) {
        uint16_t i=0;   uint16_t j=0;
        do {
            j=hash(key, i);
            if(map[j].key == key)
                return TRUE;
            i++;
        } while(i < HASH_MAX_SIZE);
        return FALSE;
    }

    command bool MapList.containsVal(t key, s val) {
        uint16_t i=0;   uint16_t j=0;        
        do {
            j=hash(key, i);
            if(map[j].key == key) {
                //dbg(MAPLIST_CHANNEL,"Checking if list for key: %d contains val\n", key);
                return contains(&map[j].list, val);
            }
            i++;
        } while(i < HASH_MAX_SIZE);
        return FALSE;
    }

    command bool MapList.isEmpty() {
        if(numofVals==0)
            return TRUE;
        return FALSE;
    }

    command bool MapList.listIsEmpty(t key) {
        uint16_t i=0;   uint16_t j=0;
        do {
            j=hash(key, i);
            if(map[j].key == key)
                return isEmpty(&map[j].list);
            i++;
        } while(i < HASH_MAX_SIZE);
        return FALSE;
    }

    command void MapList.printList(t key) {
        uint16_t i=0;   uint16_t j=0;
        do {
            j=hash(key, i);
            if(map[j].key == key) {
                print(&map[j].list);
                break;
            }
            i++;
        } while(i < HASH_MAX_SIZE);
    }

}
