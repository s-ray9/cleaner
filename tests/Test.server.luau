const ReplicatedStorage = game:GetService("ReplicatedStorage")

const Cleaner = require(ReplicatedStorage:WaitForChild("Cleaner"))

local passed, failed = 0, 0

const function check(label, condition)
	if condition then
		passed += 1
	else
		failed += 1
		warn("FAIL: " .. label)
	end
end

const function raises(label, fn, needle)
	const ok, err = pcall(fn)
	check(label .. " (errors)", not ok)
	if not ok and needle then
		check(label .. " (mentions '" .. needle .. "')", string.find(tostring(err), needle, 1, true) ~= nil)
	end
	return err
end

const function raisesAtCaller(label, fn, needle)
	const err = raises(label, fn, needle)
	check(label .. " (location is this script, not Cleaner)", string.find(tostring(err), script.Name, 1, true) ~= nil)
end

const function newPart()
	const part = Instance.new("Part")
	part.Anchored = true
	part.Parent = workspace
	return part
end

const function throwingTable(fields)
	return setmetatable(fields or {}, {
		__index = function(_, key)
			error("indexed missing '" .. tostring(key) .. "'", 0)
		end,
	})
end

print("=== Add / Run / Infer against real values ===")
do
	const cleaner = Cleaner.new()
	local ran = 0
	cleaner:Add(nil, function()
		ran += 1
	end)
	cleaner:Run(function()
		ran += 1
	end)
	cleaner:Destroy()
	check("Add and Run both run", ran == 2)
end
do
	const cleaner = Cleaner.new()
	const part = newPart()
	check("Infer returns the object", cleaner:Infer(part) == part)
	cleaner:Destroy()
	task.wait()
	check("Infer destroys a real Instance", part.Parent == nil)
end
do
	const cleaner = Cleaner.new()
	const part = newPart()
	const connection = part.Touched:Connect(function() end)
	cleaner:Infer(connection)
	cleaner:Destroy()
	check("Infer disconnects a real RBXScriptConnection", connection.Connected == false)
	part:Destroy()
end
do
	const cleaner = Cleaner.new()
	local finished = false
	const thread = task.spawn(function()
		task.wait(30)
		finished = true
	end)
	cleaner:Infer(thread)
	const ok = pcall(cleaner.Destroy, cleaner)
	task.wait(0.1)
	check("Infer cancels a real thread without throwing", ok and finished == false)
end
do
	const cleaner = Cleaner.new()
	local destroyed, lower, disconnected = 0, 0, 0
	cleaner:Infer({
		Destroy = function()
			destroyed += 1
		end,
	})
	cleaner:Infer({
		destroy = function()
			lower += 1
		end,
	})
	cleaner:Infer({
		Disconnect = function()
			disconnected += 1
		end,
	})
	cleaner:Destroy()
	check("Infer handles :Destroy / :destroy / :Disconnect tables", destroyed == 1 and lower == 1 and disconnected == 1)
end
do
	const cleaner = Cleaner.new()
	raisesAtCaller("Infer unknown shape", function()
		cleaner:Infer({ data = 1 })
	end, "no cleanup contract")
	const err = raises("Infer GoodSignal-style table with nothing usable", function()
		cleaner:Infer(throwingTable())
	end, "no cleanup contract")
	check("Infer does not leak the table's own error", string.find(tostring(err), "indexed missing", 1, true) == nil)
	local ran = false
	cleaner:Infer(throwingTable({
		Destroy = function()
			ran = true
		end,
	}))
	cleaner:Destroy()
	check("Infer finds :Destroy on a throwing-__index table", ran)
end

print("=== Cleanup order, error resilience ===")
do
	const cleaner, order = Cleaner.new(), {}
	for i = 1, 5 do
		cleaner:Run(function()
			table.insert(order, i)
		end)
	end
	cleaner:Cleanup()
	check("cleanup runs newest-first", table.concat(order, ",") == "5,4,3,2,1")
end
do
	const cleaner, ran = Cleaner.new(), {}
	cleaner:Run(function()
		table.insert(ran, "first-added")
	end)
	cleaner:Run(function()
		error("boom", 0)
	end)
	cleaner:Run(function()
		table.insert(ran, "last-added")
	end)
	const ok, err = pcall(cleaner.Cleanup, cleaner)
	check("a throwing cleanup does not stop the others", table.concat(ran, ",") == "last-added,first-added")
	check("the error is re-raised after everything ran", not ok and string.find(tostring(err), "boom", 1, true) ~= nil)
	local again = false
	cleaner:Run(function()
		again = true
	end)
	cleaner:Cleanup()
	check("container is reusable after a throwing Cleanup", again)
end
do
	const cleaner = Cleaner.new()
	local late = false
	cleaner:Run(function()
		cleaner:Destroy()
	end)
	cleaner:Run(function()
		cleaner:Run(function()
			late = true
		end)
	end)
	cleaner:Cleanup()
	check("Destroy() inside a Cleanup pass does not strand entries added in that pass", late and cleaner:IsDestroyed())
end

print("=== Track ===")
do
	const cleaner, part = Cleaner.new(), newPart()
	cleaner:Track("k", part)
	check("Track stores the value", cleaner:Get("k") == part)
	part:Destroy()
	task.wait()
	check("Track clears the entry when a real Instance is destroyed", not cleaner:Has("k"))
end
do
	const cleaner, first, second = Cleaner.new(), newPart(), newPart()
	const log = {}
	cleaner:Track("k", first, function()
		table.insert(log, "first")
	end)
	cleaner:Track("k", second, function()
		table.insert(log, "second")
	end)
	check("replacing runs the old cleanup", #log == 1 and log[1] == "first")
	first:Destroy()
	task.wait()
	check("the replaced value dying does not affect the new entry", cleaner:Get("k") == second)
	cleaner:Track("k", nil)
	check("Track(key, nil) clears", not cleaner:Has("k") and log[2] == "second")
	second:Destroy()
end
do
	const cleaner, part = Cleaner.new(), newPart()
	local runs = 0
	const cleanup = function()
		runs += 1
	end
	cleaner:Track("k", part, cleanup)
	cleaner:Track("k", part, cleanup)
	check("an identical Track call is idempotent", runs == 0)
	part:Destroy()
end
do
	const cleaner, event = Cleaner.new(), Instance.new("BindableEvent")
	cleaner:Track("custom", { Destroying = event.Event })
	event:Fire()
	task.wait()
	check("Track works with a real signal on a custom object", not cleaner:Has("custom"))
	event:Destroy()
end
do
	const cleaner, event = Cleaner.new(), Instance.new("BindableEvent")
	const object = throwingTable({ Destroying = event.Event })
	cleaner:Track("goodsignal", object)
	event:Fire()
	task.wait()
	check("Track works with a throwing-__index object", not cleaner:Has("goodsignal"))
	event:Destroy()
end
do
	const cleaner, group = Cleaner.new(), Cleaner.new()
	cleaner:Track("group", group)
	group:Destroy()
	check("Track accepts a Cleaner and clears when it is destroyed", not cleaner:Has("group"))
end
do
	const cleaner = Cleaner.new()
	raisesAtCaller("Track unparented Instance", function()
		cleaner:Track("k", Instance.new("Part"))
	end, "parented")
	raisesAtCaller("Track without a key", function()
		cleaner:Track(nil, newPart())
	end, "requires a key")
	raisesAtCaller("Track non-signal Destroying field", function()
		cleaner:Track("k", { Destroying = true })
	end, "Cleaner:Track")
end

print("=== Bind / BindAll ===")
do
	const cleaner, part = Cleaner.new(), newPart()
	cleaner:Bind(part)
	check("Bind: alive before", not cleaner:IsDestroyed())
	part:Destroy()
	task.wait()
	check("Bind: destroyed when the Instance is destroyed", cleaner:IsDestroyed())
end
do
	const cleaner = Cleaner.new()
	raisesAtCaller("Bind unparented Instance", function()
		cleaner:Bind(Instance.new("Part"))
	end, "parented")
	raisesAtCaller("Bind nil", function()
		cleaner:Bind(nil)
	end, "Cleaner:Bind")
	raisesAtCaller("Bind wrong shape", function()
		cleaner:Bind({})
	end, "Cleaner:Bind")
	check("rejected Binds never destroyed the Cleaner", not cleaner:IsDestroyed())
end
do
	const cleaner, event = Cleaner.new(), Instance.new("BindableEvent")
	cleaner:Bind({ Destroying = event.Event })
	event:Fire()
	task.wait()
	check("Bind works with a custom object's real signal", cleaner:IsDestroyed())
	event:Destroy()
end
do
	const cleaner, part = Cleaner.new(), newPart()
	cleaner:Destroy()
	raisesAtCaller("Bind on a destroyed Cleaner", function()
		cleaner:Bind(part)
	end, "destroyed Cleaner")
	part:Destroy()
end
do
	const cleaner, parts = Cleaner.new(), { newPart(), newPart(), newPart() }
	cleaner:BindAll(parts)
	for i = 1, 2 do
		parts[i]:Destroy()
		task.wait()
		check("BindAll waits (" .. i .. "/3)", not cleaner:IsDestroyed())
	end
	parts[3]:Destroy()
	task.wait()
	check("BindAll completes on the last Instance", cleaner:IsDestroyed())
end
do
	const cleaner, a, b = Cleaner.new(), newPart(), newPart()
	cleaner:BindAll({ a, b })
	a.Parent = nil
	task.wait()
	a.Parent = workspace
	task.wait()
	a.Parent = nil
	task.wait()
	check("BindAll counts an Instance once even if it leaves the tree repeatedly", not cleaner:IsDestroyed())
	b:Destroy()
	task.wait()
	check("BindAll completes when the other one goes", cleaner:IsDestroyed())
	a:Destroy()
end
do
	const cleaner, a, b = Cleaner.new(), newPart(), newPart()
	const handle = cleaner:BindAll({ a, b }, "batch")
	check("BindAll returns one handle and one key for the group", cleaner:Has(handle) and cleaner:Has("batch"))
	cleaner:Remove("batch")
	a:Destroy()
	b:Destroy()
	task.wait()
	check("removing the group handle unbinds without destroying", not cleaner:IsDestroyed())
end
do
	const cleaner = Cleaner.new()
	const group = cleaner:Extend()
	const item1, item2, item3 = newPart(), newPart(), newPart()
	group:BindAll({ item1, item2 })
	cleaner:Bind(group)
	cleaner:Bind(item3)
	item1:Destroy()
	task.wait()
	check("(1 AND 2) OR 3: partial", not cleaner:IsDestroyed())
	item2:Destroy()
	task.wait()
	check("(1 AND 2) OR 3: AND branch completes", cleaner:IsDestroyed() and group:IsDestroyed())
	item3:Destroy()
end
do
	const cleaner = Cleaner.new()
	const orGroup = cleaner:Extend()
	const item1, item2, item3 = newPart(), newPart(), newPart()
	orGroup:Bind(item1)
	orGroup:Bind(item2)
	cleaner:BindAll({ orGroup, item3 })
	item2:Destroy()
	task.wait()
	check("(1 OR 2) AND 3: OR satisfied, still waiting", not cleaner:IsDestroyed() and orGroup:IsDestroyed())
	item3:Destroy()
	task.wait()
	check("(1 OR 2) AND 3: complete", cleaner:IsDestroyed())
	item1:Destroy()
end
do
	const cleaner, part = Cleaner.new(), newPart()
	cleaner:Track("part", part)
	const extras = cleaner:Extend()
	extras:Bind(part)
	local ran = false
	extras:Run(function()
		ran = true
	end)
	part:Destroy()
	task.wait()
	check("Track + Extend/Bind share the value's lifetime", not cleaner:Has("part") and extras:IsDestroyed() and ran)
end

print("=== Extend and lifecycle ===")
do
	const parent = Cleaner.new()
	local ran = 0
	const child = parent:Extend()
	child:Run(function()
		ran += 1
	end)
	parent:Destroy()
	check("Extend: parent destroys child", child:IsDestroyed() and ran == 1)
end
do
	const parent, child = Cleaner.new(), Cleaner.new()
	parent:Bind(child)
	child:Cleanup()
	check("a plain Cleanup() on a bound Cleaner is not its death", not parent:IsDestroyed())
	child:Destroy()
	check("Destroy() on a bound Cleaner is its death", parent:IsDestroyed())
end
do
	const cleaner, group = Cleaner.new(), Cleaner.new()
	cleaner:Track("group", group)
	group:Cleanup()
	check("Track(key, cleaner) survives the cleaner's plain Cleanup()", cleaner:Has("group"))
end
do
	const cleaner = Cleaner.new()
	cleaner:Destroy()
	raisesAtCaller("Add after Destroy", function()
		cleaner:Add(nil, function() end)
	end, "Cleaner:Add")
	raisesAtCaller("Run after Destroy", function()
		cleaner:Run(function() end)
	end, "Cleaner:Run")
	raisesAtCaller("Extend after Destroy", function()
		cleaner:Extend()
	end, "Cleaner:Extend")
end
do
	const cleaner = Cleaner.new()
	const handle = cleaner:Add(nil, function() end)
	raises("handle read is blocked", function()
		return handle.removed
	end)
	raises("handle write is blocked", function()
		handle.removed = true
	end)
end

print("=== THE VOID TEST ===")
do
	const cleaner = Cleaner.new()
	const part = Instance.new("Part")
	part.CanCollide = false
	part.Position = Vector3.new(0, workspace.FallenPartsDestroyHeight - 50, 0)
	part.Parent = workspace

	cleaner:Bind(part)
	local caught = false
	for _ = 1, 100 do
		task.wait(0.1)
		if cleaner:IsDestroyed() then
			caught = true
			break
		end
	end
	check("Bind catches removal through FallenPartsDestroyHeight", caught)
end

print(string.format("=== RESULTS: %d passed, %d failed ===", passed, failed))
