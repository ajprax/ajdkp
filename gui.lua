local _, ajdkp = ...

local function ColorGradient(p)
    if p >= 1 then
        return 0, 1, 0
    elseif p <= 0 then
        return 1, 0, 0
    end
    return 1- p, p, 0
end

local function SetIconMouseover(bid_frame, item_link)
    local icon_frame = bid_frame.Icon;
    local tooltip_frame = _G[string.format("%sTooltip", bid_frame:GetName())];
    local function ShowItemTooltip()
        tooltip_frame:SetOwner(UIParent, "ANCHOR_NONE");
        tooltip_frame:SetPoint("BOTTOMRIGHT", icon_frame, "TOPLEFT");
        tooltip_frame:SetHyperlink(item_link);
    end
    local function HideTooltip()
        tooltip_frame:Hide();
    end

    icon_frame:SetScript("OnEnter", ShowItemTooltip);
    icon_frame:SetScript("OnLeave", HideTooltip);
end

function ajdkp.GetCloseButton(frame)
    local kids = { frame:GetChildren() };
    for _, child in ipairs(kids) do
        return child
    end
end

function ajdkp.CreateBidFrame(auction_id, item_link, master_looter, remaining_time)
    local player = ajdkp.StripRealm(UnitName("player"));
    local bid_frame = _G[string.format("BidFrame%d", auction_id)];
    if bid_frame then
        -- this may not be the same actual auction, so update the icon texture and name
        local _, _, id, name = string.find(item_link, ".*item:(%d+).-%[(.-)%]|h|r");
        bid_frame.Title:SetText(name);
        bid_frame.Icon.Texture:SetTexture(GetItemIcon(id));
        SetIconMouseover(bid_frame, item_link);
        -- if a bid is rejected the old frame will be sitting around ready to reuse
        bid_frame:Show();
    else
        -- otherwise, make a new one
        bid_frame = CreateFrame(
            "FRAME",
            string.format("BidFrame%d", auction_id),
            UIParent,
            "BidFrameTemplate"
        )
        local _, _, id, name = string.find(item_link, ".*item:(%d+).-%[(.-)%]|h|r");
        SetIconMouseover(bid_frame, item_link);
        bid_frame.Title:SetText(name);
        bid_frame.Icon.Texture:SetTexture(GetItemIcon(id));
    end

    local saved_position = AJDKP_FRAME_POSITIONS[bid_frame:GetName()];
    if saved_position then
        bid_frame:SetPoint("CENTER", UIParent, "CENTER", saved_position[1], saved_position[2]);
    else
        local x_offset = ((auction_id % 4) - 1.5) * 200
        bid_frame:SetPoint("CENTER", UIParent, "CENTER", x_offset, -150);
    end
    local pass_button = ajdkp.GetCloseButton(bid_frame);

    bid_frame.BidAmount:SetScript("OnTextChanged", function()
        if ajdkp.IsValidBid(player, bid_frame.BidAmount:GetNumber()) then
            bid_frame.MS:Enable();
            bid_frame.OS:Enable();
        else
            bid_frame.MS:Disable();
            bid_frame.OS:Disable();
        end
    end);
    bid_frame.MS:SetScript("OnClick", function()
        ajdkp.SendPlaceBid(
            auction_id,
            ajdkp.CONSTANTS.MS,
            bid_frame.BidAmount:GetNumber(),
            master_looter
        );
        bid_frame:Hide();
    end);
    bid_frame.OS:SetScript("OnClick", function()
        ajdkp.SendPlaceBid(
            auction_id,
            ajdkp.CONSTANTS.OS,
            bid_frame.BidAmount:GetNumber(),
            master_looter
        )
        bid_frame:Hide();
    end);
    pass_button:SetScript("OnClick", function()
        ajdkp.SendPass(auction_id, master_looter);
        bid_frame:Hide();
    end);

    function bid_frame:OnUpdate(sinceLastUpdate)
        remaining_time = remaining_time - sinceLastUpdate;
        local remaining_seconds = math.ceil(remaining_time);
        local countdown_bar = _G[string.format("BidFrame%dCountdownBar", auction_id)];
        countdown_bar:SetValue(remaining_seconds);
        countdown_bar:SetStatusBarColor(ColorGradient(remaining_time / (ajdkp.CONSTANTS.AUCTION_DURATION - 10)));
        if remaining_seconds <= 0 then
            ajdkp.SendPass(auction_id, master_looter);
            bid_frame:Hide();
        end
        bid_frame.CurrentDKP:SetText(string.format("/ %d", ajdkp.GetDKP(player)));
    end
    bid_frame:SetScript("OnUpdate", bid_frame.OnUpdate);
end

function ajdkp.CreateMLFrame(auction_id, item_link)
    local auction = ajdkp.AUCTIONS[auction_id];
    local ml_frame = CreateFrame(
        "FRAME",
        string.format("MLFrame%d", auction_id),
        UIParent,
        "MLFrameTemplate"
    );

    local saved_position = AJDKP_FRAME_POSITIONS[ml_frame:GetName()];
    if saved_position then
        ml_frame:SetPoint("CENTER", UIParent, "CENTER", saved_position[1], saved_position[2]);
    else
        local x_offset = ((auction_id % 4) - 1.5) * 300
        ml_frame:SetPoint("CENTER", UIParent, "CENTER", x_offset, -300);
    end
    local _, _, id, name = string.find(item_link, ".*item:(%d+).-%[(.-)%]|h|r");
    SetIconMouseover(ml_frame, item_link);
    ml_frame.Title:SetText(name);
    ml_frame.Icon.Texture:SetTexture(GetItemIcon(id));
    local close_button = ajdkp.GetCloseButton(ml_frame);
    close_button:SetScript("OnClick", function()
        ajdkp.CancelAuction(auction_id);
    end);
    local declare_winner_button = _G[string.format("MLFrame%dDeclareWinnerButton", auction_id)];
    declare_winner_button:SetScript("OnClick", function() ajdkp.DeclareWinner(auction_id) end);

    local function GetOrCreateBidRow(list_frame, i)
        local spec_text = _G[string.format("MLFrame%dBidderListSpec%d", auction_id, i)];
        if spec_text then
            spec_text:Show();
        else
            spec_text = list_frame:CreateFontString(string.format("$parentSpec%d", i));
            spec_text:SetFont("Fonts\\FRIZQT__.TTF", 12);
            spec_text:SetPoint("TOPLEFT", list_frame, "TOPLEFT", 5, 12 + (-15 * i));
        end
        local amt_text = _G[string.format("MLFrame%dBidderListAmt%d", auction_id, i)];
        if amt_text then
            amt_text:Show();
        else
            amt_text = list_frame:CreateFontString(string.format("$parentAmt%d", i));
            amt_text:SetFont("Fonts\\FRIZQT__.TTF", 12);
            amt_text:SetPoint("TOPLEFT", list_frame, "TOPLEFT", 35, 12 + (-15 * i));
        end
        local bidder_text = _G[string.format("MLFrame%dBidderListBidder%d", auction_id, i)];
        if bidder_text then
            bidder_text:Show();
        else
            bidder_text = list_frame:CreateFontString(string.format("$parentBidder%d", i));
            bidder_text:SetFont("Fonts\\FRIZQT__.TTF", 12);
            bidder_text:SetPoint("TOPLEFT", list_frame, "TOPLEFT", 75, 12 + (-15 * i));
        end
        local cancel_bid_button = _G[string.format("MLFrame%dBidderListCancelButton%d", auction_id, i)];
        if cancel_bid_button then
            cancel_bid_button:Show();
        else
            cancel_bid_button = CreateFrame("Button", string.format("$parentCancelButton%d", i), list_frame, "UIPanelCloseButtonNoScripts");
            cancel_bid_button:SetSize(20, 20);
            cancel_bid_button:SetPoint("TOPLEFT", list_frame, "TOPLEFT", 155, 16 + (-15 * i));
        end
        return spec_text, amt_text, bidder_text, cancel_bid_button
    end

    local function UpdateBidderList(num_old_bids, new_bids, num_outstanding_bids)
        ml_frame.OutstandingBiddersCount:SetText(tostring(num_outstanding_bids));
        local list_frame = ml_frame.BidderList;
        local num_new_bids = #new_bids;
        list_frame:SetHeight(15 * num_new_bids);
        ml_frame:SetHeight(88 + 15 * (math.max(3, table.getn(new_bids))));
        for i, bid in ipairs(new_bids) do
            local coeff, amt, bidder = unpack(bid);
            local spec = "MS"
            if coeff == 2 then
                spec = "OS"
            end

            local spec_text, amt_text, bidder_text, cancel_bid_button = GetOrCreateBidRow(list_frame, i);
            spec_text:SetText(spec);
            amt_text:SetText(amt);
            bidder_text:SetText(bidder);
            bidder_text:SetTextColor(unpack(ajdkp.CONSTANTS.CLASS_COLORS[select(3, UnitClass(bidder))]));
            cancel_bid_button:SetScript("OnClick", function()
                ajdkp.RejectBid(auction_id, bidder);
            end);
        end
        -- if there are fewer bids now than before, hide the extras (they may be reused if the list grows again
        if num_new_bids < num_old_bids then
            local num_extra = num_old_bids - num_new_bids;
            for i=math.max(1, num_old_bids - num_extra),num_old_bids do
                -- TODO: create a parent frame for these and hide that
                local spec_text = _G[string.format("MLFrame%dBidderListSpec%d", auction_id, i)];
                local amt_text = _G[string.format("MLFrame%dBidderListAmt%d", auction_id, i)];
                local bidder_text = _G[string.format("MLFrame%dBidderListBidder%d", auction_id, i)];
                local cancel_button = _G[string.format("MLFrame%dBidderListCancelButton%d", auction_id, i)];
                spec_text:Hide();
                amt_text:Hide();
                bidder_text:Hide();
                cancel_button:Hide();
            end
        end
    end

    local num_bids = 0;
    function ml_frame:OnUpdate(sinceLastUpdate)
        -- Update the time remaining
        auction.remaining_time = auction.remaining_time - sinceLastUpdate;
        local remaining_seconds = math.ceil(auction.remaining_time);
        local countdown_bar = _G[string.format("MLFrame%dCountdownBar", auction_id)];
        countdown_bar:SetValue(remaining_seconds);
        countdown_bar:SetStatusBarColor(ColorGradient(auction.remaining_time / ajdkp.CONSTANTS.AUCTION_DURATION));
        if remaining_seconds <= 0 then
            if auction.state == ajdkp.CONSTANTS.ACCEPTING_BIDS then
                auction.state = ajdkp.CONSTANTS.READY_TO_RESOLVE
            end
        end
        -- Update the list of bids
        UpdateBidderList(num_bids, auction.bids, #auction.outstanding);
        num_bids = #auction.bids;
        -- Update the Declare Winner button
        if auction.state == ajdkp.CONSTANTS.ACCEPTING_BIDS or auction.state == ajdkp.CONSTANTS.COMPLETE then
            declare_winner_button:Disable();
        elseif auction.state == ajdkp.CONSTANTS.READY_TO_RESOLVE and #auction.bids > 0 then
            declare_winner_button:Enable();
        elseif auction.state == ajdkp.CONSTANTS.CANCELED then
            ml_frame:Hide();
        end
    end
    ml_frame:SetScript("OnUpdate", ml_frame.OnUpdate);
end
