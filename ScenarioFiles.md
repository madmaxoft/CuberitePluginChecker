# Scenario files
A scenario file describes a single configuration on which a plugin is tested, together with the actual steps for testing. Usually, a scenario file specifies what worlds the simulator should create, whether to redirect any files that the plugins read / write, when exactly to load and initialize the plugin, player connections that should be simulated etc.

The Checker can execute one scenario file per session. It is of course possible to have multiple scenario files and execute the Checker multiple times, once for each scenario. You can specify the scenario file to execute using the `-s <filename>` parameter of the Checker.

# Syntax
A scenario file is a regular Lua source file. At the top level, it contains a call to the `scenario` function, taking as a parameter a table containing the scenario definition. The definition itself is an array-table of steps that the Checker executes one after another. Each step is a function call, with potential table of parameters again:
```lua
scenario
{
	redirect
	{
		["filename1"] = "different/path/filename1",
	},
	world
	{
		name = "worldName",
	},
	initializePlugin(),
	playerConnect
	{
		name = "playerName",
	},
	...
}
```
Optionally, the scenario description can contain named members (such as `name = "some scenario"`), currently the Checker ignores these completely.

Note that the scenario needs to explicitly specify when to load / initialize the plugin. This is needed because for example file redirection usually needs to take place before the plugin initialization.

# Available actions
The following actions can be used in a scenario:

## redirect
Adds redirection for files and folders. Any Cuberite API that takes a file or folder first checks if there's any redirection for the path. If the beginning of a path to be used matches any of the redirects given, the appropriate part of the path will be replaced. For example, consider a redirect of `["a/b/"] = "c/d/"`, the following table sums up the redirection performed:

Path used by plugin | Path actually used | Notes
--------------------|--------------------|------
z.txt               | z.txt              | Partial matches are ignored
a/b.txt             | a/b.txt            | Not matching the full redirect path
a/b/z.txt           | c/d/z.txt          | Redirect performed
c/a/b/z.txt         | c/a/b/z.txt        | Not matching the *beginning* of the path
c/../a/b/z.txt      | c/d/z.txt          | Redirect takes into account relative paths
c/d/../a/b/z.txt    | c/a/b/z.txt        | Relative path collapsed, but not matching the *beginning* of the path

Takes a dictionary table which maps old paths to new paths as its parameter. Note that paths always use a slash, even on Windows! Also note that most paths cannot be used in the simple Lua table key format, but will need to use the brackets instead:
```lua
{
	some/path = "another/path",  -- Lua syntax error
	["some/path"] = "another/path",  -- correct
}
```

## world
Adds a new world. Usually used before plugin initialization to set up the worlds, but can also be used later. It triggers the `HOOK_WORLD_STARTED` hook properly. If a world of the specified name already exists, the Checker aborts with an error.

Takes a dictionary table as its parameter. The table must contain at least the `name` member, specifying the world name. Any other value is currently ignored but the assumption is to make the worlds more configurable by taking more values into account - the `dimension`, `defaultGameMode` etc.

## loadPluginFiles
Loads the plugin files and executes the globals in them (but doesn't initialize the plugin yet). Usually not needed separately, use the `initializePlugin` instead.

Note that if neither `loadPluginFiles` nor `initializePlugin` are present in the scenario, the Checker will abort with an error message - there's nothing to test.

## initializePlugin
If the plugin files haven't been loaded, loads all of them, and executes their globals. Then calls the plugin's `Initialize` function.

Note that if this action is missing from the scenario, the Checker will emit a warning. It will still execute the scenario, but with the plugin not initialized, only the globals can be tested.

## connectPlayer
Simulates a player connecting to the server. All the hooks are called and their return values are respected.

Takes a dictionary table as its parameter, describing the player that connects. It must have at least the `name` value specifying the player's name. Optionally, the `worldName` value specifies the world in which the player is spawned. Although currently unused, it is expected that other values such as `ip` and `gamemode` will be implemented.

## playerCommand
Simulates a player executing an in-game command. The `HOOK_EXECUTE_COMMAND` hook is fired and its return value is respected. Then the command handler is invoked.

Takes a dictionary table as its parameter. The `playerName` value specifies the player to impersonate for this command. The `command` value specifies the entire command to execute.

If, at the time the action is executed, the specified player is not connected, the Checker aborts with an error message.

## fuzzAllCommands
Simulates a player executing each and every command with combinations of command parameters. It takes an array of strings and builds commands with parameters picked from this array, and a minimum / maximum number of parameters; then it executes each command with all combinations of parameters from the array between the max and min. For example, given the array `{"a", "b"}`, maximum length of 3 and minimum length of 0, it tests each command with the following parameters:
```
<none>
a
b
a a
a b
b a
b b
a a a
a a b
a b a
a b b
b a a
b a b
b b a
b b b
```

Takes a dictionary table as its parameter. The `playerName` value specifies the player to impersonate for the commands. The `choices` specifies an array of strings that are used for the parameters. The 'maxLen' specifies the maximum number of parameters, the optional `minLen` (default: 0) specifies the minimum number of parameters. 

If, at the time the action is executed, the specified player is not connected, the Checker aborts with an error message.