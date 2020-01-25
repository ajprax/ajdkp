local _, ajdkp = ...

local function ColorGradient(perc)
    if perc >= 1 then
        return 0, 1, 0
    elseif perc <= 0 then
        return 1, 0, 0
    end
    return 1-perc, perc, 0
end

local function MakeTexture(texture_id, frame, hide)
    local texture = frame:CreateTexture();
    texture:SetTexture(texture_id);
    texture:SetAllPoints(frame);
    if hide then
        texture:Hide();
    end
    return texture
end

local function CreateCountdownBar(frame, width, remaining_time, max_time)
    local statusbar = CreateFrame("StatusBar", "$parentCountdownBar", frame);
    statusbar:SetPoint("BOTTOM", frame, "BOTTOM", 0, 4);
    statusbar:SetWidth(width);
    statusbar:SetHeight(10);
    statusbar:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar");
    statusbar:GetStatusBarTexture():SetHorizTile(false);
    statusbar:GetStatusBarTexture():SetVertTile(false);
    statusbar:SetStatusBarColor(0, 0.65, 0);
    statusbar:SetMinMaxValues(0, max_time);

    statusbar.bg = statusbar:CreateTexture(nil, "BACKGROUND");
    statusbar.bg:SetTexture("Interface\\TARGETINGFRAME\\UI-StatusBar");
    statusbar.bg:SetAllPoints(true);
    statusbar.bg:SetVertexColor(0.2, 0.2, 0.2);

    return statusbar
end

local function CreateItemIcon(bid_frame, item_link)
    local icon_frame = CreateFrame("FRAME", "IconFrame", bid_frame);
    icon_frame:SetHeight(36);
    icon_frame:SetWidth(36);
    local icon_texture = MakeTexture(select(10, GetItemInfo(item_link)), icon_frame);
    icon_frame.texture = icon_texture;
    icon_frame:SetPoint("TOPLEFT", bid_frame, "TOPLEFT", 10, -33);

    local tooltip_frame = _G[string.format("%sTooltip", bid_frame:GetName())];

    -- if the linked item hasn't been loaded yet in this client GetItemInfo will return nil and the frame will have no
    -- title or icon texture. setting it as the hyperlink on a tooltip with force the load and then we can set the
    -- texture and title.
    if not GetItemInfo(item_link) then
        tooltip_frame:SetOwner(UIParent, "ANCHOR_NONE");
        tooltip_frame:SetHyperlink(item_link);
        tooltip_frame:SetScript("OnTooltipSetItem", function()
            if GetItemInfo(item_link) then
                tooltip_frame:SetScript("OnTooltipSetItem", nil);
                local name, link, quality, iLevel, reqLevel, type, subType, maxStack, equipSlot, texture = GetItemInfo(item_link);
                icon_texture:SetTexture(texture);
                _G[string.format("%sTitle", bid_frame:GetName())]:SetText(name);
            end
        end);
    end

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

local function CreateTitleText(bid_frame, item_link)
    local item_name = select(1, GetItemInfo(item_link));
    local title = bid_frame:CreateFontString("%parentTitle", "BACKGROUND", "ChatFontNormal");
    title:SetFont("Fonts\\FRIZQT__.TTF", 12);
    title:SetText(item_name);
    title:SetPoint("TOPLEFT", bid_frame, "TOPLEFT", 5, -5);
end

local function CreateCurrentDKPText(bid_frame)
    local current_dkp_text = bid_frame:CreateFontString(string.format("%sCurrentDKP", bid_frame:GetName()), "BACKGROUND", "ChatFontNormal");
    current_dkp_text:SetFont("Fonts\\FRIZQT__.TTF", 12);
    current_dkp_text:SetPoint("LEFT", _G[string.format("%sBidAmount", bid_frame:GetName())], "RIGHT", 5, 0);
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
        -- bidders see a 10 second shorter auction than the ML to avoid the ML closing the auction when someone can still see it
        CreateCountdownBar(bid_frame, 160, remaining_time, ajdkp.CONSTANTS.AUCTION_DURATION - 10);
        CreateTitleText(bid_frame, item_link);
        CreateItemIcon(bid_frame, item_link);
        CreateCurrentDKPText(bid_frame);
    end

    local x_offset = ((auction_id % 4) - 1.5) * 200
    bid_frame:SetPoint("CENTER", UIParent, "CENTER", x_offset, -150);

    local bid_input = _G[string.format("BidFrame%dBidAmount", auction_id)];
    local ms_button = _G[string.format("BidFrame%dMSButton", auction_id)];
    local os_button = _G[string.format("BidFrame%dOSButton", auction_id)];
    local pass_button = ajdkp.GetCloseButton(bid_frame);
    local current_dkp_text = _G[string.format("BidFrame%dCurrentDKP", auction_id)];

    bid_input:SetScript("OnTextChanged", function()
        if ajdkp.IsValidBid(player, bid_input:GetNumber()) then
            ms_button:Enable();
            os_button:Enable();
        else
            ms_button:Disable();
            os_button:Disable();
        end
    end);
    ms_button:SetScript("OnClick", function()
        ajdkp.SendPlaceBid(
            auction_id,
            ajdkp.CONSTANTS.MS,
            bid_input:GetNumber(),
            master_looter
        );
        bid_frame:Hide();
    end);
    os_button:SetScript("OnClick", function()
        ajdkp.SendPlaceBid(
            auction_id,
            ajdkp.CONSTANTS.OS,
            bid_input:GetNumber(),
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
        current_dkp_text:SetText(string.format("/ %d", ajdkp.GetDKP(player)));
    end
    bid_frame:SetScript("OnUpdate", bid_frame.OnUpdate);
end

local function CreateBidListFrame(ml_frame)
    local list_frame = CreateFrame("FRAME", "$parentBidderList", ml_frame);
    list_frame:SetPoint("TOPRIGHT", ml_frame, "TOPRIGHT", -10, -33);
    list_frame:SetSize(180, 0);
end

function ajdkp.CreateMLFrame(auction_id, item_link)
    local auction = ajdkp.AUCTIONS[auction_id];
    local ml_frame = CreateFrame(
        "FRAME",
        string.format("MLFrame%d", auction_id),
        UIParent,
        "MLFrameTemplate"
    );
    local x_offset = ((auction_id % 4) - 1.5) * 300
    ml_frame:SetPoint("CENTER", UIParent, "CENTER", x_offset, -300);
    CreateCountdownBar(ml_frame, ml_frame:GetWidth() - 8, ajdkp.CONSTANTS.AUCTION_DURATION, ajdkp.CONSTANTS.AUCTION_DURATION);
    CreateTitleText(ml_frame, item_link);
    CreateItemIcon(ml_frame, item_link);
    CreateBidListFrame(ml_frame);
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

    local function UpdateBidderList(num_old_bids, new_bids)
        local list_frame = _G[string.format("MLFrame%dBidderList", auction_id)];
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
        UpdateBidderList(num_bids, auction.bids);
        num_bids = #auction.bids;
        -- Update the Declare Winner button
        if auction.state == ajdkp.CONSTANTS.ACCEPTING_BIDS or auction.state == ajdkp.CONSTANTS.COMPLETE then
            declare_winner_button:Disable();
        elseif auction.state == ajdkp.CONSTANTS.READY_TO_RESOLVE then
            declare_winner_button:Enable();
        elseif auction.state == ajdkp.CONSTANTS.CANCELED then
            ml_frame:Hide();
        end
    end
    ml_frame:SetScript("OnUpdate", ml_frame.OnUpdate);
end
