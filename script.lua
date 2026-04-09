local conquestModule = {}

local Players = game:GetService("Players")

local eventFolder = workspace:FindFirstChild("Event")
local maps = eventFolder and eventFolder:FindFirstChild("Maps").Conquest:GetChildren() or {} -- all conquest maps

-- match config
local captureRadius = 50 -- how close you need to be to a zone to count
local pointsPerSecond = 1 -- points each owned zone drips per second
local targetScore = 800 -- first to this wins
local matchDuration = 600 -- 10 minutes in seconds
local timeRemaining = matchDuration
local matchActive = false
local ended = false -- separate flag to prevent double-ending
local respawnConnection
local votingConnection

local eventKillConnections = {} -- connections per player for kill tracking
local originalPositions = {} -- where players were before the event (for restoring later)
local teamAssignments = {} -- maps team name -> list of players
local zoneOwners = {} -- tracks which team owns each zone
local teamScores = {}
local availableTeams = {}
local currentMap = nil
local votes = {} -- player -> true/false based on whether they voted in

-- spins up a separate thread per zone so they all run concurrently
function monitorZoneCaptures()
	if currentMap then
		local zonesFolder = currentMap:FindFirstChild("Zones")
		if zonesFolder then
			for _, zone in ipairs(zonesFolder:GetChildren()) do
				task.spawn(checkZoneCapture, zone)
			end
		end
	end
	task.wait(1)
end

-- makes the map visible and solid, skips the zone/team marker parts
function makeMapVisible(map)
	if map then
		for _, object in pairs(map:GetDescendants()) do
			if object:IsA("BasePart") and object.Name ~= "Zone1" and object.Name ~= "Zone2" and object.Name ~= "Zone3" and object.Name ~= "Team1" and object.Name ~= "Team2" and object.Name ~= "Team3" and object.Name ~= "Team4" and object.Name ~= "Marines" then
				object.Transparency = 0
				object.CanCollide = true
				object.CanQuery = true
				object.CastShadow = true
			elseif object:IsA("BillboardGui") then
				object.Enabled  = true
			end
		end
	end
end

-- picks a random map from the conquest folder and shows it
function selectRandomMap()
	if #maps > 0 then
		currentMap = maps[math.random(1, #maps)]
		makeMapVisible(currentMap)
	end
end

function selectMapSpawns()
	local spawnLocations = {}
	if not currentMap then
		return spawnLocations
	end

	local mapSpawns = currentMap:FindFirstChild("Spawns")
	if not mapSpawns then
		return spawnLocations
	end

	local spawnList = mapSpawns:GetChildren()
	if #spawnList == 0 then
		return spawnLocations
	end

	local assignedSpawns = {}

	if #spawnList > 0 then
		local marineSpawn = spawnList[math.random(1, #spawnList)]
		spawnLocations["Marines"] = marineSpawn
		table.insert(assignedSpawns, marineSpawn)
	end

	for _, team in ipairs(availableTeams) do
		local spawnLocation

		-- keep rolling until we get one that isn't already taken
		repeat
			spawnLocation = spawnList[math.random(1, #spawnList)]
		until not table.find(assignedSpawns, spawnLocation)

		spawnLocations[team] = spawnLocation
		table.insert(assignedSpawns, spawnLocation)
	end

	return spawnLocations
end

function assignTeams()

	availableTeams = {"Team1", "Team2", "Team3", "Team4"}
	teamScores = {Marines = 0, Team1 = 0, Team2 = 0, Team3 = 0, Team4 = 0}

	local spawnLocations = selectMapSpawns()

	local marinePlayers = {}
	local regularPlayers = {}

	for player, voted in pairs(votes) do
		if voted then
			local character = player.Character or player.CharacterAdded:Wait()
			if character and character:FindFirstChild("HumanoidRootPart") then
				originalPositions[player] = character.HumanoidRootPart.Position
			end

			local playerFolder = game.ServerScriptService[".PlayerFolders"]:FindFirstChild(player.Name)
			if playerFolder and playerFolder:FindFirstChild("Class") and playerFolder.Class.Value == "Marine" then
				table.insert(marinePlayers, player)
			else
				table.insert(regularPlayers, player)
			end
		end
	end

	for _, player in ipairs(marinePlayers) do
		local character = player.Character or player.CharacterAdded:Wait()
		if character then
			local teamValue = Instance.new("StringValue")
			teamValue.Name = "EventTeam"
			teamValue.Parent = character
			teamValue.Value = "Marines"
		end
	end

	local totalRegularPlayers = #regularPlayers
	local playersPerTeam = math.ceil(totalRegularPlayers / 4) -- evenly distribute across 4 teams
	teamAssignments = {Marines = marinePlayers, Team1 = {}, Team2 = {}, Team3 = {}, Team4 = {}}

	-- round-robin assignment, bumps to next team once current one is full
	local teamIndex = 1
	for _, player in ipairs(regularPlayers) do
		local character = player.Character or player.CharacterAdded:Wait()
		local teamValue = Instance.new("StringValue")
		teamValue.Name = "EventTeam"
		teamValue.Parent = character

		local teamName = availableTeams[teamIndex]
		teamValue.Value = teamName
		table.insert(teamAssignments[teamName], player)

		if #teamAssignments[teamName] >= playersPerTeam then
			teamIndex = teamIndex + 1
			if teamIndex > #availableTeams then teamIndex = 1
			end
		end
	end

	if #marinePlayers > 0 then
		local marineSpawn = spawnLocations["Marines"]
		if marineSpawn then
			for _, player in ipairs(marinePlayers) do
				local character = player.Character or player.CharacterAdded:Wait()
				if character and character:FindFirstChild("HumanoidRootPart") then
					character:MoveTo(marineSpawn.Position)
				end
			end
		end
	end

	for teamName, players in pairs(teamAssignments) do
		if teamName ~= "Marines" then
			for _, player in ipairs(players) do
				local character = player.Character or player.CharacterAdded:Wait()
				if character and character:FindFirstChild("HumanoidRootPart") then
					local spawnLocation = spawnLocations[teamName]
					if spawnLocation then
						character:MoveTo(spawnLocation.Position)
					end
				end
			end
		end
	end

end

-- listens for an "EVENTKILL" tag being added to a character, which is how kills are signaled
function enableEventKillTracking()
	eventKillConnections = {}

	for player, voted in pairs(votes) do
		if voted then
			eventKillConnections[player] = {}

			if player.Character then
				local childConnection = player.Character.ChildAdded:Connect(function(child)
					if child.Name == "EVENTKILL" then
						checkConquestScoring(player)
					end
				end)
				table.insert(eventKillConnections[player], childConnection)
			end

			local charConnection = player.CharacterAdded:Connect(function(character)
				local childConnection = character.ChildAdded:Connect(function(child)
					if child.Name == "EVENTKILL" then
						checkConquestScoring(player)
					end
				end)

				table.insert(eventKillConnections[player], childConnection)
			end)

			table.insert(eventKillConnections[player], charConnection)
		end
	end
end

-- a kill is worth 20 points, cleans up the tag after counting it
function checkConquestScoring(player)
	local character = player.Character
	if character and character:FindFirstChild("EVENTKILL") then
		local teamValue = character:FindFirstChild("EventTeam")
		if teamValue and teamScores[teamValue.Value] then
			teamScores[teamValue.Value] += 20
			checkWinCondition()
			character:FindFirstChild("EVENTKILL"):Destroy()
		end
	end
end

-- sends everyone back to where they were before the event started and tops off their health
function restorePlayerPositions()
	for player, position in pairs(originalPositions) do
		local character = player.Character
		if character and character:FindFirstChild("HumanoidRootPart") then
			character.Humanoid.Health = character.Humanoid.MaxHealth
			character:MoveTo(position)
		end
	end

	originalPositions = {}
end

-- re-applies team assignment on respawn since the old character is gone
function onPlayerRespawn(player)
	if not votes[player] then return end

	task.wait(0.5)
	local character = player.Character or player.CharacterAdded:Wait()

	local teamValue = character:FindFirstChild("EventTeam") or Instance.new("StringValue")
	teamValue.Name = "EventTeam"
	teamValue.Parent = character

	local assignedTeam = nil

	for teamName, teamPlayers in pairs(teamAssignments) do
		if table.find(teamPlayers, player) then
			teamValue.Value = teamName
			assignedTeam = teamName
			break
		end
	end

	local spawnLocations = selectMapSpawns()
	local spawnLocation = spawnLocations[teamValue.Value]
	if spawnLocation and character:FindFirstChild("HumanoidRootPart") then
		character:MoveTo(spawnLocation.Position)
	end

	if assignedTeam then
		for _, teammate in ipairs(teamAssignments[assignedTeam]) do
			updateTeamIndicator(teammate, assignedTeam)
		end
	end

end

function enableRespawnTracking()
	respawnConnection = {}

	for player, voted in pairs(votes) do
		if voted then
			respawnConnection[player] = player.CharacterAdded:Connect(function()
				onPlayerRespawn(player)
			end)
		end
	end

end

function disableVotingTracking()

	for player, connection in pairs(votingConnection) do
		if connection then
			connection:Disconnect()
		end
	end
	votingConnection = {}
end

function enableVotingTracking()
	votingConnection = {}

	for player, voted in pairs(votes) do
		if not voted then
			votingConnection[player] = player.CharacterAdded:Connect(function()
				task.wait(1)

				if not votes[player] then
					game:GetService("ReplicatedStorage").Remotes.Voting:FireClient(player)
				end
			end)
		end
	end
end

function disableRespawnTracking()
	for player, connection in pairs(respawnConnection) do
		if connection then
			connection:Disconnect()
		end
	end

	respawnConnection = {}

end

-- runs the match countdown, fires ui updates to event players every second
function startTimer()
	matchActive = true
	ended = false
	for _, player in pairs(Players:GetPlayers()) do
		local character = player.Character or player.CharacterAdded:Wait()
		if character then
			local teamValue = character:FindFirstChild("EventTeam")
			if teamValue then
				game:GetService("ReplicatedStorage").Remotes.EventGui:FireClient(player,"InitiateUI",teamValue.Value)
			end
		end
	end
	while timeRemaining > 0 and matchActive do
		timeRemaining = timeRemaining - 1

		local eventPlayers = {}
		for _, player in ipairs(game.Players:GetPlayers()) do
			local character = player.Character
			if character and character:FindFirstChild("EventTeam") then
				table.insert(eventPlayers, player)
			end
		end

		for _, eventPlayer in ipairs(eventPlayers) do
			game:GetService("ReplicatedStorage").Remotes.EventGui:FireClient(eventPlayer, "Update", timeRemaining, teamScores)
		end

		task.wait(1)
	end

	if not ended then
		endGame()
	end
end

-- winners get full rewards, losers get half
function distributeRewards(winningTeam)
	for _, player in ipairs(game.Players:GetPlayers()) do
		local character = player.Character
		if character and character:FindFirstChild("EventTeam") then
			local teamName = character.EventTeam.Value
			print("REWARDS DISTRIBUTED")

			local rewards = {
				busoXP = 100,
				kenXP = 150,
				haoXP = 75,
				bounty = 1500,
				beli = math.random(10000,35000)
			}

			-- losers get everything halved
			if teamName ~= winningTeam then
				rewards.busoXP *= 0.5
				rewards.kenXP *= 0.5
				rewards.haoXP *= 0.5
				rewards.bounty *= 0.5
				rewards.beli *= 0.5
			end

			local playerFolder = game.ServerScriptService[".PlayerFolders"]:FindFirstChild(player.Name)

			if playerFolder and playerFolder:FindFirstChild("DetestHaoborn") and playerFolder.DetestHaoborn.Value == "No" then
				rewards.haoXP = nil
			end

			if playerFolder then
				playerFolder.DetestBusoExp.Value += rewards.busoXP
				playerFolder.DetestKenExp.Value += rewards.kenXP
				if playerFolder:FindFirstChild("Class") and playerFolder.Class.Value == "Marine" then
					playerFolder[".Bounty658"].Value -= rewards.bounty
				else
					playerFolder[".Bounty658"].Value += rewards.bounty
				end
				if playerFolder:FindFirstChild("Gold") then
					playerFolder["Gold"].Value += rewards.beli
					if playerFolder.Class.Value == "Pirate" then
						playerFolder["Gold"].Value += (rewards.beli * 0.6)
					end
				end
				if rewards.haoXP then
					playerFolder.DetestHaoExp.Value += rewards.haoXP
				end
			end

			game:GetService("ReplicatedStorage").Remotes.EventGui:FireClient(player, "Rewards", teamName, rewards)
		end
	end
end

-- disconnects all listeners, finds the winner, pays out rewards, hides the map
function endGame()
	matchActive = false
	ended = true
	disableRespawnTracking()

	for player, connections in pairs(eventKillConnections) do
		for _, connection in ipairs(connections) do
			if connection then
				connection:Disconnect()
			end
		end
		eventKillConnections[player] = nil
	end

	eventKillConnections = {}

	-- simple linear scan to find highest scoring team
	local highestScore = 0
	local winningTeam = nil

	for teamName, score in pairs(teamScores) do
		if score > highestScore then
			highestScore = score
			winningTeam = teamName
		end
	end

	if winningTeam then
		distributeRewards(winningTeam)
	end

	for _, player in ipairs(game.Players:GetPlayers()) do
		if player.Character and player.Character:FindFirstChild("EventTeam") then
			game:GetService("ReplicatedStorage").Remotes.EventGui:FireClient(player, "End", winningTeam)
		end
	end

	for _, player in pairs(game.Players:GetPlayers()) do
		if player.Character and player.Character:FindFirstChild("EventTeam") then
			player.Character.EventTeam:Destroy()
		end
	end

	game:GetService("ReplicatedStorage").Remotes.EventGui:FireAllClients("RemoveTeamOutlines")

	restorePlayerPositions()

	for _, v in pairs(workspace.Event:GetDescendants()) do
		if v:IsA("BasePart") then
			v.CanCollide = false
			v.CanQuery = false
			v.Transparency = 1
		elseif v:IsA("BillboardGui") then
			v.Enabled = false
		end
	end
end

-- runs every 0.1s per zone, handles contesting, progress bar, and capture
function checkZoneCapture(zone)
	if not matchActive then return end

	local capturingTeam = nil
	local lastCapturingTeam = nil
	local captureProgress = 0
	local captureNeeded = 5

	while matchActive do
		local players = game.Players:GetPlayers()
		local teamsInZone = {}
		local playersInZone = 0
		local defendingPlayers = 0

		for _, player in ipairs(players) do
			local character = player.Character
			if character and character:FindFirstChild("HumanoidRootPart") and character:FindFirstChild("EventTeam") then
				local distance = (zone.Position - character.HumanoidRootPart.Position).Magnitude
				local teamName = character.EventTeam.Value

				if distance < captureRadius then
					teamsInZone[teamName] = (teamsInZone[teamName] or 0) + 1
					playersInZone = playersInZone + 1

					if zoneOwners[zone] == teamName then
						defendingPlayers += 1
					end
				end
			end
		end

		-- owner is defending alone, bleed the attacker's progress back
		if zoneOwners[zone] and defendingPlayers > 0 and #teamsInZone == 1 and captureProgress > 0 then
			captureProgress = math.max(0, captureProgress - 0.1)
			zone.BarGUI.Frame:TweenSize(UDim2.new(captureProgress / captureNeeded, 0, 1, 0), "Out", "Linear", 0.1, true)
			task.wait(0.1)
			continue
		end

		if playersInZone == 0 then
			task.wait(0.1)
			continue
		end

		local numTeams = 0
		for _ in pairs(teamsInZone) do
			numTeams += 1
		end

		-- contested by multiple teams, nobody makes progress
		if numTeams > 1 then
			task.wait(0.1)
			continue
		else

			capturingTeam = next(teamsInZone)

			-- different team showed up, reset the bar
			if lastCapturingTeam and capturingTeam ~= lastCapturingTeam then
				captureProgress = 0
			end

			lastCapturingTeam = capturingTeam
			captureProgress = math.min(captureProgress + 0.1, captureNeeded)

			zone.BarGUI.Frame:TweenSize(UDim2.new(captureProgress / captureNeeded, 0, 1, 0), "Out", "Linear", 0.1, true)

			if captureProgress >= captureNeeded then
				zoneOwners[zone] = capturingTeam
				updateZoneVisuals(zone, capturingTeam)

				captureProgress = 0
				zone.BarGUI.Frame:TweenSize(UDim2.new(0, 0, 1, 0), "Out", "Linear", 0.1, true)

				task.wait(0.1)
				continue
			end
		end

		task.wait(0.1)
	end

end

function updateTeamIndicator(player,team)
	game:GetService("ReplicatedStorage").Remotes.EventGui:FireClient(player,"ApplyTeamOutlines",team)
end

function updateZoneVisuals(zone, teamName)

	zone.OwnedGUI.TextLabel.Text = "Owned by: "..teamName
	if zone.OwnedGUI.Enabled == false then
		zone.OwnedGUI.Enabled = true
	end
end

-- every second, each owned zone ticks +1 point for its owner
function awardPoints()
	while matchActive do
		for zone, owner in pairs(zoneOwners) do
			if owner then
				teamScores[owner] = (teamScores[owner] or 0) + pointsPerSecond
				checkWinCondition(owner)
			end
		end
		task.wait(1)
	end
end

-- ends the match the moment any team hits 800 points
function checkWinCondition(teamName)
	if teamScores[teamName] >= targetScore then
		if not ended then
			endGame()
		end
	end
end

-- called externally with the voting results before starting
function conquestModule.receiveVotes(voteData)
	votes = voteData
end

-- resets state, picks a map, builds teams, thenstarts all concurrent loops
function conquestModule.startEvent()

	zoneOwners = {}
	teamScores = {}
	timeRemaining = matchDuration
	matchActive = true

	selectRandomMap()
	assignTeams()

	for _, player in pairs(Players:GetPlayers()) do
		local character = player.Character or player.CharacterAdded:Wait()
		if character then
			local teamValue = character:FindFirstChild("EventTeam")
			if teamValue then
				updateTeamIndicator(player, teamValue.Value)
			end
		end
	end

	enableEventKillTracking()
	enableRespawnTracking()

	task.spawn(startTimer)
	task.spawn(awardPoints)
	task.spawn(monitorZoneCaptures)
end

return conquestModule
