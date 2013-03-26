-- AS Large Set Stickman V1 -- (Last Update Mar 09, 2013: tjl)
-- Aerospike Set Operations
-- (*) Set Create
-- (*) Set Insert
-- (*) Set Select (and Exists)
-- (*) Set Delete

-- ======================================================================
-- || GLOBAL PRINT ||
-- ======================================================================
-- Use this flag to enable/disable global printing (the "detail" level
-- in the server).
-- Usage: GP=F and trace()
-- When "F" is true, the trace() call is executed.  When it is false,
-- the trace() call is NOT executed (regardless of the value of GP)
-- ======================================================================
local GP=true; -- Doesn't matter what this is set to.
local F=false; -- Set F (flag) to true to turn ON global print

-- =========================
-- || LOCAL GLOBAL VALUES ||
-- =========================
local INSERT = 1; -- flag to scanList to INSERT the value (if not found)
local SCAN = 0;
local DELETE = -1; -- flag to show scanList to DELETE the value, if found
local EMPTY = "__empty__"; -- the value is NO MORE

-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- AS Large Set Utility Functions
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||

-- ======================================================================
-- initializeLSetMap:
-- ======================================================================
-- Set up the LSetMap with the standard (default) values.
-- These values may later be overridden by the user.
-- The structure held in the Record's "LSetBIN" is this map.  This single
-- structure contains ALL of the settings/parameters that drive the LSet
-- behavior.
-- Parms:
-- (*) topRec: The Aerospike Server record on which we operate
-- (*) namespace: The Namespace of the record (topRec)
-- (*) set: The Set of the record (topRec)
-- (*) setBinName: The name of the bin for the AS Large Set
-- (*) distrib: The Distribution Factor (how many separate bins) 
-- Return: The initialized lsetCtrlMap.
-- It is the job of the caller to store in the rec bin and call update()
-- ======================================================================
local function initializeLSetMap(topRec, namespace, set, lsetBinName, distrib )
  local mod = "AsLSetStickman";
  local meth = "initializeLSetMap()";
  GP=F and trace("[ENTER]: <%s:%s>:: NS(%s) Set(%s) BinName(%s) D(%s)",
    mod, meth, tostring(namespace), tostring(set), tostring(lsetBinName),
    tostring( distrib));

  -- If "distrib" is bad (zero, negative or nil)  then use our default (31)
  -- Best to use a prime number.
  if distrib == nil or distrib <= 0 then distrib = 31 end

  -- Create the map, and fill it in.
  -- Note: All Field Names start with UPPER CASE.
  local lsetCtrlMap = map();
  lsetCtrlMap.StoreState = 0; -- always start in "compact mode"
  lsetCtrlMap.BinName = lsetBinName;
  lsetCtrlMap.NameSpace = namespace;
  lsetCtrlMap.Set = set;
  lsetCtrlMap.ItemCount = 0;   -- Count of valid elements
  lsetCtrlMap.TotalCount = 0;  -- Count of both valid and deleted elements
  lsetCtrlMap.Modulo = distrib;
  lsetCtrlMap.ThreshHold = 4; -- Rehash after this many have been inserted

  -- NOTE: Version 2: We will information here about value complexity and
  -- how to find the key.  If values are atomic (e.g. int or string) then
  -- we use the WHOLE value, otherwise we expect a MAP type, which will
  -- have a KEY field in it (which is what we'll search/hash on).
  -- So, when we do type(value), we expect "number", "string" or
  -- "userdata" (which MUST be a map with a KEY field).
  lsetCtrlMap.KeyType = 0; -- assume "atomic" values for now.

  GP=F and trace("[ENTER]: <%s:%s>:: lsetCtrlMap(%s)",
    mod, meth, tostring(lsetCtrlMap));

  return lsetCtrlMap;
end -- initializeLSetMap()

-- ======================================================================
-- adjustLsetMap:
-- ======================================================================
-- Using the settings supplied by the caller in the Create() call,
-- we adjust the values in the lsetCtrlMap.
-- Parms:
-- (*) lsetCtrlMap: the main LSET Bin value
-- (*) argListMap: Map of User Override LSET Settings 
-- ======================================================================
local function adjustLSetMap( lsetCtrlMap, argListMap )
  local mod = "LSetStickman";
  local meth = "adjustLSetMap()";
  GP=F and trace("[ENTER]: <%s:%s>:: LSetMap(%s)::\n ArgListMap(%s)",
    mod, meth, tostring(lsetCtrlMap), tostring( argListMap ));

  -- Iterate thru the argListMap and adjust (override) the map settings 
  -- based on the settings passed in during the stackCreate() call.
  -- CREATE_ARGLIST='{
  -- "Modulo":67
  -- "KeyType":1}'
  for name, value in map.pairs( argListMap ) do
    if name  == "Modulo" then
      if type( value ) == "number" and value > 0 and value < 221 then
        lsetCtrlMap.Modulo = value;
      end
    elseif name == "KeyType" then
      if type( value ) == "number" and value > 0 then
        lsetCtrlMap.KeyType = value;
      end
    end
  end -- foreach arg

  GP=F and trace("[EXIT]: <%s:%s> : CTRL Map after Adjust(%s)",
    mod, meth , tostring(lsetCtrlMap));
  return lsetCtrlMap
end -- adjustLSetMap


-- ======================================================================
local  CRC32 = require('CRC32');
-- ======================================================================
-- Return the hash of "value", with modulo.
-- Notice that we can use ZERO, because this is not an array index
-- (which would be ONE-based for Lua) but is just used as a name.
-- ======================================================================
local function stringHash( value, modulo )

  if value ~= nil and type(value) == "string" then
    return  CRC32.Hash( value ) % modulo;
  else
    return 0;
  end
end
-- ======================================================================
-- Return the hash of "value", with modulo
-- Notice that we can use ZERO, because this is not an array index
-- (which would be ONE-based for Lua) but is just used as a name.
-- NOTE: Use a better Hash Function.
-- ======================================================================
local function numberHash( value, modulo )
  local mod = "AsLSetStickman";
  local meth = "numberHash()";
  local result = 0;
  if value ~= nil and type(value) == "number" then
    -- math.randomseed( value );
    -- return math.random( modulo );
    result =  CRC32.Hash( value ) % modulo;
  end
  GP=F and trace("[EXIT]:<%s:%s>HashResult(%s)", mod, meth, tostring(result))
  return result
end -- numberHash


-- ======================================================================
-- Get (create) a unique bin name given the current counter.
-- 'LSetBin_XX' will be the individual bins that hold lists of set data
-- ======================================================================
local function getBinName( number )
  local binPrefix = "LSetBin_";
  return binPrefix .. tostring( number );
end

-- ======================================================================
-- setupNewBin: Initialize a new bin -- (the thing that holds a list
-- of user values).
-- Parms:
-- (*) topRec
-- (*) Bin Number
-- Return: New Bin Name
-- ======================================================================
local function setupNewBin( topRec, binNum )
  local mod = "AsLSetStickman";
  local meth = "setupNewBin()";
  GP=F and trace("[ENTER]: <%s:%s> Bin(%d) \n", mod, meth, binNum );

  local binName = getBinName( binNum );
  topRec[binName] = list(); -- Create a new list for this new bin

  GP=F and trace("[EXIT]: <%s:%s> BinNum(%d) BinName(%s)\n",
    mod, meth, binNum, binName );

  return binName;
end


-- ======================================================================
-- computeSetBin()
-- Find the right bin for this value.
-- First -- know if we're in "compact" StoreState or "regular" 
-- StoreState.  In compact mode, we ALWAYS look in the single bin.
-- Second -- use the right hash function (depending on the type).
-- And, know if it's an atomic type or complex type.
-- ======================================================================
local function computeSetBin( newValue, lsetCtrlMap )
  local mod = "AsLSetStickman";
  local meth = "computeSetBin()";
  GP=F and trace("[ENTER]: <%s:%s> val(%s) Map(%s) \n",
    mod, meth, tostring(newValue), tostring(lsetCtrlMap) );

  -- Check StoreState
  local binNumber  = 0;
  if lsetCtrlMap.StoreState == 0 then
    return 0
  else
    if type(newValue) == "number" then
      binNumber  = numberHash( newValue, lsetCtrlMap.Modulo );
    elseif type(newValue) == "string" then
      binNumber  = stringHash( newValue, lsetCtrlMap.Modulo );
    elseif type(newValue) == "userdata" then
      binNumber  = stringHash( newValue.KEY, lsetCtrlMap.Modulo );
    else -- error case
      warn("[ERROR]<%s:%s>Unexpected Type (should be number, string or map)",
        mod, meth );
    end
  end
  -- TODO: Find a better hash function.
  GP=F and trace("[EXIT]: <%s:%s> Val(%s) BinNumber (%d) \n",
    mod, meth, tostring(newValue), binNumber );

  return binNumber;
end -- computeSetBin()


-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- Scan a List for an item.  Return the item if found.
-- This is COMPLEX SCAN, which means we are comparing the KEY field of the
-- map object in both the value and in the List.
-- We've added a delete flag that will allow us to remove the element if
-- we choose -- but for now, we are not collapsing the list.
-- Parms:
-- (*) binList: the list of values from the record
-- (*) value: the value we're searching for
-- (*) flag:
--     ==> if ==  1 (INSERT): insert the element IF NOT FOUND
--     ==> if ==  0 (SCAN): then return element if found, else return nil
--     ==> if == -1 (DELETE):  then replace the found element with nil
-- Return:
-- For SCAN and DELETE:
--    nil if not found, Value if found.
--   (NOTE: Can't return 0 -- because that might be a valid value)
-- For INSERT:
-- Return 0 if found (and not inserted), otherwise 1 if inserted.
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
local function complexScanList(lsetCtrlMap, binList, value, flag ) 
  local mod = "AsLSetStickman";
  local meth = "complexScanList()";
  local result = nil;
  -- Scan the list for the item, return true if found,
  -- Later, we may return a set of things 
  for i = 1, list.size( binList ), 1 do
    GP=F and trace("[DEBUG]: <%s:%s> It(%d) Comparing SV(%s) with BinV(%s)\n",
    mod, meth, i, tostring(value), tostring(binList[i]));
    if binList[i] ~= nil and binList[i] ~= EMPTY and binList[i].KEY == value.KEY then
      result = binList[i]; -- save the thing we found.
      GP=F and trace("[EARLY EXIT]: <%s:%s> Found(%s)\n",
        mod, meth, tostring(value));
      if( flag == DELETE ) then
        binList[i] = EMPTY; -- the value is NO MORE
        -- Decrement ItemCount (valid entries) but TotalCount stays the same
        local itemCount = lsetCtrlMap.ItemCount;
        lsetCtrlMap.ItemCount = itemCount - 1;
      elseif flag == INSERT then
        return 0 -- show caller nothing got inserted (don't count it)
      end
      return result
    end
  end -- for each list entry in this binList

  -- Didn't find it.  If INSERT, then append the value to the list
  if flag == INSERT then
    GP=F and trace("[DEBUG]: <%s:%s> INSERTING(%s)\n",
      mod, meth, tostring(value));
    list.append( binList, value );
    return 1 -- show caller we did an insert
  end
  GP=F and trace("[LATE EXIT]: <%s:%s> Did NOT Find(%s)\n",
    mod, meth, tostring(value));
  return nil;
end


-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- Scan a List for an item.  Return the item if found.
-- This is SIMPLE SCAN, where we are assuming ATOMIC values.
-- We've added a delete flag that will allow us to remove the element if
-- we choose -- but for now, we are not collapsing the list.
-- Parms:
-- (*) binList: the list of values from the record
-- (*) value: the value we're searching for
-- (*) flag:
--     ==> if ==  1 (INSERT): insert the element IF NOT FOUND
--     ==> if ==  0 (SCAN): then return element if found, else return nil
--     ==> if == -1 (DELETE):  then replace the found element with nil
-- Return:
-- For SCAN and DELETE:
--    nil if not found, Value if found.
--   (NOTE: Can't return 0 -- because that might be a valid value)
-- For INSERT:
-- Return 0 if found (and not inserted), otherwise 1 if inserted.
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
local function simpleScanList(lsetCtrlMap, binList, value, flag ) 
  local mod = "AsLSetStickman";
  local meth = "simpleScanList()";
  GP=F and trace("[ENTER]: <%s:%s> Looking for V(%s), ListSize(%d) List(%s)",
    mod, meth, tostring(value), list.size(binList), tostring(binList))

  local result = nil;
  -- Scan the list for the item, return true if found,
  -- Later, we may return a set of things 
  for i = 1, list.size( binList ), 1 do
    GP=F and trace("[DEBUG]: <%s:%s> It(%d) Comparing SV(%s) with BinV(%s)\n",
    mod, meth, i, tostring(value), tostring(binList[i]));
    if binList[i] ~= nil and binList[i] == value then
      result = binList[i];
      GP=F and trace("[EARLY EXIT]: <%s:%s> Found(%s)\n",
        mod, meth, tostring(value));
      if( flag == DELETE ) then
        binList[i] = EMPTY; -- the value is NO MORE
        -- Decrement ItemCount (valid entries) but TotalCount stays the same
        local itemCount = lsetCtrlMap.ItemCount;
        lsetCtrlMap.ItemCount = itemCount - 1;
      elseif flag == INSERT then
        return 0 -- show caller nothing got inserted (don't count it)
      end
      return result;
    end
  end

  -- Didn't find it.  If INSERT, then append the value to the list
  if flag == INSERT then
    GP=F and trace("[EXIT]: <%s:%s> INSERTING(%s)\n",
      mod, meth, tostring(value));
    list.append( binList, value );
    return 1 -- show caller we did an insert
  end
  GP=F and trace("[LATE EXIT]: <%s:%s> Did NOT Find(%s)\n",
    mod, meth, tostring(value));
  return nil;
end -- simpleScanList


-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- Scan a List for an item.  Return the item if found.
-- Since there are two types of scans (simple, complex), we do the test
-- up front and call the appropriate scan type (rather than do the test
-- of which compare to do -- for EACH value.
-- Parms:
-- (*) lsetCtrlMap: the control map -- so we can see the type of key
-- (*) binList: the list of values from the record
-- (*) searchValue: the value we're searching for
-- (*) flag:
--     ==> if == -1 (DELETE):  then replace the found element with nil
--     ==> if ==  0 (SCAN): then return element if found, else return nil
--     ==> if ==  1 (INSERT): insert the element IF NOT FOUND
-- Return: nil if not found, Value if found.
-- (NOTE: Can't return 0 -- because that might be a valid value)
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
local function scanList( lsetCtrlMap, binList, searchValue, flag ) 
  local mod = "AsLSetStickman";
  local meth = "scanList()";

  if lsetCtrlMap.KeyType == 0 then
    return simpleScanList(lsetCtrlMap, binList, searchValue, flag ) 
  else
    return complexScanList(lsetCtrlMap, binList, searchValue, flag ) 
  end
end


-- ======================================================================
-- localInsert( lsetCtrlMap, newValue, stats )
-- ======================================================================
-- Perform the main work of insert (used by both rehash and insert)
-- Parms:
-- (*) topRec: The top DB Record:
-- (*) lsetCtrlMap: The AsLSet control map
-- (*) newValue: Value to be inserted
-- (*) stats: 1=Please update Counts, 0=Do NOT update counts (rehash)
-- ======================================================================
local function localInsert( topRec, lsetCtrlMap, newValue, stats )
  local mod = "AsLSetStickman";
  local meth = "localInsert()";
  GP=F and trace("[ENTER]:<%s:%s>Insert(%s)", mod, meth, tostring(newValue));

  -- Notice that "computeSetBin()" will know which number to return, depending
  -- on whether we're in "compact" or "regular" storageState.
  local binNumber = computeSetBin( newValue, lsetCtrlMap );
  local binName = getBinName( binNumber );
  GP=F and trace("[DEBUG]:<%s:%s> Compute:BNum(%s) BName(%s) Val(%s) Map(%s)",
    mod, meth, tostring(binNumber), tostring(binName),
    tostring(newValue), tostring(lsetCtrlMap));

  local binList = topRec[binName];

  local insertResult = 0;
  if binList == nil then
    GP=F and trace("[INTERNAL ERROR]:<%s:%s> binList is nil: binName(%s)",
      mod, meth, tostring( binName ) );
      return('INTERNAL ERROR: Nil Bin');
  else
    -- Look for the value, and insert if it is not there.
    insertResult = scanList( lsetCtrlMap, binList, newValue, INSERT );
    -- list.append( binList, newValue );
    topRec[binName] = binList;
  end

  GP=F and trace("[DEBUG]: <%s:%s>:Bin(%s) Now has list(%s)",
    mod, meth, binName, tostring(binList) );

  if stats == 1 and insertResult == 1 then -- Update Stats if success
    local itemCount = lsetCtrlMap.ItemCount;
    local totalCount = lsetCtrlMap.TotalCount;
    lsetCtrlMap.ItemCount = itemCount + 1; -- number of valid items goes up
    lsetCtrlMap.TotalCount = totalCount + 1; -- Total number of items goes up
    GP=F and trace("[DEBUG]: <%s:%s> itemCount(%d)", mod, meth, itemCount );
  end
  topRec['AsLSetCtrlBin'] = lsetCtrlMap;

  GP=F and trace("[EXIT]: <%s:%s>Storing Record() with New Value(%s): Map(%s)",
    mod, meth, tostring( newValue ), tostring( lsetCtrlMap ) );

    -- No need to return anything
end -- localInsert


-- ======================================================================
-- rehashSet( topRec, lsetBinName, lsetCtrlMap )
-- ======================================================================
-- When we start in "compact" StoreState (value 0), we eventually have
-- to switch to "regular" state when we get enough values.  So, at some
-- point (StoreThreshHold), we rehash all of the values in the single
-- bin and properly store them in their final resting bins.
-- So -- copy out all of the items from bin 1, null out the bin, and
-- then resinsert them using "regular" mode.
-- Parms:
-- (*) topRec
-- (*) lsetBinName
-- (*) lsetCtrlMap
-- ======================================================================
local function rehashSet( topRec, lsetBinName, lsetCtrlMap )
  local mod = "AsLSetStickman";
  local meth = "rehashSet()";
  GP=F and trace("[ENTER]:<%s:%s> !!!! REHASH !!!! ", mod, meth );
  GP=F and trace("[ENTER]:<%s:%s> !!!! REHASH !!!! ", mod, meth );

  -- Get the list, make a copy, then iterate thru it, re-inserting each one.
  local singleBinName = getBinName( 0 );
  local singleBinList = topRec[singleBinName];
  if singleBinList == nil then
    warn("[INTERNAL ERROR]:<%s:%s> Rehash can't use Empty Bin (%s) list",
      mod, meth, tostring(singleBinName));
      return('BAD BIN 0 LIST for Rehash');
  end
  local listCopy = list.take( singleBinList, list.size( singleBinList ));
  topRec[singleBinName] = nil; -- this will be reset shortly.
  lsetCtrlMap.StoreState = 1; -- now in "regular" (modulo) mode
  
  -- Rebuild. Allocate new lists for all of the bins, then re-insert.
  -- Create ALL of the new bins, each with an empty list
  -- Our "indexing" starts with ZERO, to match the modulo arithmetic.
  local distrib = lsetCtrlMap.Modulo;
  for i = 0, (distrib - 1), 1 do
    setupNewBin( topRec, i );
  end -- for each new bin

  for i = 1, list.size( listCopy), 1 do
    localInsert( topRec, lsetCtrlMap, listCopy[i], 0 ); -- do NOT update counts.
  end

  GP=F and trace("[EXIT]: <%s:%s>", mod, meth );
end -- rehashSet()
-- ======================================================================

-- ======================================================================
-- The C Version
-- ------------------------------------------------------------
--  The published hash algorithm used in the UNIX ELF format
--  for object files. Accepts a pointer to a string to be hashed
--  and returns an unsigned long.
-- ------------------------------------------------------------
-- unsigned long ElfHash ( const unsigned char *name ) {
--  unsigned long   h = 0, g;
--  while ( *name ) {
--    h = ( h << 4 ) + *name++;
--    if ( g = h & 0xF0000000 )
--      h ^= g >> 24;
--    h &= ~g;
--  }
--  return h;
--}
-- ======================================================================
-- ------------------------------------------------------------
--  The published hash algorithm used in the UNIX ELF format
--  for object files. Accepts a pointer to a string to be hashed
--  and returns an unsigned long.
-- ------------------------------------------------------------
-- local function intHash ( intValue  )
--   local mod = "AsLSetStickman";
--   local meth = "intHash()";
--   GP=F and trace("[ENTER]: <%s:%s> val(%d) \n", mod, meth, intValue );
--   local h = 0;
--   local g = 0;
--    h = ( h << 4 ) + intValue;
--    if ( g = h and 0xF0000000 ) then
--       h  = h ^ (g >> 24);
--    end
--    h = h bit.band  ~g;
--   GP=F and trace("[EXIT]: <%s:%s> Return (%d) \n", mod, meth, h );
--   return h;
-- end

-- ======================================================================
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- AS Large Set Main Functions
-- ||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- Requirements/Restrictions (this version).
-- (1) One Set Per Record
--
-- ======================================================================
-- || asLSetCreate ||
-- ======================================================================
-- Create/Initialize a AS LSet structure in a record, using multiple bins
--
-- We will use predetermined BIN names for this initial prototype:
-- 'AsLSetCtrlBin' will be the name of the bin containing the control info
-- 'LSetBin_XX' will be the individual bins that hold lists of set data
-- There can be ONLY ONE set in a record, as we are using preset fixed names
-- for the bin.
-- +========================================================================+
-- | Usr Bin 1 | Usr Bin 2 | o o o | Usr Bin N | Set CTRL BIN | Set Bins... |
-- +========================================================================+
-- Set Ctrl Bin is a Map -- containing control info and the list of
-- bins (each of which has a list) that we're using.
-- Parms:
-- (*) topRec: The Aerospike Server record on which we operate
-- (*) namespace: The Namespace of the record (topRec)
-- (*) set: The Set of the record (topRec)
-- (*) setBinName: The name of the bin for the AS Large Set
-- (*) distrib: The Distribution Factor (how many separate bins) 
function asLSetCreate( topRec, namespace, set, setBinName, distrib )
  local mod = "AsLSetStickman";
  local meth = "asLSetCreate()";
  GP=F and trace("[ENTER]: <%s:%s> NS(%s) Set(%s) Bin(%s) Dis(%d)\n",
    mod, meth, namespace, set, setBinName, distrib );

  -- Check to see if Set Structure (or anything) is already there,
  -- and if so, error.
  if( topRec['AsLSetCtrlBin'] ~= nil ) then
    GP=F and trace("[ERROR EXIT]: <%s:%s> AsLSetCtrlBin Already Exists",
      mod, meth );
    return('AsLSetCtrlBin already exists');
  end

  GP=F and trace("[DEBUG]: <%s:%s> : Initialize SET CTRL Map", mod, meth );
  local lsetCtrlMap =
    initializeLSetMap( topRec, namespace, set, lsetBinName, distrib );

  GP=F and trace("[DEBUG]: <%s:%s> : CTRL Map after Init(%s)",
    mod, meth , tostring(lsetCtrlMap));

  topRec['AsLSetCtrlBin'] = lsetCtrlMap; -- store in the record

  -- If ONE BIN state then create just that one.  If Multi-bin, then create all
  -- of them.
  if lsetCtrlMap.StoreState == 0 then
    -- Create just the FIRST bin (bin ZERO)  with an empty list.
    setupNewBin( topRec, 0 );
  else
    -- Create ALL of the new bins, each with an empty list
    -- Our "indexing" starts with ZERO, to match the modulo arithmetic.
    for i = 0, (distrib - 1), 1 do
      setupNewBin( topRec, i );
    end -- for each new bin
  end

  -- All done, store the record
  local rc = -99; -- Use Odd starting Num: so that we know it got changed
  if( not aerospike:exists( topRec ) ) then
    GP=F and trace("[DEBUG]:<%s:%s>:Create Record()", mod, meth );
    rc = aerospike:create( topRec );
  else
    GP=F and trace("[DEBUG]:<%s:%s>:Update Record()", mod, meth );
    rc = aerospike:update( topRec );
  end

  GP=F and trace("[EXIT]: <%s:%s> : Done.  RC(%d)", mod, meth, rc );
  return rc;
end -- function asLSetCreate( record, namespace, set, distrib )

-- ======================================================================
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- || AS Large Set Insert 
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- Insert a value into the set.
-- Take the value, perform a hash and a modulo function to determine which
-- bin list is used, then add to the list.
--
-- We will use predetermined BIN names for this initial prototype
-- 'AsLSetCtrlBin' will be the name of the bin containing the control info
-- 'LSetBin_XX' will be the individual bins that hold lists of data
-- Notice that this means that THERE CAN BE ONLY ONE AS Set object per record.
-- In the final version, this will change -- there will be multiple 
-- AS Set bins per record.  We will switch to a modified bin naming scheme.
--
-- NOTE: Design, V2.  We will cache all data in the FIRST BIN until we
-- reach a certain number N (e.g. 100), and then at N+1 we will create
-- all of the remaining bins in the record and redistribute the numbers, 
-- then insert the 101th value.  That way we save the initial storage
-- cost of small, inactive or dead users.
-- ==> The CtrlMap will show which state we are in:
-- (*) StoreState=0: We are in SINGLE BIN state (no hash)
-- (*) StoreState=1: We hash, mod N, then insert (append) into THAT bin.
--
-- +========================================================================+=~
-- | Usr Bin 1 | Usr Bin 2 | o o o | Usr Bin N | Set CTRL BIN | Set Bins... | ~
-- +========================================================================+=~
--    ~=+===========================================+
--    ~ | Set Bin 1 | Set Bin 2 | o o o | Set Bin N |
--    ~=+===========================================+
--            V           V                   V
--        +=======+   +=======+           +=======+
--        |V List |   |V List |           |V List |
--        +=======+   +=======+           +=======+
--
-- Parms:
-- (*) topRec: the Server record that holds the Large Set Instance
-- (*) namespace: The Namespace of the record (topRec)
-- (*) set: The Set of the record (topRec)
-- (*) lsetBinName: The name of the bin for the AS Large Set
-- (*) distrib: The Distribution Factor (how many separate bins) 
-- (*) newValue: Value to be inserted into the Large Set
function asLSetInsert( topRec, namespace, set, lsetBinName, distrib, newValue )
  local mod = "AsLSetStickman";
  local meth = "asLSetInsert()";
  GP=F and trace("[ENTER]:<%s:%s>NS(%s) Set(%s) SetBin(%s) D(%s) NewValue(%s)",
    mod, meth, tostring(namespace),tostring(set),tostring(lsetBinName),
    tostring(distrib), tostring( newValue ));

  local lsetCtrlMap;

  -- Check that the Set Structure is already there, otherwise, error
  if( topRec['AsLSetCtrlBin'] == nil ) then
    warn("[WARNING]: <%s:%s> AsLSetCtrlBin does not Exist:Creating",mod,meth );
    lsetCtrlMap =
      initializeLSetMap( topRec, namespace, set, lsetBinName, distrib );
    topRec['AsLSetCtrlBin'] = lsetCtrlMap;
  else
    lsetCtrlMap = topRec['AsLSetCtrlBin'];
  end

  -- When we're in "Compact" mode, before each insert, look to see if 
  -- it's time to rehash our single bin into all bins.
  local totalCount = lsetCtrlMap.TotalCount;
  if lsetCtrlMap.StoreState == 0 and totalCount >= lsetCtrlMap.ThreshHold then
    rehashSet( topRec, lsetBinName, lsetCtrlMap );
  end

  -- Call our local multi-purpose insert() to do the job.(Update Stats)
  localInsert( topRec, lsetCtrlMap, newValue, 1 );

  topRec['AsLSetCtrlBin'] = lsetCtrlMap;
  -- All done, store the record
  local rc = -99; -- Use Odd starting Num: so that we know it got changed
  if( not aerospike:exists( topRec ) ) then
    GP=F and trace("[DEBUG]:<%s:%s>:Create Record()", mod, meth );
    rc = aerospike:create( topRec );
  else
    GP=F and trace("[DEBUG]:<%s:%s>:Update Record()", mod, meth );
    rc = aerospike:update( topRec );
  end

  GP=F and trace("[EXIT]: <%s:%s> : Done.  RC(%d)", mod, meth, rc );
  return rc
end -- function set Insert()

-- ======================================================================
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- || as Large Set Exists
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- 
-- Return 1 item if the item exists in the set, otherwise return 0.
-- We don't want to return "true" and "false" because of Lua Weirdness
-- So, similar to insert -- take the new value and locate the right bin.
-- Then, scan the bin's list for that item (linear scan).
--
-- ======================================================================
function asLSetExists( topRec, setBinName, searchValue )
  local mod = "AsLSetStickman";
  local meth = "asLSetSearch()";
  GP=F and trace("[ENTER]: <%s:%s> Search for Value(%s)",
    mod, meth, tostring( searchValue ) );

  -- Check that the Set Structure is already there, otherwise, error
  if( topRec['AsLSetCtrlBin'] == nil ) then
    GP=F and trace("[ERROR EXIT]: <%s:%s> AsLSetCtrlBin does not Exist",
    mod, meth );
    return('AsLSetCtrlBin does not exist');
  end

  -- Find the appropriate bin for the Search value
  local lsetCtrlMap = topRec['AsLSetCtrlBin'];
  local binNumber = computeSetBin( searchValue, lsetCtrlMap );
  local binName = getBinName( binNumber );
  local binList = topRec[binName];
  -- local result = scanList( binList, searchValue, 0 ); -- do NOT delete
  local result = scanList( lsetCtrlMap, binList, searchValue, SCAN );
  if result == nil then
    return 0
  else
    return 1
  end

end -- function asLSetSearch()



-- ======================================================================
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- || as Large Set Search
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- 
-- Return the item if the item exists in the set.
-- So, similar to insert -- take the new value and locate the right bin.
-- Then, scan the bin's list for that item (linear scan).
--
-- ======================================================================
function asLSetSearch( topRec, setBinName, searchValue )
  local mod = "AsLSetStickman";
  local meth = "asLSetSearch()";
  GP=F and trace("[ENTER]: <%s:%s> Search for Value(%s)",
    mod, meth, tostring( searchValue ) );

  -- Check that the Set Structure is already there, otherwise, error
  if( topRec['AsLSetCtrlBin'] == nil ) then
    GP=F and trace("[ERROR EXIT]: <%s:%s> AsLSetCtrlBin does not Exist",
    mod, meth );
    return('AsLSetCtrlBin does not exist');
  end

  -- Find the appropriate bin for the Search value
  local lsetCtrlMap = topRec['AsLSetCtrlBin'];
  local binNumber = computeSetBin( searchValue, lsetCtrlMap );
  local binName = getBinName( binNumber );
  local binList = topRec[binName];
  -- local result = scanList( binList, searchValue, 0 ); -- do NOT delete
  local result = scanList( lsetCtrlMap, binList, searchValue, SCAN );

  GP=F and trace("[EXIT]: <%s:%s>: Search Returns (%s)",
    mod,meth,tostring(result));
    if result == nil then
      return ('Not Found')
    else
      return result;
    end
end -- function asLSetSearch()


-- ======================================================================
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- || as Set Delete
-- |||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||||
-- ======================================================================
-- Find an element (i.e. search) and then remove it from the list.
-- Return the element if found, return nil if not found.
-- ======================================================================
function asLSetDelete( topRec, setBinName, deleteValue )
  local mod = "AsLSetStickman";
  local meth = "asLSetDelete()";
  GP=F and trace("[ENTER]: <%s:%s> Delete Value(%s)",
    mod, meth, tostring( deleteValue ) );

  -- Check that the Set Structure is already there, otherwise, error
  if( topRec['AsLSetCtrlBin'] == nil ) then
    GP=F and trace("[ERROR EXIT]: <%s:%s> AsLSetCtrlBin does not Exist",
      mod, meth );
    return('AsLSetCtrlBin does not exist');
  end

  -- Find the appropriate bin for the Search value
  local lsetCtrlMap = topRec['AsLSetCtrlBin'];
  local binNumber = computeSetBin( deleteValue, lsetCtrlMap );

  local binName = getBinName( binNumber );
  local binList = topRec[binName];
  -- Fow now, scanList() will only NULL out the element in a list, but will
  -- not collapse it.  Later, if we see that there are a LOT of nil entries,
  -- we can RESET the set and remove all of the "gas".
  -- local result = scanList( binList, deleteValue, 1);
  local result = scanList( lsetCtrlMap, binList, deleteValue, DELETE );
  -- If we found something, then we need to update the bin and the record.
  if result ~= nil then
    -- We found something -- and marked it nil -- so update the record
    topRec[binName] = binList;
    rc = aerospike:update( topRec );
  end

  GP=F and trace("[EXIT]: <%s:%s>: Delete Returns (%s) \n",
    mod, meth, tostring( result ));

  return result;
end -- function asLSetDelete()

-- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> -- <EOF> --
