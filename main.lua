local _, ajdkp = ...

-- position of the various bid and ml frames saved between sessions. keys are frame names, values are {x, y} for a CENTER anchor to the UIParent
AJDKP_FRAME_POSITIONS = {};

ajdkp.CONSTANTS = {};
ajdkp.CONSTANTS.VERSION = "0.1.8";

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

------------
-- FRAMES --
------------

-- frame pools
local nextMLFrame = 1;
local AvailableMLFrames = {};
local nextBidFrame = 1;
local AvailableBidFrames = {};

function ajdkp.ColorGradient(p)
    if p >= 1 then
        return 0, 1, 0
    elseif p <= 0 then
        return 1, 0, 0
    end
    return 1- p, p, 0
end

function ajdkp.GetClassColor(character)
    local class_index = select(3, UnitClass(character));
    local r, g, b;
    if class_index and class_index > 0 and class_index <= 12 then
        r, g, b = unpack(ajdkp.CONSTANTS.CLASS_COLORS[class_index]);
    else
        -- show grey if it's not a known class. this should mostly happen if a user leaves the raid before sending a bid
        -- or pass
        r = 0.5; g = 0.5; b = 0.5;
    end
    return {r, g, b}
end

function ajdkp.ColorByClass(player)
    local r, g, b = unpack(ajdkp.GetClassColor(player));
    local hex = string.format("%02x%02x%02x", r*255, g*255, b*255);
    return string.format("|cFF%s%s|r", hex, player);
end

function ajdkp.GetCloseButton(frame)
    local kids = { frame:GetChildren() };
    for _, child in ipairs(kids) do
        return child
    end
end

function ajdkp.SetIconMouseover(frame)
    frame.Icon:SetScript("OnEnter", function()
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE");
        GameTooltip:SetPoint("BOTTOMRIGHT", frame.Icon, "TOPLEFT");
        GameTooltip:SetHyperlink(frame.item_link or ajdkp.AUCTIONS[frame.auction_id].item_link);
        GameTooltip_ShowCompareItem();
    end);
    frame.Icon:SetScript("OnLeave", function()
        GameTooltip:Hide();
    end);
end

function ajdkp.SetOutstandinbBiddersMouseover(frame)
    frame.OutstandingBidders:SetScript("OnEnter", function()
        local outstanding = ajdkp.AUCTIONS[frame.auction_id].outstanding;
        if #outstanding > 0 then
            GameTooltip:SetOwner(UIParent, "ANCHOR_NONE");
            GameTooltip:SetPoint("BOTTOMRIGHT", frame.OutstandingBidders, "TOPLEFT");
            GameTooltip:ClearLines();
            local text = "Waiting for bids from:\n";
            for i, player in ipairs(outstanding) do
                if i == 1 then
                    text = text .. ajdkp.ColorByClass(player);
                else
                    text = text .. ", " .. ajdkp.ColorByClass(player);
                end
                if (i % 4) == 0 then
                    text = text .. "\n";
                end
            end
            GameTooltip:SetText(text);
        end
    end);
    frame.OutstandingBidders:SetScript("OnLeave", function()
        GameTooltip:Hide();
    end);
end

function ajdkp.InitMLFrame(frame)
    local auction = ajdkp.AUCTIONS[frame.auction_id];
    local _, _, id, name = string.find(auction.item_link, ".*item:(%d+).-%[(.-)%]|h|r");
    frame.Title:SetText(name);
    frame.Icon.Texture:SetTexture(GetItemIcon(id));
    frame.DeclareWinner:SetText("Declare Winner"); -- in case we're reusing an old frame that's showing the old winner
    frame:Show();
end

function ajdkp.GetOrCreateMLFrame(auction_id)
    local frame;
    if #AvailableMLFrames > 0 then
        frame = table.remove(AvailableMLFrames);
        frame.auction_id = auction_id;
    else
        -- reserve a frame id
        local id = nextMLFrame;
        nextMLFrame = nextMLFrame + 1;
        local name = string.format("MLFrame%d", id);
        -- instantiate the frame
        frame = CreateFrame("FRAME", name, UIParent, "MLFrameTemplate");
        frame.id = id;
        frame.auction_id = auction_id;
        -- restore the saved position
        local saved_position = AJDKP_FRAME_POSITIONS[name];
        if saved_position then
            local point, relative_point, x, y = unpack(saved_position);
            frame:ClearAllPoints();
            frame:SetPoint(point, UIParent, relative_point, x, y);
        else
            local x_offset = (((frame.id - 1) % 5) - 2) * 300;
            local y_offset = math.floor((frame.id - 1) / 5) * 200;
            frame:SetPoint("CENTER", UIParent, "CENTER", x_offset, y_offset);
        end
        -- set the hover tooltips
        ajdkp.SetIconMouseover(frame);
        ajdkp.SetOutstandinbBiddersMouseover(frame);
        -- link the buttons
        ajdkp.GetCloseButton(frame):SetScript("OnClick", function() ajdkp.CancelAuction(frame.auction_id) end);
        frame.DeclareWinner:SetScript("OnClick", function () ajdkp.DeclareWinner(frame, frame.auction_id) end);
        -- listen for updates (bids, time ticking down)
        local previous_bid_count = 0;
        local function GetOrCreateBidRow(i)
            local row = _G[string.format("%sBidderListRow%d", frame:GetName(), i)];
            if not row then
                row = CreateFrame("FRAME", string.format("$parentRow%d", i), frame.BidderList);
                row:SetSize(180, 15);
                row:SetPoint("TOPLEFT", frame.BidderList, "TOPLEFT", 5, 12 + (-15 * i));
                local spec = row:CreateFontString();
                row.spec = spec;
                spec:SetFont("Fonts\\FRIZQT__.TTF", 12);
                spec:SetPoint("TOPLEFT", row, "TOPLEFT");
                local amt = row:CreateFontString();
                row.amt = amt;
                amt:SetFont("Fonts\\FRIZQT__.TTF", 12);
                amt:SetPoint("TOPLEFT", row, "TOPLEFT", 30, 0);
                local bidder = row:CreateFontString();
                row.bidder = bidder;
                bidder:SetFont("Fonts\\FRIZQT__.TTF", 12);
                bidder:SetPoint("TOPLEFT", row, "TOPLEFT", 70, 0);
                local cancel = CreateFrame("Button", nil, row, "UIPanelCloseButtonNoScripts");
                row.cancel = cancel;
                cancel:SetSize(20, 20);
                cancel:SetPoint("TOPLEFT", row, "TOPLEFT", 150, 4);
            end
            return row
        end
        frame:SetScript("OnUpdate", function(self, sinceLastUpdate)
            -- update the time reamining
            ajdkp.AUCTIONS[frame.auction_id].remaining_time = ajdkp.AUCTIONS[frame.auction_id].remaining_time - sinceLastUpdate;
            local remaining_seconds = math.ceil(ajdkp.AUCTIONS[frame.auction_id].remaining_time);
            frame.CountdownBar:SetValue(remaining_seconds);
            frame.CountdownBar:SetStatusBarColor(ajdkp.ColorGradient(ajdkp.AUCTIONS[frame.auction_id].remaining_time / ajdkp.CONSTANTS.AUCTION_DURATION));
            -- when time expires, move the auction to READY_TO_RESOLVE if we haven't already passed that point
            if remaining_seconds <= 0 then
                if ajdkp.AUCTIONS[frame.auction_id].state == ajdkp.CONSTANTS.ACCEPTING_BIDS then
                    ajdkp.AUCTIONS[frame.auction_id].state = ajdkp.CONSTANTS.READY_TO_RESOLVE
                end
            end
            -- update the bids
            frame.OutstandingBidders.Count:SetText(tostring(#ajdkp.AUCTIONS[frame.auction_id].outstanding));
            frame.BidderList:SetHeight(15 * #ajdkp.AUCTIONS[frame.auction_id].bids);
            frame:SetHeight(88 + 15 * math.max(3, #ajdkp.AUCTIONS[frame.auction_id].bids));
            -- set and show bid rows
            for i, bid in ipairs(ajdkp.AUCTIONS[frame.auction_id].bids) do
                local coeff, amt, bidder = unpack(bid);
                local spec = "MS"
                if coeff == 2 then
                    spec = "OS"
                end
                local row = GetOrCreateBidRow(i);
                row.spec:SetText(spec);
                row.amt:SetText(amt);
                row.bidder:SetText(bidder);
                row.bidder:SetTextColor(unpack(ajdkp.GetClassColor(bidder)));
                row.cancel:SetScript("OnClick", function() ajdkp.RejectBid(frame.auction_id, bidder) end);
                row:Show();
            end
            -- hide excess bid rows
            if #ajdkp.AUCTIONS[frame.auction_id].bids < previous_bid_count then
                local extra_rows_count = previous_bid_count - #ajdkp.AUCTIONS[frame.auction_id].bids;
                for i=math.max(1, previous_bid_count - extra_rows_count),previous_bid_count do
                    _G[string.format("%sBidderListRow%d", frame:GetName(), i)]:Hide();
                end
            end
            -- current bid count becomes previous for the next frame
            previous_bid_count = #ajdkp.AUCTIONS[frame.auction_id].bids;
            -- update the Declare Winner button
            if ajdkp.AUCTIONS[frame.auction_id].state == ajdkp.CONSTANTS.ACCEPTING_BIDS or ajdkp.AUCTIONS[frame.auction_id].state == ajdkp.CONSTANTS.COMPLETE then
                frame.DeclareWinner:Disable();
            elseif ajdkp.AUCTIONS[frame.auction_id].state == ajdkp.CONSTANTS.READY_TO_RESOLVE and #ajdkp.AUCTIONS[frame.auction_id].bids > 0 then
                frame.DeclareWinner:Enable();
            elseif ajdkp.AUCTIONS[frame.auction_id].state == ajdkp.CONSTANTS.CANCELED then
                frame:Hide();
            end
        end);
        -- when the frame is no longer needed, send it back to the frame pool
        frame:SetScript("OnHide", function()
            local insertion_index = 0;
            for i,mlframe in ipairs(AvailableMLFrames) do
                if frame.id > mlframe.id then
                    insertion_index = i;
                    break
                end
            end
            if insertion_index == 0 then
                table.insert(AvailableMLFrames, frame);
            else
                table.insert(AvailableMLFrames, insertion_index, frame);
            end
        end);
    end
    ajdkp.InitMLFrame(frame);
end

function ajdkp.InitBidFrame(frame)
    local _, _, id, name = string.find(frame.item_link, ".*item:(%d+).-%[(.-)%]|h|r");
    frame.Title:SetText(name);
    frame.Icon.Texture:SetTexture(GetItemIcon(id));
    frame.BidAmount:SetText("");
    frame:Show();
end

function ajdkp.GetOrCreateBidFrame(auction_id, item_link, master_looter, remaining_time)
    local frame;
    if not (#AvailableBidFrames == 0) then
        frame = table.remove(AvailableBidFrames);
        frame.auction_id = auction_id;
        frame.item_link = item_link;
        frame.master_looter = master_looter;
        frame.remaining_time = remaining_time;
    else
        -- reserve a frame id
        local id = nextBidFrame;
        nextBidFrame = nextBidFrame + 1;
        local name = string.format("BidFrame%d", id);
        -- instantiate the frame
        frame = CreateFrame("FRAME", name, UIParent, "BidFrameTemplate");
        frame.id = id;
        frame.auction_id = auction_id;
        frame.item_link = item_link;
        frame.master_looter = master_looter;
        frame.remaining_time = remaining_time;
        -- restore the saved position
        local saved_position = AJDKP_FRAME_POSITIONS[name];
        if saved_position then
            local point, relative_point, x, y = unpack(saved_position);
            frame:ClearAllPoints();
            frame:SetPoint(point, UIParent, relative_point, x, y);
        else
            local x_offset = (((frame.id - 1) % 5) - 2) * 200;
            local y_offset = (math.floor((frame.id - 1) / 5) * 120) - 300;
            frame:SetPoint("CENTER", UIParent, "CENTER", x_offset, y_offset);
        end
        -- set the hover tooltip
        ajdkp.SetIconMouseover(frame);

        local player = ajdkp.StripRealm(UnitName("player"));
        frame.BidAmount:SetScript("OnTextChanged", function()
            if ajdkp.IsValidBid(player, frame.BidAmount:GetNumber()) then
                frame.MS:Enable();
                frame.OS:Enable();
            else
                frame.MS:Disable();
                frame.OS:Disable();
            end
        end);
        frame.MS:SetScript("OnClick", function()
            ajdkp.SendPlaceBid(
                frame.auction_id,
                ajdkp.CONSTANTS.MS,
                frame.BidAmount:GetNumber(),
                frame.master_looter
            );
            frame:Hide();
        end);
        frame.OS:SetScript("OnClick", function()
            ajdkp.SendPlaceBid(
                frame.auction_id,
                ajdkp.CONSTANTS.OS,
                frame.BidAmount:GetNumber(),
                frame.master_looter
            );
            frame:Hide();
        end);
        ajdkp.GetCloseButton(frame):SetScript("OnClick", function()
            ajdkp.SendPass(frame.auction_id, frame.master_looter);
            frame:Hide();
        end);

        frame:SetScript("OnUpdate", function(self, sinceLastUpdate)
            frame.remaining_time = frame.remaining_time - sinceLastUpdate;
            local remaining_seconds = math.ceil(frame.remaining_time);
            frame.CountdownBar:SetValue(remaining_seconds);
            frame.CountdownBar:SetStatusBarColor(ajdkp.ColorGradient(frame.remaining_time / (ajdkp.CONSTANTS.AUCTION_DURATION - 10)));
            if frame.remaining_time <= 0 then
                ajdkp.SendPass(frame.auction_id, frame.master_looter);
                frame:Hide();
            end
            frame.CurrentDKP:SetText(string.format("/ %d", ajdkp.GetDKP(player)));
        end);
        frame:SetScript("OnHide", function()
            local insertion_index = 0;
            for i,bidframe in ipairs(AvailableBidFrames) do
                if frame.id > bidframe.id then
                    insertion_index = i;
                    break
                end
            end
            if insertion_index == 0 then
                table.insert(AvailableBidFrames, frame);
            else
                table.insert(AvailableBidFrames, insertion_index, frame);
            end
        end);
    end
    ajdkp.InitBidFrame(frame);
end

--------------
-- Auctions --
--------------

-- keys are auction ids
-- values are
-- {
--   state: 1|2|3, -- auction states are listed above
--   item_link: "...", -- printable link to the item being auctioned
--   remaining_time: 123, -- number of seconds remaining in the auction (may include partial seconds, bidders see this number - 10)
--   outstanding: {}, -- keys are character names, values are whether that character has bid or passed
--   bids: {}, -- bids are (spec, amount, character) sorted
--   winner: {character, amount}, -- only present if state == COMPLETE
--   start_time: 123, -- wall clock time when the auction was started
-- }
ajdkp.AUCTIONS = {};

local NEXT_AUCTION_ID = 1;

-- returns nil if there's not a single winner
function ajdkp.GetSingleWinner(rolls)
    local max = 0;
    local max_count = 0;
    local max_i = 0;
    for i, roll in ipairs(rolls) do
        if roll == max then
            max_count = max_count + 1;
        elseif roll > max then
            max = roll;
            max_count = 1;
            max_i = i;
        end
    end
    if max_count == 1 then
        return max_i
    end
end

function ajdkp.RollUntilSingleWinner(bids)
    local winner_i;
    local rolls = {};
    while not winner_i do
        for i=1,#bids do
            rolls[i] = math.random(100);
        end
        winner_i = ajdkp.GetSingleWinner(rolls);
    end
    return bids[winner_i], rolls
end

local function StartAuction(item_link)
    local auction_id = NEXT_AUCTION_ID;
    NEXT_AUCTION_ID = NEXT_AUCTION_ID + 1;

    local auction = {
        state=ajdkp.CONSTANTS.ACCEPTING_BIDS,
        item_link=item_link,
        remaining_time=ajdkp.CONSTANTS.AUCTION_DURATION,
        outstanding=ajdkp.GetRaidMembers(),
        bids={},
        start_time=date("%Y/%m/%d %H:%M:%S"),
    };
    ajdkp.AUCTIONS[auction_id] = auction;
    ajdkp.GetOrCreateMLFrame(auction_id);
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

function ajdkp.DeclareWinner(ml_frame, auction_id)
    local auction = ajdkp.AUCTIONS[auction_id];
    if ajdkp.AUCTIONS[auction_id].state == ajdkp.CONSTANTS.READY_TO_RESOLVE then
        local winning_bid, tied_bids, rolls = ajdkp.DetermineWinner(auction_id);
        local spec, amt, character = unpack(winning_bid);
        -- the final price can never be less than 10
        amt = math.max(amt, 10);
        if spec == ajdkp.CONSTANTS.MS then
            spec = "MS"
        elseif spec == ajdkp.CONSTANTS.OS then
            spec = "OS"
        end
        if character then
            ajdkp.AUCTIONS[auction_id].state = ajdkp.CONSTANTS.COMPLETE;
            if tied_bids then
                SendChatMessage(string.format("Top bid for %s was tied", auction.item_link));
                -- if there was a tie, announce the rolls
                for i=1,#tied_bids do
                    local _, _, character = unpack(tied_bids[i]);
                    local roll = rolls[i];
                    SendChatMessage(string.format("Tiebreak Roll - %d by %s", roll, character), "RAID");
                end
            end
            SendChatMessage(string.format("%s wins %s for %d dkp (%s)", character, auction.item_link, amt, spec), "RAID_WARNING");
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
            ajdkp.AUCTIONS[auction_id].winner = {character, amt};
            SOTA_Call_SubtractPlayerDKP(character, amt);
            ml_frame.DeclareWinner:SetText(character .. " wins!");
            ajdkp.GetCloseButton(ml_frame):SetScript("OnClick", function() ml_frame:Hide() end)
        end
    end
end

-- returns (spec, amt, character), tied bids, tiebreak rolls
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
                local winning_bid, rolls = ajdkp.RollUntilSingleWinner(tied_bids);
                return winning_bid, tied_bids, rolls
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
                local winning_bid, rolls = ajdkp.RollUntilSingleWinner(tied_bids);
                return winning_bid, tied_bids, rolls
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
end

--------------
-- MESSAGES --
--------------

function ajdkp.SendStartAuction(auction_id, item_link)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %d %s", ajdkp.CONSTANTS.START_AUCTION, auction_id, item_link), "RAID");
end

function ajdkp.HandleStartAuction(auction_id, item_link, master_looter)
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, auction_id + 1);
    -- bidders see a 10 second shorter auction than the ML to avoid the ML closing the auction when someone can still see it
    ajdkp.GetOrCreateBidFrame(auction_id, item_link, master_looter, ajdkp.CONSTANTS.AUCTION_DURATION - 10);
end

function ajdkp.SendResumeAuction(auction_id, item_link, remaining_time, target)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %d %d %s", ajdkp.CONSTANTS.RESUME_AUCTION, auction_id, remaining_time, item_link), "WHISPER", target);
end

function ajdkp.HandleResumeAuction(auction_id, item_link, master_looter, remaining_time)
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, auction_id + 1);
    ajdkp.GetOrCreateBidFrame(auction_id, item_link, master_looter, remaining_time);
end

function ajdkp.SendPlaceBid(auction_id, spec, amt, master_looter)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %d %d %d", ajdkp.CONSTANTS.PLACE_BID, auction_id, spec, amt), "WHISPER", master_looter);
end

function ajdkp.HandlePlaceBid(auction_id, spec, amt, character)
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, auction_id + 1);
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
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, auction_id + 1);
    print("your bid was rejected by the master looter");
end

function ajdkp.SendCancelAuction(auction_id)
    C_ChatInfo.SendAddonMessage("AJDKP", string.format("%s %d", ajdkp.CONSTANTS.CANCEL_AUCTION, auction_id), "RAID");
end

function ajdkp.HandleCancelAuction(auction_id)
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, auction_id + 1);
    for i=1,nextBidFrame do
        local frame = _G[string.format("BidFrame%d", i)];
        if frame and (frame.auction_id == auction_id) then
            frame:Hide();
            break
        end
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
    NEXT_AUCTION_ID = math.max(NEXT_AUCTION_ID, auction_id + 1);
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
                ajdkp.HandleStartAuction(tonumber(auction_id), item_link, sender);
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
                ajdkp.HandleWelcome(tonumber(next_auction_id), version);
            end
        end
    end
end);


SLASH_AJDKP_AUCTION1 = "/auction";
SlashCmdList["AJDKP_AUCTION"] = function(msg)
    for link in string.gmatch(msg, ".-|h|r") do
        StartAuction(link);
    end
end
SLASH_AJDKP_WINNERS1 = "/winners";
SlashCmdList["AJDKP_WINNERS"] = function(msg)
    for i=1,NEXT_AUCTION_ID do
        local auction = ajdkp.AUCTIONS[i];
        if auction then
            local winner, amt = unpack(auction.winner);
            print(winner, "won", auction.item_link, "for", amt, "at", auction.start_time);
        end
    end
end


-- TODO: recognize if there are two of the same item being auctioned and show just one window and give them to the two highest
-- TODO: disable bidding on items the user can't equip
-- TODO: normalize frame strata
-- TODO: widen the ML frame slightly
-- TODO: improve anchors/points so the frames are more easily modified
-- TODO: consider a "to-be-distributed" list with "x"s and won auctions go there
-- TODO: send the minimum bid with StartAuction so only the ML needs to update if we change prices
-- TODO: allow item comparisons by holding shift
-- TODO: record the version numbers for GREET and WELCOME and add a command to show people on newer and older versions than the player
-- TODO: Add a downgrade to os button (or an upgrade to MS depending on the current bid). message the bidder telling them their bid has been changed
-- TODO: make it clearer that OS covers PVP
