/**
 * ANDES Lab - University of California, Merced
 * This moudle provides a simple hashmap.
 *
 * @author UCM ANDES Lab
 * @date 2013/09/03
 *
 */
#include "../../includes/channels.h"
generic module MapListC(typedef t, typedef s, uint16_t n, uint16_t k) {
    provides interface MapList<t, s>;
}

implementation{
    uint16_t HASH_MAX_SIZE = n;
    uint16_t LIST_MAX_SIZE = k;

    // This index is reserved for empty values.
    uint16_t EMPTY_KEY = 0;

    typedef struct List {
        s container[k];
        uint16_t size = 0;
    } List;

    typedef struct HashmapEntry {
        List list;
        t key;
    } HashmapEntry;

    HashmapEntry map[n];
    uint16_t numofVals;

    // Hashing Functions
    uint32_t hash2(uint32_t k) {
        return k%13;
    }
    uint32_t hash3(uint32_t k) {
        return 1+k%11;
    }

    uint32_t hash(uint32_t k, uint32_t i) {
        return (hash2(k)+ i*hash3(k))%HASH_MAX_SIZE;
    }

/******************************************************/
/*  
**  List functions
 */

	void pushback(List l, s val){
		// Check to see if we have room for the input.
		if(l.size == MAX_SIZE){
            popfront(l);
        }
        // Put it in.
        l.container[l.size] = val;
        l.size++;
	}

	void pushfront(List l, s val){
		// Check to see if we have room for the input.
		if(size == MAX_SIZE){
            popback(l);
        }
        int32_t i;
        // Shift everything to the right.
        for(i = l.size-1; i>=0; i--){
            l.container[i+1] = l.container[i];
        }

        l.container[0] = val;
        l.size++;
	}

	s popback(List l){
		s returnVal = l.container[size];
		// We don't need to actually remove the value, we just need to decrement
		// the size.
		if(l.size > 0) {
            l.size--;
        }
		return returnVal;
	}

	s popfront(List l){
		s returnVal = l.container[0];
		uint16_t i;
		if(l.size>0){
			// Move everything to the left.
			for(i = 0; i < l.size-1; i++){
				l.container[i] = l.container[i+1];
			}
			l.size--;
		}
		return returnVal;
	}

	// This is similar to peek head.
	s front(List l){
		return l.container[0];
	}

	// Peek tail
	s back(List l){
		return l.container[size];
	}

	bool isEmpty(List l){
		if(l.size == 0)
			return TRUE;
		else
			return FALSE;
	}

	uint16_t size(List l){
		return l.size;
	}

	s get(List l, uint16_t position){
		return l.container[position];
	}

	bool remove(List l, s val){
        int i;
        int j;
        for(i = l.size-1; i >= 0; i--){
            // If we find the key matches 
            if(l.container[i] == s) {
                // Move everything to the left
                for(j = i+1; j < l.size-1; j++){
                    l.container[j-1] = l.container[j];
                }
                // Decrement the size
                l.size--;
                return TRUE;
            }
        }
        return FALSE;
	}

	bool contains(List l, s val){
        int i;
        for(i = l.size-1; i >= 0; i--){
            if(l.container[i] == s) {
                return TRUE;
            }
        }
		return FALSE;
	}

/******************************************************/

    command void Hashmap.insertVal(t key, s val) {
        uint32_t i=0;	uint32_t j=0;
        do {
            // Generate a hash.
            j = hash(k, i);
            // If the bucket is free or if we found the correct bucket
            if(map[j].key == 0 || map[j].key == key) {
                // Push the val onto back of the list
                pushback(map[j].list, val);
                // Make sure the correct key is assigned to the bucket
                if(map[j].key == 0 ) {
                    map[j].key = key;
                }
            }
            i++;
        // This will allow a total of HASH_MAX_SIZE misses. It can be greater,
        // But it is unlikely to occur.
        } while(i<HASH_MAX_SIZE);
    }


    command void Hashmap.removeVal(t key, s val){
        uint32_t i=0;	uint32_t j=0;
        do {
            j=hash(k, i);
            if(map[j].key == key){
                remove(map[j].list, val);
            }
            i++;
        } while(i<HASH_MAX_SIZE);

    }

    
    command t Hashmap.get(uint32_t k){
        uint32_t i=0;	uint32_t j=0;
        do{
            j=hash(k, i);
            if(map[j].key == k)
                return map[j].value;
            i++;
        }while(i<HASH_MAX_SIZE);

        // We have to return something so we return the first key
        return map[0].value;
    }

    command bool Hashmap.contains(uint32_t k){
        uint32_t i=0;	uint32_t j=0;
        /*
        if(k == EMPTY_KEY)
	{
		return FALSE;
	}
	*/
        do{
            j=hash(k, i);
            if(map[j].key == k)
                return TRUE;
            i++;
        }while(i<HASH_MAX_SIZE);
        return FALSE;
    }

    command bool Hashmap.isEmpty(){
        if(numofVals==0)
            return TRUE;
        return FALSE;
    }

    command uint32_t* Hashmap.getKeys(){
        return keys;
    }

    command uint16_t Hashmap.size(){
        return numofVals;
    }
}
