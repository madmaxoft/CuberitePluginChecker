-- StoreInCallbackTest.lua

-- Defines the test scenario for the StoreInCallback plugin





scenario
{
	name = "StoreForLater",
	world
	{
		name = "world",
	},
	initializePlugin(),
	connectPlayer
	{
		name = "player1",
		worldName = "world",
	},
	playerCommand
	{
		playerName = "player1",
		command = "test",
	},
}
