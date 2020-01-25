local _, ajdkp = ...

ajdkp.CONSTANTS = {};
ajdkp.CONSTANTS.AUCTION_DURATION = 50; -- this is the real auction duration, but clients see the auction as ending 10 seconds early
ajdkp.CONSTANTS.MINIMUM_BID = 10;
-- bid priorities
ajdkp.CONSTANTS.MS_OVER_OS = 1;
ajdkp.CONSTANTS.TWO_TO_ONE = 2;
ajdkp.CONSTANTS.PRIORITY_TYPE = ajdkp.CONSTANTS.MS_OVER_OS;
-- Specs
ajdkp.CONSTANTS.MS = 1;
ajdkp.CONSTANTS.OS = 2;
-- Auction states
ajdkp.CONSTANTS.ACCEPTING_BIDS = 1;
ajdkp.CONSTANTS.READY_TO_RESOLVE = 2;
ajdkp.CONSTANTS.COMPLETE = 3;
ajdkp.CONSTANTS.CANCELED = 4;

-- keys are auction ids
-- values are
-- {
--   state: 1|2|3, -- auction states are listed above
--   item_link: "...", -- printable link to the item being auctioned
--   remaining_time: 123, -- number of seconds remaining in the auction (may include partial seconds, bidders see this number - 10)
--   responded: {}, -- keys are character names, values are whether that character has bid or passed
--   bids: {}, -- bids are (spec, amount, character) sorted
-- }
ajdkp.AUCTIONS = {};

local NEXT_AUCTION_ID = 0;

local function StartAuction(item_link)
    local auction_id = NEXT_AUCTION_ID;
    NEXT_AUCTION_ID = NEXT_AUCTION_ID + 1;

    local auction = {
        state=ajdkp.CONSTANTS.ACCEPTING_BIDS,
        item_link=item_link,
        remaining_time=ajdkp.CONSTANTS.AUCTION_DURATION,
        responded=ajdkp.GetRaidMembers(),
        bids={},
    };
    ajdkp.AUCTIONS[auction_id] = auction;

    ajdkp.CreateMLFrame(auction_id, item_link);

    ajdkp.SendStartAuction(auction_id, item_link);
    local name, _ = UnitName("player");
    ajdkp.HandleStartAuction(auction_id, item_link, name);
end

local function ReadyToResolve(auction_id)
    local auction = ajdkp.AUCTIONS[auction_id];
    if auction.remaining_time <= 0 then
        return true
    end
    for _, ready in ipairs(auction.responded) do
        if not ready then
            return false
        end
    end
    return true
end

function ajdkp.DeclareWinner(auction_id)
    local auction = ajdkp.AUCTIONS[auction_id];
    local spec, amt, character = unpack(ajdkp.DetermineWinner(auction_id));
    if spec == ajdkp.CONSTANTS.MS then
        spec = "MS"
    elseif spec == ajdkp.CONSTANTS.OS then
        spec = "OS"
    end
    if character then
        SendChatMessage(string.format("%s wins %s for %d dkp (%s)", character, auction.item_link, amt, spec) ,"RAID");
        SOTA_Call_SubtractPlayerDKP(character, amt);
        ajdkp.AUCTIONS[auction_id].state = ajdkp.CONSTANTS.COMPLETE;
        _G[string.format("MLFrame%dDeclareWinnerButton", auction_id)]:SetText(string.format("%s wins!", character));
        local ml_frame = _G[string.format("MLFrame%d", auction_id)];
        ajdkp.GetCloseButton(ml_frame):SetScript("OnClick", function() ml_frame:Hide() end)
    end
end

-- returns (spec, amt, character)
function ajdkp.DetermineWinner(auction_id)
    -- bids are inserted in sorted order so we really just have to look for cases with fewer than 2 bids and ties
    local auction = ajdkp.AUCTIONS[auction_id];
    if #auction.bids == 0 then
        return {nil, nil, nil}
    elseif #auction.bids == 1 then
        local spec, _, character = unpack(auction.bids[1]);
        return {spec, ajdkp.CONSTANTS.MINIMUM_BID, character}
    else
        if ajdkp.CONSTANTS.PRIORITY_TYPE == ajdkp.CONSTANTS.MS_OVER_OS then
            local first_spec, first_amt, first_character = unpack(auction.bids[1]);
            local second_spec, second_amt, _ = unpack(auction.bids[2]);
            if not first_spec == second_spec then
                -- MS trumps OS so first bidder wins for the minimum
                return {first_spec, ajdkp.CONSTANTS.MINIMUM_BID, first_character }
            elseif not first_amt == second_amt then
                -- specs are the same, but bid amounts are different so give it to the highest bidder
                return {first_spec, second_amt, first_character }
            else
                -- a tie (possibly with more than 2 top bidders)
                local tied_bids = {};
                for _, bid in ipairs(auction.bids) do
                    local spec, amt, character = unpack(bid);
                    if spec == first_spec and amt == first_amt then
                        table.insert(tied_bids, bid);
                    else
                        break
                    end
                end
                -- pick a winner at random among the tied bidders
                return tied_bids[math.random(#tied_bids)]
            end
        elseif ajdkp.CONSTANTS.PRIORITY_TYPE == ajdkp.CONSTANTS.TWO_TO_ONE then
            local first_bid_weight = ajdkp.BidWeight(auction.bids[1]);
            local second_bid_weight = ajdkp.BidWeight(auction.bids[2]);
            if not first_bid_weight == second_bid_weight then
                -- single highest bid weight wins; pays second bid amount reweighted to highest bidder's spec
                -- examples
                --   1, 100, a
                --   2, 150, b
                -- a wins with a bid weight of 100 against b's 75, pays 150 / 2 * 1 = 75 dkp
                --   2, 200, a
                --   1, 80, b
                -- a wins with a bid weight of 100 against b's 80, pays 80 / 1 * 2 = 160 dkp
                local first_spec, _, first_character = unpack(auction.bids[1]);
                local second_spec, second_amt, _ = unpack(auction.bids[2]);
                -- because the bid weight of the second place bidder could be a fraction (e.g. {2, 5, a} for a weight of 2.5)
                -- and because we can only charge whole numebrs of dkp, we round the price. We always round up because
                -- rounding down would put the price below the second bidder's bid weight instead of equal or greater
                local price = math.ceil(second_amt / second_spec * first_spec);
                return {first_spec, price, first_character }
            else
                -- a tie (possibly with more than 2 top bidders)
                local tied_bids = {};
                for _, bid in ipairs(auction.bids) do
                    local bid_weight = ajdkp.BidWeight(bid);
                    if bid_weight == first_bid_weight then
                        table.insert(tied_bids, bid);
                    else
                        break
                    end
                end
                return tied_bids[math.random(#tied_bids)];
            end
        else
            -- TODO: some kind of error
        end
    end
end

function ajdkp.RejectBid(auction_id, character)
    local auction = ajdkp.AUCTIONS[auction_id];
    if auction.state == ajdkp.CONSTANTS.ACCEPTING_BIDS or auction.state == ajdkp.CONSTANTS.READY_TO_RESOLVE then
        auction.responded[character] = false;
        auction.state = ajdkp.CONSTANTS.ACCEPTING_BIDS;
        for i, bid in ipairs(auction.bids) do
            local _, _, bidder = unpack(bid);
            if bidder == character then
                table.remove(auction.bids, i);
            end
        end
        ajdkp.SendRejectBid(auction_id, character);
        ajdkp.SendResumeAuction(auction_id, auction.item_link, auction.remaining_time, character);
    end
end

function ajdkp.CancelAuction(auction_id)
    ajdkp.AUCTIONS[auction_id].state = ajdkp.CONSTANTS.CANCELED;
    ajdkp.SendCancelAuction(auction_id);
end

-- Messages
-- START_AUCTION (00)
--     sent by ML to RAID
--     contains (auction id, item link)
--     triggers clients to show bid window
-- RESUME_AUCTION (01)
--     sent by ML in WHISPER to bidder
--     contains (auction id, remaining time, item link)
--     triggers one client to show bid window
-- PLACE_BID (02)
--     sent by bidder in WHISPER to ML
--     contains (auction id, spec/coefficient (1/2), bid amount)
--     trigger ML client to add bid to list
-- REJECT_BID (03)
--     sent by ML in WHISPER to bidder
--     contains auction id
--     triggers client to print "your bid has been rejected by the masterlooter"
--     immediately followed by a RESUME_AUCTION for the same item so the user can rebid if appropriate
-- CANCEL_AUCTION (04)
--     sent by ML in RAID
--     contains auction id
--     triggers clients to print "auction for {} has been canceled by masterlooter" and hide open bid windows
-- CHECK_AUCTIONS (05)
--     sent by bidder in RAID
--     empty
--     triggers ML client to respond with RESUME_AUCTION for any open auctions in which the sender hasn't already bid
-- PASS (06)
--     sent by bidder in WHISPER to ML
--     contains auction id
--     triggers ML client to mark bidder as ready

function ajdkp.SendStartAuction(auction_id, item_link)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("00 %d %s", auction_id, item_link), "RAID");
end

function ajdkp.HandleStartAuction(auction_id, item_link, master_looter)
    -- bidders see a 10 second shorter auction than the ML to avoid the ML closing the auction when someone can still see it
    ajdkp.CreateBidFrame(auction_id, item_link, master_looter, ajdkp.CONSTANTS.AUCTION_DURATION - 10);
end

function ajdkp.SendResumeAuction(auction_id, item_link, remaining_time, target)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("01 %d %d %s", auction_id, remaining_time, item_link), "WHISPER", target);
end

function ajdkp.HandleResumeAuction(auction_id, item_link, master_looter, remaining_time)
    ajdkp.CreateBidFrame(auction_id, item_link, master_looter, remaining_time)
end

function ajdkp.SendPlaceBid(auction_id, spec, amt, master_looter)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("02 %d %d %d", auction_id, spec, amt), "WHISPER", master_looter);
end

function ajdkp.HandlePlaceBid(auction_id, spec, amt, character)
    local auction = ajdkp.AUCTIONS[auction_id];
    if auction and auction.state == ajdkp.CONSTANTS.ACCEPTING_BIDS then
        local sort;
        if ajdkp.CONSTANTS.PRIORITY_TYPE == ajdkp.CONSTANTS.MS_OVER_OS then
            sort = ajdkp.MSOverOSSort;
        elseif ajdkp.CONSTANTS.PRIORITY_TYPE == ajdkp.CONSTANTS.TWO_TO_ONE then
            sort = ajdkp.TwoToOneSort;
        else
            -- TODO: some kind of error
        end
        ajdkp.InsertNewBid(auction.bids, {spec, amt, character}, sort);
        auction.responded[character] = true;
        if ReadyToResolve(auction_id) then
            auction.state = ajdkp.CONSTANTS.READY_TO_RESOLVE;
        end
    end
end

function ajdkp.SendRejectBid(auction_id, target)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("03 %d", auction_id), "WHISPER", target);
end

function ajdkp.HandleRejectBid(auction_id)
    print("your bid was rejected by the master looter");
end

function ajdkp.SendCancelAuction(auction_id)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("04 %d", auction_id), "RAID");
    ajdkp.HandleCancelAuction(auction_id);
end

function ajdkp.HandleCancelAuction(auction_id)
    local bid_frame = _G[string.format("BidFrame%d", auction_id)];
    if bid_frame then
        bid_frame:Hide();
    end
end

function ajdkp.SendCheckAuctions()
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("05"), "RAID");
end

function ajdkp.HandleCheckAuctions(target)
    for auction_id, auction in ipairs(ajdkp.AUCTIONS) do
        -- only send ResumeAuction if the user hasn't already bid
        if not auction.responded[target] then
            -- bidders see a 10 second shorter auction than the ML to avoid the ML closing the auction when someone can still see it
            ajdkp.SendResumeAuction(auction_id, auction.item_link, auction.remaining_time - 10, target);
        end
    end
end

function ajdkp.SendPass(auction_id, master_looter)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("06 %d", auction_id), "WHISPER", master_looter);
end

function ajdkp.HandlePass(auction_id, character)
    local auction = ajdkp.AUCTIONS[auction_id];
    if auction and auction.state == ajdkp.CONSTANTS.ACCEPTING_BIDS then
        auction.responded[character] = true;
        if ReadyToResolve(auction_id) then
            auction.state = ajdkp.CONSTANTS.READY_TO_RESOLVE;
        end
    end
end

-- Frame used to receive addon messages
local EVENT_FRAME = CreateFrame("FRAME", nil, UIParent);
EVENT_FRAME:RegisterEvent("CHAT_MSG_ADDON");
C_ChatInfo.RegisterAddonMessagePrefix("AJDKP");
EVENT_FRAME:SetScript("OnEvent", function(self, event, ...)
    local _, message, distribution, sender = ...;
    local msg_type = message:sub(1, 2)
    if msg_type == "00" then
        for auction_id, item_link in string.gmatch(message:sub(4), "(%d+) (.+)") do
            ajdkp.HandleStartAuction(auction_id, item_link, sender);
        end
    elseif msg_type == "01" then
        for auction_id, remaining_time, item_link in string.gmatch(message:sub(4), "(%d+) (%d+) (.+)") do
            ajdkp.HandleResumeAuction(tonumber(auction_id), item_link, sender, tonumber(remaining_time));
        end
    elseif msg_type == "02" then
        for auction_id, spec, amt in string.gmatch(message:sub(4), "(%d+) (%d) (%d+)") do
            ajdkp.HandlePlaceBid(tonumber(auction_id), tonumber(spec), tonumber(amt), ajdkp.StripRealm(sender));
        end
    elseif msg_type == "03" then
        local auction_id = tonumber(message:sub(4));
        ajdkp.HandleRejectBid(auction_id);
    elseif msg_type == "04" then
        local auction_id = tonumber(message:sub(4));
        ajdkp.HandleCancelAuction(auction_id);
    elseif msg_type == "05" then
        ajdkp.HandleCheckAuctions(sender);
    elseif msg_type == "06" then
        local auction_id = tonumber(message:sub(4));
        ajdkp.HandlePass(auction_id, sender);
    end
end);




SLASH_AJDKP1 = "/d"
SlashCmdList["AJDKP"] = function(msg)
    for link in string.gmatch(msg, ".-|h|r") do
        StartAuction(link);
    end
end

-- Send a CheckAuctions message on startup in case there are any running
ajdkp.SendCheckAuctions();


-- TODO: create a frame pool and position the frames based on how many frames are being opened simultaneously
-- TODO: recognize if there are two of the same item being auctioned and show just one window and give them to the two highest
-- TODO: once a winner is determined lock the ML frame (leave the close button but unlink the cancel-auction effect), charge the dkp
-- TODO: move everything into one files and get rid of CONSTANTS
-- TODO: if multiple people start auctions the ids may conflict