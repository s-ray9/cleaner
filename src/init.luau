const Cleaner = {}
Cleaner.__index = Cleaner

const taskCancel = task.cancel

const EntryHandle = {}

EntryHandle.__index = function(_, key)
	error(
		"Cleaner entry handles are opaque - cannot read '"
			.. tostring(key)
			.. "' from one. Use Cleaner:Get()/:Has() instead.",
		2
	)
end

EntryHandle.__newindex = function(_, key)
	error("Cleaner entry handles are opaque - cannot write '" .. tostring(key) .. "' on one.", 2)
end

EntryHandle.__tostring = function()
	return "CleanerEntry"
end

const function noop() end

const function destroyObject(object)
	object:Destroy()
end

const function runAll(list)
	for i = #list, 1, -1 do
		list[i]()
	end
end

const function readField(object, key)
	return object[key]
end

const function safeIndex(object, key)
	const ok, value = pcall(readField, object, key)
	if ok then
		return value
	end
	return nil
end

const function describe(value)
	const ok, name = pcall(typeof, value)
	if ok then
		return name
	end
	return type(value)
end

const function isEntryHandle(value)
	return type(value) == "table" and getmetatable(value) == EntryHandle
end

const function isInstance(value)
	return typeof(value) == "Instance"
end

const function isCleaner(value)
	return type(value) == "table" and getmetatable(value) == Cleaner
end

const function isSignal(value)
	if value == nil or value == false then
		return false
	end
	return type(safeIndex(value, "Once")) == "function" or type(safeIndex(value, "Connect")) == "function"
end

const function getDestroyingSignal(value)
	if type(value) ~= "table" then
		return nil
	end
	const upper = safeIndex(value, "Destroying")
	if isSignal(upper) then
		return upper
	end
	const lower = safeIndex(value, "destroying")
	if isSignal(lower) then
		return lower
	end
	return nil
end

const function disconnect(connection)
	if typeof(connection) == "RBXScriptConnection" then
		connection:Disconnect()
		return
	end
	const method = safeIndex(connection, "Disconnect")
	if type(method) == "function" then
		method(connection)
	end
end

const function watchUntilDead(thing, onDead)
	local finished = false

	const function fire()
		if finished then
			return
		end
		finished = true
		onDead()
	end

	if isCleaner(thing) then
		if thing._destroyed then
			fire()
			return nil
		end
		local watchers = thing._deathWatchers
		if not watchers then
			watchers = {}
			thing._deathWatchers = watchers
		end
		watchers[fire] = true
		return function()
			watchers[fire] = nil
		end
	end

	if isInstance(thing) then
		const connection = thing.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				fire()
			end
		end)
		return function()
			connection:Disconnect()
		end
	end

	const signal = getDestroyingSignal(thing)
	const once = safeIndex(signal, "Once")
	local connection
	if type(once) == "function" then
		connection = once(signal, fire)
	else
		connection = signal:Connect(fire)
	end
	return function()
		disconnect(connection)
	end
end

const function destroyedMessage(methodName)
	return "cannot call Cleaner:" .. methodName .. "() on a destroyed Cleaner"
end

const function nanMessage(methodName)
	return "Cleaner:" .. methodName .. " does not accept NaN as a key"
end

const function watchProblem(thing, methodName)
	if isInstance(thing) then
		if thing.Parent == nil then
			return "Cleaner:"
				.. methodName
				.. " requires an Instance to be currently parented - an unparented "
				.. "Instance is ambiguous (not yet placed? pooled? already destroyed?). Parent it first."
		end
		return nil
	end
	if isCleaner(thing) or getDestroyingSignal(thing) ~= nil then
		return nil
	end
	return "Cleaner:"
		.. methodName
		.. " requires an Instance, another Cleaner, or a table with a "
		.. "Destroying/destroying signal (got "
		.. describe(thing)
		.. ")"
end

const function resolve(self, keyOrHandle)
	if isEntryHandle(keyOrHandle) then
		const records = self._records
		return records and records[keyOrHandle]
	end
	const byKey = self._byKey
	return byKey and byKey[keyOrHandle]
end

const function release(self, record, runCleanup)
	if record.removed then
		return
	end
	record.removed = true

	const older, newer = record.prev, record.next
	if older then
		older.next = newer
	end
	if newer then
		newer.prev = older
	else
		self._tail = older
	end
	record.prev = nil
	record.next = nil

	const key = record.key
	if key ~= nil and self._byKey[key] == record then
		self._byKey[key] = nil
	end
	self._records[record.handle] = nil

	const watcher, object, cleanup = record.watcher, record.task, record.cleanup
	record.watcher = nil
	record.task = nil
	record.cleanup = nil

	if watcher then
		watcher()
	end
	if runCleanup then
		cleanup(object)
	end
end

const function claim(self, key)
	const byKey = self._byKey
	const existing = byKey and byKey[key]
	if existing then
		release(self, existing, true)
	end
end

const function install(self, object, cleanup, key)
	const handle = setmetatable({}, EntryHandle)
	const record = {
		task = object,
		cleanup = cleanup,
		key = key,
		handle = handle,
		removed = false,
		prev = self._tail,
	}

	local records = self._records
	if not records then
		records = {}
		self._records = records
	end
	records[handle] = record

	if self._tail then
		self._tail.next = record
	end
	self._tail = record

	if key ~= nil then
		local byKey = self._byKey
		if not byKey then
			byKey = {}
			self._byKey = byKey
		end
		byKey[key] = record
	end

	return handle, record
end

const function add(self, methodName, object, cleanup, key)
	if self._destroyed then
		return nil, nil, destroyedMessage(methodName)
	end
	if type(cleanup) ~= "function" then
		return nil, nil, "Cleaner:" .. methodName .. " requires a cleanup function (got " .. describe(cleanup) .. ")"
	end
	if key ~= key then
		return nil, nil, nanMessage(methodName)
	end
	if key ~= nil then
		claim(self, key)
		if self._destroyed then
			return nil, nil, destroyedMessage(methodName)
		end
	end
	const handle, record = install(self, object, cleanup, key)
	return handle, record, nil
end

const function bind(self, methodName, things, requireAll, key)
	if self._destroyed then
		return nil, destroyedMessage(methodName)
	end
	const total = #things
	for i = 1, total do
		const problem = watchProblem(things[i], methodName)
		if problem then
			return nil, problem
		end
	end
	if key ~= key then
		return nil, nanMessage(methodName)
	end
	if total == 0 then
		self:Destroy()
		return nil, nil
	end
	if key ~= nil then
		claim(self, key)
		if self._destroyed then
			return nil, destroyedMessage(methodName)
		end
	end

	local remaining = 1
	if requireAll then
		remaining = total
	end

	const function onGone()
		remaining = remaining - 1
		if remaining == 0 then
			self:Destroy()
		end
	end

	const disposers = {}
	local count = 0
	for i = 1, total do
		const dispose = watchUntilDead(things[i], onGone)
		if dispose then
			count = count + 1
			disposers[count] = dispose
		end
		if self._destroyed then
			break
		end
	end

	if self._destroyed then
		runAll(disposers)
		return nil, nil
	end

	const handle, record = install(self, nil, noop, key)
	if count == 1 then
		record.watcher = disposers[1]
	elseif count > 1 then
		record.watcher = function()
			runAll(disposers)
		end
	end
	return handle, nil
end

const function drain(self, snapshot, count, state)
	for i = state.next, count do
		state.next = i + 1
		release(self, snapshot[i], true)
	end
end

const function raise(errors)
	if #errors == 1 then
		error(errors[1], 0)
	end
	const messages = {}
	for i = 1, #errors do
		messages[i] = tostring(errors[i])
	end
	error(#errors .. " cleanup functions errored:\n\n" .. table.concat(messages, "\n\n"), 0)
end

const CONTRACTS = table.freeze({
	table.freeze({
		name = "connection (:Disconnect)",
		matches = function(value)
			return typeof(value) == "RBXScriptConnection"
				or (type(value) == "table" and type(safeIndex(value, "Disconnect")) == "function")
		end,
		dispose = function(value)
			value:Disconnect()
		end,
	}),
	table.freeze({
		name = "Instance (:Destroy)",
		matches = function(value)
			return typeof(value) == "Instance"
		end,
		dispose = function(value)
			value:Destroy()
		end,
	}),
	table.freeze({
		name = "thread (task.cancel)",
		matches = function(value)
			return type(value) == "thread"
		end,
		dispose = function(value)
			pcall(taskCancel, value)
		end,
	}),
	table.freeze({
		name = "table with :Destroy()",
		matches = function(value)
			return type(value) == "table" and type(safeIndex(value, "Destroy")) == "function"
		end,
		dispose = function(value)
			value:Destroy()
		end,
	}),
	table.freeze({
		name = "table with :destroy()",
		matches = function(value)
			return type(value) == "table" and type(safeIndex(value, "destroy")) == "function"
		end,
		dispose = function(value)
			value:destroy()
		end,
	}),
	table.freeze({
		name = "function (called directly)",
		matches = function(value)
			return type(value) == "function"
		end,
		dispose = function(value)
			value()
		end,
	}),
})

local contractNames = {}
for i = 1, #CONTRACTS do
	contractNames[i] = CONTRACTS[i].name
end
const CONTRACT_NAMES = table.concat(contractNames, ", ")

function Cleaner.new()
	return setmetatable({
		_destroyed = false,
		_cleaning = false,
	}, Cleaner)
end

function Cleaner:Add(object, cleanup, key)
	const handle, _record, problem = add(self, "Add", object, cleanup, key)
	if problem then
		error(problem, 2)
	end
	return handle
end

function Cleaner:Run(cleanup, key)
	const handle, _record, problem = add(self, "Run", nil, cleanup, key)
	if problem then
		error(problem, 2)
	end
	return handle
end

function Cleaner:Infer(object, key)
	for i = 1, #CONTRACTS do
		const contract = CONTRACTS[i]
		const ok, matched = pcall(contract.matches, object)
		if ok and matched then
			const _handle, _record, problem = add(self, "Infer", object, contract.dispose, key)
			if problem then
				error(problem, 2)
			end
			return object
		end
	end
	error(
		"Cleaner:Infer found no cleanup contract for a "
			.. describe(object)
			.. " value. Checked: "
			.. CONTRACT_NAMES
			.. ". Use :Add with an explicit cleanup function instead.",
		2
	)
end

function Cleaner:Track(key, value, cleanup)
	if self._destroyed then
		error(destroyedMessage("Track"), 2)
	end
	if key == nil then
		error("Cleaner:Track requires a key (use :Add if you don't need one)", 2)
	end
	if value == nil then
		self:Remove(key)
		return nil
	end
	const unwatchable = watchProblem(value, "Track")
	if unwatchable then
		error(unwatchable, 2)
	end

	cleanup = cleanup or noop

	const byKey = self._byKey
	const existing = byKey and byKey[key]
	if existing and existing.task == value and existing.cleanup == cleanup then
		return existing.handle
	end

	const handle, record, problem = add(self, "Track", value, cleanup, key)
	if problem then
		error(problem, 2)
	end
	record.watcher = watchUntilDead(value, function()
		release(self, record, true)
	end)
	return handle
end

function Cleaner:Extend(key)
	if self._destroyed then
		error(destroyedMessage("Extend"), 2)
	end
	const child = Cleaner.new()
	const _handle, _record, problem = add(self, "Extend", child, destroyObject, key)
	if problem then
		error(problem, 2)
	end
	return child
end

function Cleaner:Bind(thing, key)
	if thing == nil then
		error("Cleaner:Bind requires a thing to watch (got nil)", 2)
	end
	const handle, problem = bind(self, "Bind", { thing }, false, key)
	if problem then
		error(problem, 2)
	end
	return handle
end

function Cleaner:BindAll(things, key)
	if type(things) ~= "table" then
		error("Cleaner:BindAll requires an array of things (got " .. describe(things) .. ")", 2)
	end
	const handle, problem = bind(self, "BindAll", things, true, key)
	if problem then
		error(problem, 2)
	end
	return handle
end

function Cleaner:Get(keyOrHandle)
	const record = resolve(self, keyOrHandle)
	if record then
		return record.task
	end
	return nil
end

function Cleaner:Has(keyOrHandle)
	return resolve(self, keyOrHandle) ~= nil
end

function Cleaner:Remove(keyOrHandle)
	const record = resolve(self, keyOrHandle)
	if record then
		release(self, record, true)
	end
end

function Cleaner:Forget(keyOrHandle)
	const record = resolve(self, keyOrHandle)
	if record then
		release(self, record, false)
	end
end

function Cleaner:Cleanup()
	if self._cleaning then
		return
	end
	self._cleaning = true

	local errors
	const state = { next = 1 }
	repeat
		const snapshot = {}
		local count = 0
		local record = self._tail
		while record do
			count = count + 1
			snapshot[count] = record
			record = record.prev
		end

		state.next = 1
		while state.next <= count do
			const ok, err = xpcall(drain, debug.traceback, self, snapshot, count, state)
			if not ok then
				errors = errors or {}
				errors[#errors + 1] = err
			end
		end
	until not self._destroyed or self._tail == nil

	self._cleaning = false

	if errors then
		raise(errors)
	end
end

function Cleaner:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true

	local errors
	const cleaned, cleanupError = pcall(self.Cleanup, self)
	if not cleaned then
		errors = { cleanupError }
	end

	const watchers = self._deathWatchers
	if watchers then
		self._deathWatchers = nil
		const pending = {}
		local count = 0
		for fire in pairs(watchers) do
			count = count + 1
			pending[count] = fire
		end
		for i = 1, count do
			const ok, err = xpcall(pending[i], debug.traceback)
			if not ok then
				errors = errors or {}
				errors[#errors + 1] = err
			end
		end
	end

	if errors then
		raise(errors)
	end
end

function Cleaner:IsDestroyed()
	return self._destroyed
end

return table.freeze(Cleaner)
