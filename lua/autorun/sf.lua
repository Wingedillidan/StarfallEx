--[[

Starfall Context Structure:
{
	softQuotaUsed   (num) Soft quota used
	original        (str) Source code
	environment     (tbl) Variables, functions
	func            (fn)  The compiled script
	ent             (ent) The SF entity
	data            (tbl) Data used by modules
	ply             (ent) Person who owns the chip
}

SF_Compiler variables:
{
	softQuota       (convar) Amount of ops before the overflow is added into the soft quota
	hardQuota       (convar) Amount of ops to be used in a single execution before the processor shuts down
	softQuotaAmount (convar) Total quota for the soft quota

	envTable        (tbl) Metatable for context.environment
	currentChip     (tbl) Context of the chip currently running, or nil if no chip is running
}

]]

local min = math.min

SF_Compiler = {}

--SF_Compiler.softQuota = CreateConVar("starfall_quota", "10000", {FCVAR_ARCHIVE,FCVAR_REPLICATED})
SF_Compiler.hardQuota = CreateConVar("starfall_hardquota", "20000", {FCVAR_ARCHIVE,FCVAR_REPLICATED})
--SF_Compiler.softQuotaAmount = CreateConVar("starfall_softquota", "10000", {FCVAR_ARCHIVE,FCVAR_REPLICATED})

--------------------------- Execution ---------------------------

local env_table = {}
SF_Compiler.env_table = env_table
env_table.__index = env_table

function SF_Compiler.Compile(code, ply, ent)
	local sf = {}
	sf.softQuotaUsed = 0
	sf.original = code
	sf.environment = {}
	sf.ent = ent
	sf.ply = ply
	sf.data = {}
	
	local ok, func = pcall(CompileString, code, "Starfall", false)
	if not ok then return false, func end
	
	if func == nil then
		return false, "Unknown Compiler Error"
	elseif type(func) == "string" then
		return false, func
	end
	sf.func = func
	
	SF_Compiler.Reset(sf)
	return true, sf
end

function SF_Compiler.Reset(sf)
	sf.environment = setmetatable({},env_table)
	debug.setfenv(sf.func,sf.environment)
end

-- Runs a function inside of a Starfall context.
-- Throws an error if you try to run this inside of func.
-- Returns (ok, msg or whatever func returns)
function SF_Compiler.RunStarfallFunction(context, func, ...)
	if SF_Compiler.currentChip ~= nil then
		error("Tried to execute multiple SF processors simultaneously, or RunStarfallFunction did not clean up properly", 0)
	end
	SF_Compiler.currentChip = context
	local ok, ops, rt = pcall(SF_Compiler.RunFuncWithOpsQuota, func,
		--min(SF_Compiler.hardQuota:GetInt(), SF_Compiler.softQuota:GetInt() + SF_Compiler.softQuotaAmount:GetInt() - context.softQuotaUsed), ...)
		SF_Compiler.hardQuota:GetInt(), ...)
	--local ok, rt = pcall(func, ...)
	--local ops = 0
	SF_Compiler.currentChip = nil
	if not ok then return false, ops end
	
	--local softops = ops - SF_Compiler.softQuota:GetInt()
	--if softops > 0 then context.softQuotaUsed = context.softQuotaUsed + softops end
	return true, rt
end

-- debug.gethook() returns "external hook" instead of a function... |:/
-- (I think) it basically just errors after like 500,000 lines
local function infloop_detection_replacement()
	error("Infinite Loop Detected!",2)
end

-- Calls a function while counting the number of lines executed. Only counts lines that share
-- the same source file as the function called.
function SF_Compiler.RunFuncWithOpsQuota(func, max, ...)
	if max == nil then max = 1000000 end
	local used = 0
	
	local source = debug.getinfo(func,"S").source
	
	local oldhookfunc, oldhookmask, oldhookcount = debug.gethook()
	
	-- TODO: Optimize
	local function SF_OpHook(event, lineno)
		if event ~= "line" then return end
		if debug.getinfo(2,"S").source ~= source then return end
		used = used + 1
		if used > max then
			debug.sethook(infloop_detection_replacement,oldhookmask)
			error("Ops quota exceeded",3)
		end
	end
	
	debug.sethook(SF_OpHook,"l")
	local rt = func(...)
	debug.sethook(infloop_detection_replacement,oldhookmask,oldhookcount)
	
	return used, rt
end

--------------------------- Modules ---------------------------
SF_Compiler.modules = {}
function SF_Compiler.AddModule(name,tbl)
	print("SF: Adding module "..name)
	tbl.__index = tbl
	SF_Compiler.modules[name] = tbl
end

--------------------------- Hooks ---------------------------

function SF_Compiler.AddInternalHook(name, func)
	if not SF_Compiler.hooks[name] then SF_Compiler.hooks[name] = {} end
	SF_Compiler.hooks[name][func] = true
end

function SF_Compiler.RunInternalHook(name, ...)
	if not SF_Compiler.hooks[name] then return end
	for func,_ in pairs(SF_Compiler.hooks[name]) do
		func(...)
	end
end

SF_Compiler.hooks = {}
function SF_Compiler.CallHook(name, context, ...)
	if SF_Compiler.hooks[context] and SF_Compiler.hooks[context][name] then
		return SF_Compiler.RunStarfallFunction(context, SF_Compiler.hooks[context][name], ...)
	end
	return nil
end

--------------------------- Library Functions ---------------------------

-- Returns the type of an object, also checking the "type" index of a table
-- Note: can be faked
function SF_Compiler.GetType(obj)
	local typ = type(obj)
	if typ == "table" and obj.type then return obj.type
	else return typ end
end

-- Checks the type of an object using SF_Compiler.GetType. Throws a formatted error on mismatch.
-- desired = a metatable or a a type() string (note that getmetatable("<any string>") ~= string)
-- level = amount of levels away from the library function (0 or nil = the library function, 1 = a function inside of that, etc.)
function SF_Compiler.CheckType(obj, desired, level)
	if getmetatable(obj) == desired then return obj
	elseif type(obj) == desired then return obj
	else
		level = level or 0
		
		local typname
		if type(desired) == "table" then
			typname = desired.type or "table"
		else
			typname = type(desired)
		end
		
		local funcname = debug.getinfo(2+level, "n").name or "<unnamed>"
		error("Type mismatch (Expected "..typname..", got "..SF_Compiler.GetType(typ)..") in function "..funcname,3+level)
	end
end

-- Throws an error due to type mismatch. Exported because some functions take multiple types
function SF_Compiler.ThrowTypeError(obj, desired, level)
	level = level or 0
	local funcname = debug.getinfo(2+level, "n").name or "<unnamed>"
	error("Type mismatch (Expected "..desired..", got "..SF_Compiler.GetType(obj)..") in function "..funcname,3+level)
end


--------------------------- Misc ---------------------------

function SF_Compiler.ReloadLibraries()
	print("SF: Loading libraries...")
	SF_Compiler.modules = {}
	SF_Compiler.hooks = {}
	do
		local list = file.FindInLua("autorun/sflibs/*.lua")
		for _,filename in pairs(list) do
			print("SF: Including sflibs/"..filename)
			include("sflibs/"..filename)
		end
	end
	print("SF: End loading libraries")
	SF_Compiler.RunInternalHook("postload")
end
--concommand.Add("sf_reload_libraries",SF_Compiler.ReloadLibraries,nil,"Reloads starfall libraries")
SF_Compiler.ReloadLibraries()