local _, ajdkp = ...

function ajdkp.Contains(array, item)
    for _, e in ipairs(array) do
        if item == e then
            return true
        end
    end
    return false
end

function ajdkp.Remove(array, item)
    for i, e in ipairs(array) do
        if item == e then
            table.remove(array, i);
            break
        end
    end
end

function ajdkp.GetRaidMembers()
    local out = {};
    for i=1,40 do
        local name, rank, subgroup, level, class, fileName, zone, online, isDead, role, isML = GetRaidRosterInfo(i);
        if name then
            table.insert(out, name);
        end
    end
    return out
end

-- bids are (spec [2|1], amount, ...)
function ajdkp.MSOverOSSort(new_bid, old_bid)
    -- check spec, then bid amount
    if new_bid[1] < old_bid[1] then
        return true
    elseif new_bid[1] > old_bid[1] then
        return false
    else
        return new_bid[2] > old_bid[2]
    end
end

-- only used in 2:1 priority systems
function ajdkp.BidWeight(bid)
    local spec, amt = unpack(bid);
    return amt / spec
end

-- bids are (spec [2|1], amount, ...)
function ajdkp.TwoToOneSort(new_bid, old_bid)
    -- 2:1 means an OS bid has to be 2x an MS bid to tie, so compare bid weights
    return ajdkp.BidWeight(new_bid) > ajdkp.BidWeight(old_bid)
end

function ajdkp.ApplyPriority(b1, b2)
    if ajdkp.CONSTANTS.PRIORITY_TYPE == ajdkp.CONSTANTS.MS_OVER_OS then
        return ajdkp.MSOverOSSort(b1, b2);
    elseif ajdkp.CONSTANTS.PRIORITY_TYPE == ajdkp.CONSTANTS.TWO_TO_ONE then
        return ajdkp.TwoToOneSort(b1, b2);
    end
end

function ajdkp.InsertNewBid(bids, new_bid)
    -- find the insertion index then shift everything after downward

    -- default to inserting at the end, for an empty table this will be position 1
    local insert_at = #bids + 1;
    for i, old_bid in ipairs(bids) do
        if ajdkp.ApplyPriority(new_bid, old_bid) then
            insert_at = i;
            break
        end
    end

    -- shift from the end so we don't overwrite values we have yet to shift
    for i=#bids,insert_at,-1 do
        bids[i+1] = bids[i]
    end
    bids[insert_at] = new_bid
end

function ajdkp.StripRealm(character)
    local start = string.find(character, "-");
    if start then
        return character:sub(1, start - 1)
    else
        return character
    end
end

function ajdkp.IsValidBid(character, amount)
    return amount >= 10 and ajdkp.GetDKP(character) >= amount
end

function ajdkp.GetDKP(character)
    local num_guild_members = GetNumGuildMembers();
    for i=1,num_guild_members do
        local nameAndRealm, rank, rankIndex, _, class, zone, publicnote, officernote, online = GetGuildRosterInfo(i);
        if character == ajdkp.StripRealm(nameAndRealm) then
            local _, _, dkp = string.find(officernote, "<(-?%d*)>");
            if dkp then
                dkp = tonumber(dkp);
            end
            if dkp then
                return dkp
            end
        end
    end
    return 0
end

-- generates ~64 bit random ids
function ajdkp.GenerateAuctionId()
    return string.gsub("xxxxxxxxxxxxxxxxxxxx", "[x]", function ()
        return string.format("%x", math.random(0, 0x9))
    end)
end

function ajdkp.PrintableSpec(spec)
    if spec == 1 then
        return "MS"
    else
        return "OS"
    end
end
