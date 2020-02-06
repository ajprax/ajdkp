local _, ajdkp = ...

-- position of the various bid and ml frames saved between sessions. keys are frame names, values are {x, y} for a CENTER anchor to the UIParent
AJDKP_FRAME_POSITIONS = {};

ajdkp.CONSTANTS = {};
ajdkp.CONSTANTS.VERSION = "0.1.0";

ajdkp.CONSTANTS.AUCTION_DURATION = 190; -- this is the real auction duration, but clients see the auction as ending 10 seconds early
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
-- Class colors
ajdkp.CONSTANTS.CLASS_COLORS = { -- CLASS_COLORS[select(3, UnitClass("name"))]
    {0.78, 0.61, 0.43}, -- warrior
    {0.96, 0.55, 0.73}, -- paladin
    {0.67, 0.83, 0.45}, -- hunter
    {1.00, 0.96, 0.41}, -- rogue
    {1.00, 1.00, 1.00}, -- priest
    {0.77, 0.12, 0.23}, -- death knight
    {0.00, 0.44, 0.87}, -- shaman
    {0.41, 0.80, 0.94}, -- mage
    {0.58, 0.51, 0.79}, -- warlock
    {0.33, 0.54, 0.52}, -- monk
    {1.00, 0.49, 0.04}, -- druid
    {0.64, 0.19, 0.79}, -- demon hunter
};

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
-- CONFIRM_BID (07)
--     sent by ML in WHISPER to bidder
--     contains auction id, bid details (spec, amount, item link)
--     triggers bidder client to print "Your bid (amt MS/OS) for [link] was received"
-- GREET (08)
--     sent by everyone in GUILD upon logging in
--     includes addon version
--     triggers recipients to send back their addon version (eventually this will be used to verify everyone has the latest version) and next auction id (one higher than the highest one they've seen)
-- WELCOME (09)
--     sent by everyone in WHISPER to sender of GREET
--     contains addon version and next auction id
--     triggers client to update NEXT_AUCTION_ID and eventually addon version will be used to verify everyone has the latest version

ajdkp.CONSTANTS.START_AUCTION = "00";
ajdkp.CONSTANTS.RESUME_AUCTION = "01";
ajdkp.CONSTANTS.PLACE_BID = "02";
ajdkp.CONSTANTS.REJECT_BID = "03";
ajdkp.CONSTANTS.CANCEL_AUCTION = "04";
ajdkp.CONSTANTS.CHECK_AUCTIONS = "05";
ajdkp.CONSTANTS.PASS = "06";
ajdkp.CONSTANTS.CONFIRM_BID = "07";
ajdkp.CONSTANTS.GREET = "08";
ajdkp.CONSTANTS.WELCOME = "09";

-- keys are auction ids
-- values are
-- {
--   state: 1|2|3, -- auction states are listed above
--   item_link: "...", -- printable link to the item being auctioned
--   remaining_time: 123, -- number of seconds remaining in the auction (may include partial seconds, bidders see this number - 10)
--   outstanding: {}, -- keys are character names, values are whether that character has bid or passed
--   bids: {}, -- bids are (spec, amount, character) sorted
-- }
ajdkp.AUCTIONS = {};

local NEXT_AUCTION_ID = 1;

local function StartAuction(item_link)
    local auction_id = NEXT_AUCTION_ID;
    NEXT_AUCTION_ID = NEXT_AUCTION_ID + 1;

    local auction = {
        state=ajdkp.CONSTANTS.ACCEPTING_BIDS,
        item_link=item_link,
        remaining_time=ajdkp.CONSTANTS.AUCTION_DURATION,
        outstanding=ajdkp.GetRaidMembers(),
        bids={},
    };
    ajdkp.AUCTIONS[auction_id] = auction;

    ajdkp.CreateMLFrame(auction_id, item_link);

    SendChatMessage(string.format("Auction open for %s", auction.item_link) ,"RAID_WARNING");
    ajdkp.SendStartAuction(auction_id, item_link);
end

local function ReadyToResolve(auction_id)
    local auction = ajdkp.AUCTIONS[auction_id];
    if auction.remaining_time <= 0 then
        return true
    end
    return #auction.outstanding == 0
end

function ajdkp.DeclareWinner(auction_id)
    local auction = ajdkp.AUCTIONS[auction_id];
    if ajdkp.AUCTIONS[auction_id].state == ajdkp.CONSTANTS.READY_TO_RESOLVE then
        local spec, amt, character = unpack(ajdkp.DetermineWinner(auction_id));
        -- the final price can never be less than 10
        amt = math.max(amt, 10);
        if spec == ajdkp.CONSTANTS.MS then
            spec = "MS"
        elseif spec == ajdkp.CONSTANTS.OS then
            spec = "OS"
        end
        if character then
            ajdkp.AUCTIONS[auction_id].state = ajdkp.CONSTANTS.COMPLETE;
            SendChatMessage(string.format("%s wins %s for %d dkp (%s)", character, auction.item_link, amt, spec) ,"RAID");
            -- go through all open auctions and make sure the winner of this auction hasn't bid more than their new dkp
            -- if they have, lower their bid to their new dkp (we presume they'd still be willing to bid that much since
            -- it's less than they've previously said they were willing to pay)
            local winners_new_dkp = ajdkp.GetDKP(character) - amt;
            for _, auction in ipairs(ajdkp.AUCTIONS) do
                if auction.state == ajdkp.CONSTANTS.ACCEPTING_BIDS or auction.state == ajdkp.CONSTANTS.READY_TO_RESOLVE then
                    for i, bid in ipairs(auction.bids) do
                        local bid_spec, bid_amt, bid_character = unpack(bid);
                        if bid_character == character and bid_amt > winners_new_dkp then
                            -- remove the bid and re-insert with the new dkp amount so it's sorted correctly
                            table.remove(auction.bids, i);
                            ajdkp.InsertNewBid(auction.bids, {bid_spec, winners_new_dkp, bid_character});
                            break
                        end
                    end
                end
            end
            SOTA_Call_SubtractPlayerDKP(character, amt);
            _G[string.format("MLFrame%dDeclareWinnerButton", auction_id)]:SetText(string.format("%s wins!", character));
            local ml_frame = _G[string.format("MLFrame%d", auction_id)];
            ajdkp.GetCloseButton(ml_frame):SetScript("OnClick", function() ml_frame:Hide() end)
        end
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
            if not (first_spec == second_spec) then
                -- MS trumps OS so first bidder wins for the minimum
                return {first_spec, ajdkp.CONSTANTS.MINIMUM_BID, first_character }
            elseif not (first_amt == second_amt) then
                -- specs are the same, but bid amounts are different so give it to the highest bidder for the second
                -- highest bid + 1 to avoid the appearance of a tie
                return {first_spec, second_amt + 1, first_character }
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
            if not (first_bid_weight == second_bid_weight) then
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
                local unrounded = second_amt / second_spec * first_spec;
                local price = math.ceil(unrounded);
                if price == unrounded then
                    -- rounding had no effect, so add one to the price to avoid the appearance of a tie
                    price = price + 1;
                end
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
        table.insert(auction.outstanding, character);
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
    local auction = ajdkp.AUCTIONS[auction_id];
    auction.state = ajdkp.CONSTANTS.CANCELED;
    SendChatMessage(string.format("Auction canceled for %s", auction.item_link), "RAID");
    ajdkp.SendCancelAuction(auction_id);
    ajdkp.HandleCancelAuction(auction_id);
end

--------------
-- MESSAGES --
--------------

function ajdkp.SendStartAuction(auction_id, item_link)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %d %s", ajdkp.CONSTANTS.START_AUCTION, auction_id, item_link), "RAID");
end

function ajdkp.HandleStartAuction(auction_id, item_link, master_looter)
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, auction_id);
    -- bidders see a 10 second shorter auction than the ML to avoid the ML closing the auction when someone can still see it
    ajdkp.CreateBidFrame(auction_id, item_link, master_looter, ajdkp.CONSTANTS.AUCTION_DURATION - 10);
end

function ajdkp.SendResumeAuction(auction_id, item_link, remaining_time, target)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %d %d %s", ajdkp.CONSTANTS.RESUME_AUCTION, auction_id, remaining_time, item_link), "WHISPER", target);
end

function ajdkp.HandleResumeAuction(auction_id, item_link, master_looter, remaining_time)
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, auction_id);
    ajdkp.CreateBidFrame(auction_id, item_link, master_looter, remaining_time)
end

function ajdkp.SendPlaceBid(auction_id, spec, amt, master_looter)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %d %d %d", ajdkp.CONSTANTS.PLACE_BID, auction_id, spec, amt), "WHISPER", master_looter);
end

function ajdkp.HandlePlaceBid(auction_id, spec, amt, character)
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, auction_id);
    local auction = ajdkp.AUCTIONS[auction_id];
    if auction and auction.state == ajdkp.CONSTANTS.ACCEPTING_BIDS then
        ajdkp.InsertNewBid(auction.bids, {spec, amt, character});
        ajdkp.Remove(auction.outstanding, character);
        ajdkp.SendConfirmBid(spec, amt, auction.item_link, character);
        if ReadyToResolve(auction_id) then
            auction.state = ajdkp.CONSTANTS.READY_TO_RESOLVE;
        end
    end
end

function ajdkp.SendRejectBid(auction_id, target)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %d", ajdkp.CONSTANTS.REJECT_BID, auction_id), "WHISPER", target);
end

function ajdkp.HandleRejectBid(auction_id)
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, auction_id);
    print("your bid was rejected by the master looter");
end

function ajdkp.SendCancelAuction(auction_id)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %d", ajdkp.CONSTANTS.CANCEL_AUCTION, auction_id), "RAID");
end

function ajdkp.HandleCancelAuction(auction_id)
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, auction_id);
    local bid_frame = _G[string.format("BidFrame%d", auction_id)];
    if bid_frame then
        bid_frame:Hide();
    end
end

function ajdkp.SendCheckAuctions()
    -- Sometimes we want to send a check auctions message before we're allowed to when loading. this will retry every
    -- second until it works without blocking other code
    -- TODO: maybe this should have a limited number of retries. if you log in while not in a party this will run indefinitely
    if not C_ChatInfo.SendAddonMessage("AJDKP", ajdkp.CONSTANTS.CHECK_AUCTIONS, "RAID") then
        C_Timer.After(1, ajdkp.SendCheckAuctions);
    end
end

function ajdkp.HandleCheckAuctions(target)
    for auction_id=1,NEXT_AUCTION_ID do
        local auction = ajdkp.AUCTIONS[auction_id];
        -- only send ResumeAuction if the user hasn't already bid
        if auction and auction.state == ajdkp.CONSTANTS.ACCEPTING_BIDS and ajdkp.Contains(auction.outstanding, ajdkp.StripRealm(target)) then
            -- bidders see a 10 second shorter auction than the ML to avoid the ML closing the auction when someone can still see it
            ajdkp.SendResumeAuction(auction_id, auction.item_link, auction.remaining_time - 10, target);
        end
    end
end

function ajdkp.SendPass(auction_id, master_looter)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %d", ajdkp.CONSTANTS.PASS, auction_id), "WHISPER", master_looter);
end

function ajdkp.HandlePass(auction_id, character)
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, auction_id);
    local auction = ajdkp.AUCTIONS[auction_id];
    if auction and auction.state == ajdkp.CONSTANTS.ACCEPTING_BIDS then
        ajdkp.Remove(auction.outstanding, character);
        if ReadyToResolve(auction_id) then
            auction.state = ajdkp.CONSTANTS.READY_TO_RESOLVE;
        end
    end
end

function ajdkp.SendConfirmBid(spec, amt, item_link, bidder)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %d %d %s", ajdkp.CONSTANTS.CONFIRM_BID, spec, amt, item_link), "WHISPER", bidder);
end

function ajdkp.HandleConfirmBid(spec, amt, item_link)
    if spec == ajdkp.CONSTANTS.MS then
        spec = "MS"
    elseif spec == ajdkp.CONSTANTS.OS then
        spec = "OS"
    end
    print(string.format("Your bid (%d %s) for %s was received", amt, spec, item_link));
end

function ajdkp.SendGreet()
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %s", ajdkp.CONSTANTS.GREET, ajdkp.CONSTANTS.VERSION), "GUILD");
end

function ajdkp.HandleGreet(target, version)
    -- version is ignored for now
    ajdkp.SendWelcome(target);
end

function ajdkp.SendWelcome(target)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %d %s", ajdkp.CONSTANTS.WELCOME, NEXT_AUCTION_ID, ajdkp.CONSTANTS.VERSION), "WHISPER", target);
end

function ajdkp.HandleWelcome(next_auciton_id, version)
    -- version is ignored for now
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, next_auciton_id);
end


-- Frame used to receive addon messages
local EVENT_FRAME = CreateFrame("FRAME", nil, UIParent);
EVENT_FRAME:RegisterEvent("CHAT_MSG_ADDON");
EVENT_FRAME:RegisterEvent("PLAYER_LOGIN");
C_ChatInfo.RegisterAddonMessagePrefix("AJDKP");
EVENT_FRAME:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        ajdkp.SendCheckAuctions();
        ajdkp.SendGreet();
        return
    end
    local prefix, message, distribution, sender = ...;
    if prefix and string.upper(prefix) == "AJDKP" and event == "CHAT_MSG_ADDON" then
        local msg_type = message:sub(1, 2)
        if msg_type == ajdkp.CONSTANTS.START_AUCTION then
            for auction_id, item_link in string.gmatch(message:sub(4), "(%d+) (.+)") do
                ajdkp.HandleStartAuction(auction_id, item_link, sender);
            end
        elseif msg_type == ajdkp.CONSTANTS.RESUME_AUCTION then
            for auction_id, remaining_time, item_link in string.gmatch(message:sub(4), "(%d+) (%d+) (.+)") do
                ajdkp.HandleResumeAuction(tonumber(auction_id), item_link, sender, tonumber(remaining_time));
            end
        elseif msg_type == ajdkp.CONSTANTS.PLACE_BID then
            for auction_id, spec, amt in string.gmatch(message:sub(4), "(%d+) (%d) (%d+)") do
                ajdkp.HandlePlaceBid(tonumber(auction_id), tonumber(spec), tonumber(amt), ajdkp.StripRealm(sender));
            end
        elseif msg_type == ajdkp.CONSTANTS.REJECT_BID then
            local auction_id = tonumber(message:sub(4));
            ajdkp.HandleRejectBid(auction_id);
        elseif msg_type == ajdkp.CONSTANTS.CANCEL_AUCTION then
            local auction_id = tonumber(message:sub(4));
            ajdkp.HandleCancelAuction(auction_id);
        elseif msg_type == ajdkp.CONSTANTS.CHECK_AUCTIONS then
            ajdkp.HandleCheckAuctions(sender);
        elseif msg_type == ajdkp.CONSTANTS.PASS then
            local auction_id = tonumber(message:sub(4));
            ajdkp.HandlePass(auction_id, ajdkp.StripRealm(sender));
        elseif msg_type == ajdkp.CONSTANTS.CONFIRM_BID then
            for spec, amt, item_link in string.gmatch(message:sub(4), "(%d) (%d+) (.+)") do
                ajdkp.HandleConfirmBid(tonumber(spec), tonumber(amt), item_link);
            end
        elseif msg_type == ajdkp.CONSTANTS.GREET then
            ajdkp.HandleGreet(sender, message:sub(4));
        elseif msg_type == ajdkp.CONSTANTS.WELCOME then
            for next_auction_id, version in string.gmatch(message:sub(4), "(%d) (.*)") do
                ajdkp.HandleWelcome(next_auction_id, version);
            end
        end
    end
end);


SLASH_AJDKP1 = "/auction"
SlashCmdList["AJDKP"] = function(msg)
    for link in string.gmatch(msg, ".-|h|r") do
        StartAuction(link);
    end
end



-- TODO: create a frame pool and position the frames based on how many frames are being opened simultaneously
--       use CreateFramePool to manage the frames.
--       move as much of the layout of the frame as possible into the xml and just modify the values (name, icon, etc)
--       when receiving a frame from the pool, set a field on it for the auction id
--       figure out how to associate real scripts from xml
--       FramePool does name the frames, how do we interact with them, elements can be named in the xml but if what does $parent do if the main frame is nil?

-- TODO: recognize if there are two of the same item being auctioned and show just one window and give them to the two highest
-- TODO: if multiple people start auctions the ids may conflict (this includes someone reloading since it resets their auction id)
-- TODO: disable bidding on items the user can't equip
-- TODO: normalize frame strata
-- TODO: add a tooltip showing who hasn't bid
-- TODO: widen the ML frame slightly
-- TODO: improve anchors/points so the frames are more easily modified
-- TODO: consider a "to-be-distributed" list with "x"s and won auctions go there
-- TODO: send the minimum bid with StartAuction so only the ML needs to update if we change prices
-- TODO: change GET_NEXT_AUCTION_ID to some kind of welcome message including your addon version
--       everyone else responds with their addon version and their next_auction_id
--       this will let us make a display of who in a raid doesn't have the addon and what version everyone's on
-- TODO: allow item comparisons by holding shift