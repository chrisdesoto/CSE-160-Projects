/**
 * MapList
 *
 * @author Chris DeSoto
 * @date   2018/09/10
 * 
 */

interface MapList<t, s> {
   command void insertVal(t key, s val);
   command void removeVal(t key, s val);
   command s getList(t key);
   command bool containsList(t key);
   command bool containsVal(t key, s val);
   command bool isEmpty();
   command uint16_t size();
   command t * getKeys();
}
