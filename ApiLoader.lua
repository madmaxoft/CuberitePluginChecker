-- ApiLoader.lua

-- Implements the API loader that reads the API description files and injects it into the simulator's sandbox
-- API functions can have special implementations, rather than the default-provided dummy ones.

--[[
API table format, being returned from the loader:
{
	Classes =
	{
		cClass =
		{
			Functions =
			{
				Fn1 =
				{
					{
						Params =
						{
							{ Type = "string" },
							{ Type = "number" },
							{ Type = "cPlugin" },
						},
						Returns =
						{
							{ Type = "bool" }
						},
						Implementation = function (...) ... end,  -- Special implementation, executed within the simulator; first param is the Simulator object
					},
					{
						Params = ...,
						Returns = ...,
						IsStatic = true,
					},
				},  -- Fn1
			},  -- Functions
			Variables =
			{
				Var1 = { Type = "bool" },
			},
			Constants =
			{
				Const1 = { Type = "string" },
			},
		},  -- cClass
	},  -- Classes
	Globals =
	{
		Functions = ...  -- Same as in any cClass
	},
}
--]]





--- Translation from C types to Lua types
-- Dictionary of "CType" -> "LuaType"
local g_CTypeToLuaType =
{
	AString = "string",
	bool = "boolean",
	Byte = "number",
	char = "number",
	double = "number",
	float = "number",
	ForEachChunkProvider = "cWorld",
	int = "number",
	size_t = "number",
	unsigned = "number",
	["const AString"] = "string",
	["const char*"] = "string",
	["std::string"] = "string",
	["Vector3<int>"]    = "Vector3i",
	["Vector3<float>"]  = "Vector3f",
	["Vector3<double>"] = "Vector3d",
}





--- Converts C++ types (AString, int) in a function signature to their Lua counterparts:
-- Modifies a_FnSignature directly
local function convertParamTypes(a_FnSignature)
	-- Convert params:
	a_FnSignature.Params = a_FnSignature.Params or {}
	for _, param in ipairs(a_FnSignature.Params) do
		param.Type = g_CTypeToLuaType[param.Type] or param.Type
	end

	-- Convert returns:
	a_FnSignature.Returns = a_FnSignature.Returns or {}
	for _, ret in ipairs(a_FnSignature.Returns) do
		ret.Type = g_CTypeToLuaType[ret.Type] or ret.Type
	end
end





--- Normalizes the class description for a single class (or globals)
-- Makes sure Functions, Constants and Variables are present
-- Makes sure each function has a multi-signature description format (FnName = { {desc1}, {desc2}, ... })
local function normalizeClass(a_Class)
	assert(a_Class)

	local fns = {}
	for fnName, desc in pairs(a_Class.Functions or {}) do
		if not(desc[1]) then
			convertParamTypes(desc)
			fns[fnName] = {desc}  -- Convert single-signature functions to same format as multi-signature ones
		else
			for _, signature in ipairs(desc) do
				convertParamTypes(signature)
			end
			fns[fnName] = desc
		end
	end
	a_Class.Functions = fns
	a_Class.Constants = a_Class.Constants or {}
	a_Class.Variables = a_Class.Variables or {}
end





--- Returns whether the array-table representing the parameter types matches the function signature
-- a_Signature is the API description's function signature
-- a_ParamTypes is an array-table representation of param types, as parsed from the API implementation files
local function signatureMatchesParams(a_Signature, a_ParamTypes)
	-- Check params:
	assert(type(a_Signature) == "table")
	assert(type(a_Signature.Params) == "table")
	assert(type(a_ParamTypes) == "table")

	-- Check param count first:
	local sParams = a_Signature.Params
	if (#sParams ~= #a_ParamTypes) then
		-- The param count doesn't match
		return false
	end

	-- Check each param type:
	for idx, t in ipairs(a_ParamTypes) do
		if (sParams[idx].Type ~= t) then
			-- Param type doesn't match
			return false
		end
	end

	-- All params have matched
	return true
end





--- Sets the implementation of the specified function into the API description
-- a_Api is the API description into which the implementation is to be set
-- a_FnFullName is a string representation of the function's full name and signature ("cRoot:GetWorld(string)")
-- a_Fn is the function to set as the implementation
-- Raises an error if the function name cannot be resolved or no such API function
local function setApiImplementation(a_Api, a_FnFullName, a_Fn)
	-- Check params:
	assert(type(a_Api) == "table")
	assert(type(a_Api.Classes) == "table")
	assert(type(a_Api.Globals) == "table")

	-- Parse the function name:
	local fnName, functionParamsStr = string.match(a_FnFullName, "([a-zA-Z0-9:]+)(%b())")
	local idxColon = string.find(fnName, ":")
	local className, functionName
	if (idxColon) then
		className = string.sub(fnName, 1, idxColon - 1)
		functionName = string.sub(fnName, idxColon + 1)
	else
		functionName = fnName
	end
	--[[
	local className, functionName = string.match(fnName, "([a-zA-Z0-9]+):?([a-zA-Z0-9]+)")
	-- local className, functionName = string.match(fnName, "(%a+):?(%a+)")
	if (functionName == "") then
		functionName, className = className, nil
	end
	--]]
	local functionParams = {}
	string.gsub(functionParamsStr, "[^,]+",
		function (a_Match)
			local param = string.gsub(a_Match, "[()]", "")  -- Remove the parentheses
			param = param:match("^%s*(.-)%s*$")  -- Trim the whitespace
			if (param and (param ~= "")) then
				table.insert(functionParams, param)
			end
		end
	)  -- Parse param types into an array

	-- Find the API description for the function
	local apiFnDesc
	if (className) then
		apiFnDesc = ((a_Api.Classes[className] or {}).Functions or {})[functionName]
	else
		apiFnDesc = a_Api.Globals.Functions[functionName]
	end
	if not(apiFnDesc) then
		error(string.format("Cannot add custom implementation for function \"%s\", it is not present in the API",
			a_FnFullName
		))
	end

	-- Find the right signature for the function:
	for _, signature in ipairs(apiFnDesc) do
		if (signatureMatchesParams(signature, functionParams)) then
			signature.Implementation = a_Fn
			return
		end
	end
	error(string.format("Cannot add custom implementation for function \"%s\", such a parameter combination is not present in the API",
		a_FnFullName
	))
end





--- Loads the custom implementations for API functions from the files specified in options
-- a_Options is the global options object
-- a_Api is the destination table where the API implementations will get stored
local function loadApiImplementations(a_Options, a_Api)
	-- Check params:
	assert(type(a_Options) == "table")
	assert(type(a_Api) == "table")
	assert(type(a_Api.Classes) == "table")
	assert(type(a_Api.Globals) == "table")

	-- Load all files specified in options:
	for _, fnam in ipairs(a_Options.apiImplementationFiles) do
		print(string.format("Loading API implementation file \"%s\".", fnam))
		local f = assert(loadfile(fnam))
		local impl = f()
		assert(type(impl) == "table", "API Implementation must return a dictionary-table")
		for k, v in pairs(impl) do
			if (type(v) == "function") then
				setApiImplementation(a_Api, k, v)
			end
		end
	end
end





--- Loads the API in the format generated by Cuberite's src/Bindings/GenerateBindings.lua script
-- a_Options is the global options object
-- a_Api is the destination table where the API description will get stored
-- The loader assumes that each class API is defined in no more than one file.
local function loadAutoApi(a_Options, a_Api)
	-- Check params:
	assert(type(a_Options) == "table")
	assert(type(a_Api) == "table")
	assert(type(a_Api.Classes) == "table")
	assert(type(a_Api.Globals) == "table")

	-- Use defaults, if optioins not given:
	local apiPath = a_Options.autoApiDescPath
	if not(apiPath) then
		print("Path to automatic API not given, using the default of \"AutoAPI\".")
		print("Note that you should obtain the automatic API from Cuberite by running its src/Bindings/GenerateBindings.lua file.")
		print("You can use the -a <path> option to specify the path to the API files.")
		apiPath = "AutoAPI"
	end

	-- Read the list of API files:
	print(string.format("Loading AutoAPI from path %s", apiPath))
	local fileListFNam = apiPath .. "/_files.lua"
	local isSuccess, fileList = pcall(dofile, fileListFNam)
	if not(isSuccess) then
		error(string.format("Failed to load the AutoAPI filelist from file %s: %s",
			fileListFNam, tostring(fileList)
		))
	end

	-- Read each API file:
	for _, fnam in ipairs(fileList) do
		local apiFileName = apiPath .. "/" .. fnam
		local f, msg = loadfile(apiFileName)
		if not(f) then
			error(string.format(
				"Error loading the AutoAPI description file %s: %s",
				apiFileName, msg or "<no message>"
			))
		end
		local partialApi = assert(f(), string.format("Failed to load API description from file %s", apiFileName))

		-- Copy the partial API into the main API table:
		for k, v in pairs(partialApi) do
			if (k == "Globals") then
				a_Api.Globals = v
			else
				a_Api.Classes[k] = v
			end
		end
	end
end





--- Copies the API descriptions from a_Src to a_Dest, while preserving the a_Dest's descriptions
-- a_Dest is a single class API description (or Globals)
-- a_Src is a single class API description (or Globals)
local function mergeApi(a_Dest, a_Src)
	-- Check params:
	assert(type(a_Dest) == "table")
	assert(type(a_Src) == "table")

	-- Copy functions. Preserve individual signatures:
	a_Dest.Functions = a_Dest.Functions or {}
	for fnName, fnDesc in pairs(a_Src.Functions or {}) do
		if not(a_Dest.Functions[fnName]) then
			-- The entire function is not in a_Dest, copy the whole thing:
			a_Dest.Functions[fnName] = fnDesc
		else
			-- The function is already in a_Dest, copy each signature separately:
			local dst = a_Dest.Functions[fnName]
			for _, signature in ipairs(fnDesc) do
				table.insert(dst, signature)
			end
		end
	end

	-- Copy constants:
	a_Dest.Constants = a_Dest.Constants or {}
	for cnName, cnDesc in pairs(a_Src.Constants or {}) do
		a_Dest.Constants[cnName] = cnDesc
	end

	-- Copy variables:
	a_Dest.Variables = a_Dest.Variables or {}
	for varName, varDesc in pairs(a_Src.Variables or {}) do
		a_Dest.Variables[varName] = varDesc
	end
end





--- Loads extra API description files (specified in the a_Options)
-- a_Options is the global options object
-- a_Api is the destination table where the API will get stored
-- The extra API descriptions contain classes that may already be present in the main API, and extends those with more symbols
-- Therefore this function must not overwrite the main API's classes, but rather merge in the new symbols
local function loadExtraApi(a_Options, a_Api)
	-- Check params:
	assert(type(a_Options) == "table")
	assert(type(a_Api) == "table")
	assert(type(a_Api.Classes) == "table")
	assert(type(a_Api.Globals) == "table")

	-- Load each specified file:
	for _, fnam in ipairs(a_Options.extraApiFiles) do
		print(string.format("Loading ExtraAPI file \"%s\".", fnam))
		local f, msg = loadfile(fnam)
		if not(f) then
			error(string.format(
				"Error loading the extra API description file %s: %s",
				fnam, msg or "<no message>"
			))
		end
		local partialApi = assert(f(), string.format("Failed to load extra API description from file %s", fnam))

		-- Merge the partial API description into the main API table:
		for className, classApi in pairs(partialApi.Classes or {}) do
			local dst = a_Api.Classes[className]
			if not(dst) then
				-- The class is not in the main API at all, just copy the whole thing:
				a_Api.Classes[className] = classApi
			else
				-- The class is already present, merge in the new symbols:
				mergeApi(dst, classApi)
			end
		end
		if (partialApi.Globals) then
			mergeApi(a_Api.Globals, partialApi.Globals)
		end
	end
end





--- Loads the API description files, based on the commandline options
-- a_Options is the Options object that can be queried for global options
-- Returns the complete API description table
local function loadApi(a_Options)
	-- Check params
	assert(type(a_Options) == "table")

	-- Load the API from files:
	local api =
	{
		Classes = {},
		Globals = {},
	}
	loadAutoApi(a_Options, api)
	loadExtraApi(a_Options, api)

	-- Make sure each class has a properly formatted Functions, Constants and Variables members:
	for k, v in pairs(api.Classes) do
		normalizeClass(v)
	end
	normalizeClass(api.Globals)

	-- Load the specific implementations for API functions:
	loadApiImplementations(a_Options, api)

	-- Mark all global functions as global:
	for _, fn in pairs(api.Globals.Functions) do
		for _, signature in ipairs(fn) do
			signature.IsGlobal = true
		end
	end

	return api
end





return
{
	load = loadApi,
}




