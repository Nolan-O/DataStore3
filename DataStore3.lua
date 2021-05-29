--[[
	MIT License

	Copyright (c) 2021 Nolan-O

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
]]

local game = game
local new_coroutine = coroutine.create
local resume_coroutine = coroutine.resume

--[[
	The philosophy behind this module is that any object which has data that needs to be stored should be able to go
		into a datastore simply by adding rules for how to do so. As a result of that thinking, a DS3Compliant object
		is any object which contains methods to serialze and deserialize its data.
		Realistically you also need to supply some versioning data.

	This module is pretty straight-forward: you set up a databinding by passing in a list of DS3Compliant tables.
		The key for each DS3Compliant is the name it will be stored under the master key with, after it serializes.
		However that shouldn't come up in normal DS3 use. It may be important for people who are still trying to
		save bytes in their stores.

	Example of a binding being set up (see DS3.NewDataBinding for detailed overview of how the arguments are used):
	```
		local character = NewCharacter()
		local DSkey = "P_" .. plr.UserId
		character.DataBinding = DS3.NewDataBinding(storeName, DSkey,
		{
		  --Store name | lua object to be stored
			Inventory = character.Inventory,
		},
			character, OnPlayerLoadFinished
		)
	```

	Example Inventory as a DS3Compliant, using multiple data versions as well:
	```
		local function Deserialize_v1( stored_tbl )
			--Version one stuff
		end
		local function Deserialize_v2( stored_tbl )
			--Version two stuff
		end

		char.Inventory = {
			StoreRetrieved = false

			--The Contents table is just for example, it is not part of the DS3 requirements.
			Contents = { 1, 0, 0, 3, 4, 0, 1 }

			DS3Versions = {
				Latest = "v2",
				["v1"] = Deserialize_v1,
				["v2"] = Deserialize_v2
			}

			Serialize = function()
				local data = { }

				for i = 1, Inventory.Contents, 1 do
					data[#data + 1] = Inventory.Contents[i]
				end

				return data
			end
		}
	```

A full explanation of versions:
	Every time you save something with a datastore, the layout of the data can only be understood with the correct
		Deserialize procedure, which is not surprising. To enable games to freely update their internal systems, free
		of worry about DataStore compatibility, we support versionsed Stores.
	@Note: Newer DataStore API features support version tags on Stores, but this module predates such functionality.

	To add a new version, you create a new Deserialze function and point at it via the DS3Versions table, using the
		version tag as a key. You do not erase old versions, that undermines the purpose of the versioning system.
		You then update the Serialize function to comply with the newest Deserialize function. The result is a list of
		methods to Deserialize older versions, but only one way to Serialize, and the Serialize method is up-to-date...
		***Therefore older stores will be converted to the newer versions upon saving***
			(after an older Deserialize method is successful in deserializing the older version)

	Internally, versions of a store are tracked by DS3 inserting an `__VERSION` field, which is used as a key into the
		DS3Versions table which lists the various Deserialize functions.

	The "current" version is specified by a reserved field: DS3Versions.Latest; Any new saves will be tagged as the
		value stored in that field

Callbacks:
	The only callback in this module is a function passed as the final argument to DS3.NewDataBinding, `OnLoadFinished`
	This function, which is called from _GetAsync has finished, will recieve the DS3 DataBinding as the first argument,
		and the DataBinding's Parent object (such as a player, etc) as the second argument. This callback function is
		intended to be the standard way of responding to a DataStore finishing loading.

	Additional lists of callbacks for saving and loading would be trivial to implement, however the use cases for such
		design seems limited, and easily problematic, so implementing additional callbacks has been left as a task for
		people that really know they need them.
]]

local RunService = game:GetService("RunService")
local DataStores = game:GetService("DataStoreService")


local IsStudio = RunService:IsStudio()
local SaveInStudio = true
local EnableAutosaves = true
local AUTOSAVE_INTERVAL = 360.0

local DS3 = { }
local Stores = { }
local BindingsList = { }

local ERR_NOT_DS3_OBJ = "Unserializable object in DS3 binding! Store: `%s` Master-key: `%s` Sub-key: `%s`"
local ERR_REBINDING = "Attempt to overwrite DS3 binding / Sub-key: `%s` for Master-key: `%s` (same binding passed twice?)" 
local ERR_NO_BINDING = "Binding is nil after Get()! Master-key: `%s` Sub-key: `%s`\nRaw data:"
local ERR_NO_VERSIONS = "DS3Compliant has no listed versions! Master-key: `%s` Sub-key: `%s`"
local ERR_INCOMPLETE_VERSIONS = "DS3Compliant has missing Deserialze function! Master-key: `%s` Sub-key: `%s` Version: `%s`"
local ERR_NO_LATEST_VERSION = "DS3Compliant has no specified latest version! Master-key: `%s` Sub-key: `%s`"
local ERR_INVALID_LATEST = "DS3Compliant has latest version, but version does not exist! Master-key: `%s` Sub-key: `%s` Version: `%s`"
local ERR_DESERIALIZE = "Deserialize failed! Master-key: `%s` Sub-key: `%s`"
local ERR_EARLY_SAVE = "DS3 saved before any Get(); possible data corruption! Store: `%s` Master-key: `%s`"
local ERR_NO_SAVE = "DataStore save failed with code: %s"
local ERR_NO_GET = "DataStore get failed with code: %s This DataBinding will not save!"
--This is a big error that's easy to make.
--Mixing of indices' types will cause some indices to be silently lost to the DataStore's JSON serialization process.
--For each table recieved by JSONEncode, the indices must be EITHER strings OR ints.
local ERR_INVALID_TBL = "DATA LOST!!! Keys to table were not exclusively strings or ints! Store: `%s` Master-key: `%s` Sub-key: `%s`"

--Some types just for context
type array<T> = 		{ [number]: T }
type JSONTable =		{ [string]: (string | number | boolean | array<(string | number | boolean)> ) }
--The useful type annotations
type DeserializeFunc = 	( JSONTable ) -> boolean
type SerializeFunc = 	(DS3Compliant) -> { [string]: any }
type DS3Compliant = 	{ StoreRetrieved: boolean, DS3Versions: { [string]: number }, Serialize: SerializeFunc, Deserialize: DeserializeFunc }
type BindingList = 		{ [string]: DS3Compliant }

--NewDataBinding has the side effect of automatically fetching the store that is associated with it.
function DS3.NewDataBinding(StoreName: string, MasterKey: string, Bindings: BindingList, Parent: any, OnLoadFinished: (DS3Binding, any) -> nil ): DS3Binding
	assert(typeof(StoreName) == "string")
	assert(typeof(MasterKey) == "string")
	assert(typeof(Bindings) == "table")

	if not Stores[StoreName] then
		--TODO: Log the creation of new data stores to have a record of mis-named stores and keys
		Stores[StoreName] = DataStores:GetDataStore(StoreName)
	end

	local self = {
		--Metadata
		storeName = StoreName,
		masterKey = MasterKey,
		masterTbl = { [MasterKey] = { } },
		bindings = { },
		--The parent is used as an argument passed back to the callback function
		--A decision made to avoid the use of anonymous functions when possible
		Parent = Parent,

		--State variables
		_retrieved = false,
		_dontSave = false,

		--DS Functions
		SaveAsync = DS3.SaveAsync,
		GetAsync = DS3.GetAsync,
		Finalize = DS3.Finalize,

		OnLoadFinished = OnLoadFinished
	}

	--Verify lua objects targeted by a binding are actual DS3Compliant before going forward
	for key, DS3Obj in pairs(Bindings) do
		if self.bindings[key] ~= nil then
			error(string.format(ERR_REBINDING, key, MasterKey))
		end

		--Verifying that we can serialize is trivial
		if DS3Obj.Serialize == nil then
			error(string.format(ERR_NOT_DS3_OBJ, StoreName, MasterKey, key))
		end

		--Verifying that we can deserialize requires us to find a list of versions and check the latest one
		do
			if DS3Obj.DS3Versions == nil or type(DS3Obj.DS3Versions) ~= "table" then
				error(string.format(ERR_NO_VERSIONS, MasterKey, key))
			end

			for version, deserialize_func in pairs(DS3Obj.DS3Versions) do
				assert(typeof(version) == "string")
				if version == "Latest" then
					continue
				end

				if not deserialize_func or typeof(deserialize_func) ~= "function" then
					error(string.format(ERR_INCOMPLETE_VERSIONS, MasterKey, key, tostring(version)))
				end
			end

			local latest_version = DS3Obj.DS3Versions.Latest
			if not latest_version then
				error(string.format(ERR_NO_LATEST_VERSION, MasterKey, key))
			end

			local latest_version_found = false
			for version, _ in pairs(DS3Obj.DS3Versions) do
				if version == latest_version then
					latest_version_found = true
					break
				end
			end

			if not latest_version_found then
				error(string.format(ERR_INVALID_LATEST, MasterKey, key, tostring(latest_version)))
			end
		end

		self.bindings[key] = DS3Obj
	end

	table.insert(BindingsList, self)

	self:GetAsync()

	return self
end

--[[
	Verifies the types of indices to notify if an index error causes data loss
	If this returns false in production, a major error is occuring!
]]
local function verify_table_recursive(tbl: table): boolean
	local bad_type_found = false
	for i, v in pairs(tbl) do
		local index_type = type(i)
		if index_type ~= "string" and index_type ~= "number" then
			bad_type_found = true
		end

		if bad_type_found == true then
			return false
		end

		if type(v) == "table" then
			local is_sub_valid = verify_table_recursive(v)

			if is_sub_valid == false then
				return false
			end
		end
	end

	return true
end

--[[
	_SaveAsync is the target of a coroutine spawned by DS3.SaveAsync
]]
local function _SaveAsync(self: DS3Binding, callback: (boolean) -> nil)
	if not self._retrieved then
		warn(string.format(ERR_EARLY_SAVE, self.storeName, self.masterKey), "\nSave skipped!")
		return
	end

	local masterKey = self.masterKey
	for key, DS3Obj in pairs(self.bindings) do
		local serial_data = DS3Obj.Serialize( DS3Obj )
		local is_valid = verify_table_recursive(serial_data)

		serial_data["__VERSION"] = DS3Obj.DS3Versions.Latest

		if is_valid then
			self.masterTbl[masterKey][key] = serial_data
		else
			warn(string.format(ERR_INVALID_TBL, self.storeName, self.masterKey, key))
		end
	end

	local store = Stores[self.storeName]
	local success, code = pcall( store.SetAsync, store, masterKey, self.masterTbl )
	if not success then
		warn(string.format(ERR_NO_SAVE, code))
	end

	if callback then
		callback(self, success)
	end
end

function DS3.SaveAsync(self: DS3Binding, callback: (boolean) -> nil)
	if IsStudio and not SaveInStudio then
		return
	end

	if self._dontSave == true then
		return
	end

	local success, err = resume_coroutine(new_coroutine(_SaveAsync), self, callback)

	if not success then
		error(err)
	end
end

--[[
	_GetAsync is the target of a coroutine spawned by DS3.GetAsync
]]
local function _GetAsync(self: DS3Binding)
	local store = Stores[self.storeName]
	local success, ret = pcall( store.GetAsync, store, self.masterKey )
	if success == false then
		warn(string.format(ERR_NO_GET, ret))
		self._dontSave = true
		ret = { }
	end

	ret = ret or { }
	local data = ret[self.masterKey] or { }

	for key, DS3Obj in pairs( self.bindings ) do
		--For uninitialized saves, sub_store can be nil. We substitute nil with an empty table, which a Deserialize
		--  function will typically populate with default data
		local sub_store = data[key] or { }

		if DS3Obj == nil then
			error(string.format(ERR_NO_BINDING, self.masterKey, key), sub_store)
		end

		local version = sub_store["__VERSION"]
		--Deserialize funcs don't need to see or worry about handling the __VERSION field, so we'll wipe it.
		sub_store["__VERSION"] = nil
		--If a version is somehow missing, fallback to the latest.
		version = version or DS3Obj.DS3Versions.Latest

		local success = DS3Obj.DS3Versions[DS3Obj.DS3Versions.Latest]( DS3Obj, sub_store, self )
		if success then
			DS3Obj.StoreRetrieved = true
		else
			warn(string.format(ERR_DESERIALIZE, self.masterKey, key))
		end
	end

	self._retrieved = true

	if self.OnLoadFinished then
		self.OnLoadFinished( self, self.Parent )
	end
end

function DS3.GetAsync(self: DS3Binding, bypass_cache: boolean)
	if self._retrieved and not bypass_cache then
		warn("Attempt to retrieve store multiple times")
		return
	end

	--coroutine.wrap is broken and will not execute the co before continuing this function. I suspect it's going straight to the task scheduler
	local success, err = resume_coroutine(new_coroutine(_GetAsync), self)

	if not success then
		error(err)
	end
end

local function OnFinalSave(self: DS3Binding, success: boolean)
	if success then
		table.remove(BindingsList, table.find(BindingsList, self))
	end
end

function DS3.Finalize(self)
	self:SaveAsync(OnFinalSave)
end

--A funciton which saves ALL existing DataBindings
function DS3.FinalizeAll()
	if IsStudio and not SaveInStudio then
		return
	end

	for i,DataBinding in pairs(BindingsList) do
		DataBinding:SaveAsync(OnFinalSave)
	end
end

local function AutoSave()
	wait(AUTOSAVE_INTERVAL)

	for _,binding in pairs(BindingsList) do
		binding:SaveAsync()
	end

	coroutine.wrap(AutoSave)()
end

if EnableAutosaves then
	coroutine.wrap(AutoSave)()
end

game:BindToClose(DS3.FinalizeAll)

return DS3