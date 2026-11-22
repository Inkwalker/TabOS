local Document = require("document")
local Files = require("files")
local Tabs = require("tabs")
local Recovery = {}
Recovery.__index = Recovery

local root = Files.recovery_directory()
local root_key = Files.key(root)
local session_magic, legacy_magic, draft_magic = "TCS2", "TCS1", "TCD1"
local envelope, session_header, tab_header, draft_header = "<c4I4I4", "<I4B", "<BI4I4BI4I4", "<I4BBI4I4"
local legacy_header, legacy_tab = "<I4BB", "<BI4I4BI4I4I4I4I4I4"
local idle, interval = 2, 10
local missing = 2 -- ENOENT
local path_limit = 4096
local generation_limit = 0x7fffffff
local session_limit = string.packsize(legacy_header) + Tabs.limit * (string.packsize(legacy_tab) + path_limit)
local draft_limit = string.packsize(draft_header) + 2 * Document.limit

local function session_path(bank)
    return root .. "/session" .. bank .. ".bin"
end

local function draft_path(slot, bank)
    return string.format("%s/tab%d-%d.bin", root, slot, bank)
end

-- Include every byte, with one Lua iteration per four bytes of document text.
local function checksum(bytes)
    local hash = 0x811c9dc5
    local stop = #bytes - #bytes % 4
    for index = 1, stop, 4 do
        hash = ((hash ~ string.unpack("<I4", bytes, index)) * 16777619) & 0xffffffff
    end
    for index = stop + 1, #bytes do
        hash = ((hash ~ bytes:byte(index)) * 16777619) & 0xffffffff
    end
    return hash
end
Recovery.checksum = checksum

local function read_record(path, magic, limit, legacy)
    local file, err, code = io.open(path, "rb")
    if not file then
        if code ~= missing then return nil, err or path, true end
        return nil
    end
    local bytes, read_error = file:read(limit + string.packsize(envelope) + 1)
    local closed, close_error = file:close()
    if read_error or not closed then return nil, read_error or close_error or path, true end
    if bytes and #bytes >= string.packsize(envelope) then
        local tag, length, hash, start = string.unpack(envelope, bytes)
        if (tag == magic or tag == legacy) and length <= limit and length == #bytes - start + 1 then
            local payload = bytes:sub(start)
            if checksum(payload) == hash then return payload, nil, nil, tag end
        end
    end
    return nil, "Invalid recovery file: " .. path
end

local function write_record(path, magic, payload)
    local file, err = io.open(path, "wb")
    if not file then return nil, err or path end
    local written, write_error = file:write(string.pack(envelope, magic, #payload, checksum(payload)) .. payload)
    local closed, close_error = file:close()
    if not written or not closed then return nil, write_error or close_error or path end
    return true
end

local function read_session(bank)
    local payload, err, unavailable, magic = read_record(session_path(bank), session_magic, session_limit, legacy_magic)
    if not payload then return nil, err, unavailable end
    local legacy = magic == legacy_magic
    local header, tab_format = session_header, tab_header
    if legacy then header, tab_format = legacy_header, legacy_tab end
    local invalid = "Invalid session metadata: " .. session_path(bank)
    if #payload < string.packsize(header) then return nil, invalid end
    local generation, count, index = string.unpack(session_header, payload)
    if legacy then index = index + 1 end
    if generation < 1 or generation > generation_limit or count > Tabs.limit then
        return nil, invalid
    end
    local session = {generation = generation, bank = bank, items = {}, slots = {}}
    local paths, numbers = {}, {}
    for row = 1, count do
        if #payload - index + 1 < string.packsize(tab_format) then return nil, invalid end
        local slot, older, draft, draft_bank, number, length, next_index
        if legacy then
            local _
            slot, older, draft, draft_bank, number, _, _, _, _, length, next_index =
                string.unpack(legacy_tab, payload, index)
        else
            slot, older, draft, draft_bank, number, length, next_index = string.unpack(tab_header, payload, index)
        end
        index = next_index
        if slot < 1 or slot > Tabs.limit or session.slots[slot] or older < 0 or older > math.max(0, draft - 1)
            or draft < 0 or draft > generation or draft_bank > 1 or number < 0 or number >= generation_limit
            or length < 0 or length > path_limit or length > #payload - index + 1 then return nil, invalid end
        local path, key
        if length > 0 then
            path = payload:sub(index, index + length - 1)
            if number ~= 0 or Files.resolve(path) ~= path then return nil, invalid end
            key = Files.key(path)
            if paths[key] or key == root_key or key:sub(1, #root_key + 1) == root_key .. "/" then
                return nil, invalid
            end
            paths[key] = true
        else
            if number == 0 or numbers[number] then return nil, invalid end
            numbers[number] = true
        end
        local entry = {slot = slot, older = older, draft = draft, bank = draft_bank, path = path,
            number = number}
        session.items[row], session.slots[slot] = entry, entry
        index = index + length
    end
    if index ~= #payload + 1 then return nil, invalid end
    return session
end

local function encode_items(items)
    local parts = {}
    for index, entry in ipairs(items) do
        local path = entry.path or ""
        if #path > path_limit then return nil end
        parts[index] = string.pack(tab_header, entry.slot, entry.older, entry.draft, entry.bank,
            entry.number, #path) .. path
    end
    return string.char(#items) .. table.concat(parts)
end

local function read_draft(entry, bank)
    local payload, err = read_record(draft_path(entry.slot, bank), draft_magic, draft_limit)
    if not payload then return nil, err end
    local invalid = "Invalid draft for " .. (entry.path or ("Untitled " .. entry.number))
    if #payload < string.packsize(draft_header) then return nil, invalid end
    local generation, crlf, named, saved_size, size, index = string.unpack(draft_header, payload)
    local expected = bank == entry.bank and entry.draft or entry.older
    if generation ~= expected or crlf > 1 or named > 1 or (named == 0 and saved_size ~= 0)
        or saved_size < 0 or saved_size > Document.limit or size < 0 or size > Document.limit
        or saved_size + size ~= #payload - index + 1 then
        return nil, invalid
    end
    local saved = named == 1 and payload:sub(index, index + saved_size - 1) or nil
    local bytes = payload:sub(index + saved_size)
    local eol = crlf == 1 and "\r\n" or "\n"
    if entry.path and not saved then return nil, invalid end
    return {bytes = bytes, saved = entry.path and saved or nil, eol = eol, draft = generation, bank = bank}
end

function Recovery:draft(entry, history, current_only)
    local function open(bank)
        local draft, err = read_draft(entry, bank)
        if not draft then return nil, err end
        local doc
        doc, err = Document.new(draft.bytes, history, draft.eol)
        if not doc then return nil, err end
        doc.saved, doc.modified = draft.saved, true
        return doc, draft.bytes, draft
    end
    local doc, bytes, draft = open(entry.bank)
    if doc then return doc, bytes, draft end
    if not current_only and entry.older > 0 then
        local previous, previous_bytes, older = open(1 - entry.bank)
        if previous then return previous, previous_bytes, older, true end
    end
    return nil, bytes or "Draft unavailable"
end

function Recovery.new()
    return setmetatable({generation = 0, bank = 1, slots = {}, items = {}, signature = "\0", cleanup = {},
        next_metadata = idle, retry_at = 0}, Recovery)
end

local function read_sessions()
    local sd, err = fs.stat("/sd")
    if not sd or sd.type ~= "dir" then return nil, err or "SD card unavailable", true end
    local first, first_error, first_unavailable = read_session(0)
    local second, second_error, second_unavailable = read_session(1)
    local session = first
    if second and (not first or second.generation > first.generation) then session = second end
    return session, first_error or second_error, first_unavailable or second_unavailable
end

function Recovery:load()
    local session, err, unavailable = read_sessions()
    if session then
        self.generation, self.bank, self.slots = session.generation, session.bank, session.slots
        self.items = session.items
        self.signature = encode_items(session.items)
    end
    self.unread = unavailable
    return session, err
end

local function ensure_directory()
    local info, err, code = fs.stat(root)
    if not info and code == missing then
        local created
        created, err = fs.mkdir(root)
        if not created then return nil, err or root end
    elseif not info or info.type ~= "dir" then
        return nil, err or root
    end
    return true
end

function Recovery:observe(tab, time)
    local doc = tab.document
    local record = tab.recovery
    if not record then
        record = {draft = 0, older = 0, bank = 0, document = doc, revision = 0}
        tab.recovery = record
    end
    if doc ~= record.document then
        self:retire(tab)
        record.document, record.revision = doc, 0
    end
    if record.revision ~= doc.revision then
        record.revision, record.edited = doc.revision, time
        record.pending = record.pending or time
    end
    if not doc.modified and record.draft > 0 then self:retire(tab) end
    if not doc.modified then record.pending = nil end
    return record
end

function Recovery:retire(tab)
    local record = tab.recovery
    if record then
        if record.draft > 0 then self.cleanup[record.slot] = true end
        record.draft, record.older, record.pending = 0, 0, nil
    end
end

function Recovery:attach(tab, entry, draft)
    tab.recovery = {slot = entry.slot, bank = draft and draft.bank or entry.bank,
        draft = draft and draft.draft or 0, older = draft and draft.draft == entry.draft and entry.older or 0,
        document = tab.document, revision = tab.document.revision}
    if not draft and entry.draft > 0 then self.cleanup[entry.slot] = true end
end

function Recovery:drop(entry)
    if entry.draft > 0 then self.cleanup[entry.slot] = true end
end

local function write_draft(entry, doc)
    local bytes, saved = doc:serialize(), doc.saved
    local payload = string.pack(draft_header, entry.draft, doc.eol == "\r\n" and 1 or 0,
        saved and 1 or 0, saved and #saved or 0, #bytes) .. (saved or "") .. bytes
    return write_record(draft_path(entry.slot, entry.bank), draft_magic, payload)
end

function Recovery:clean_slots(protected)
    local failure
    for slot in pairs(self.cleanup) do
        local current = protected[slot]
        if current and current.draft > 0 then
            self.cleanup[slot] = nil
        else
            local failed
            for bank = 0, 1 do
                local ok, err, code = fs.remove(draft_path(slot, bank))
                if not ok and code ~= missing then failed = err or draft_path(slot, bank) end
            end
            if failed then failure = failed else self.cleanup[slot] = nil end
        end
    end
    return failure
end

function Recovery:check_storage()
    if not self.unread then return true end
    local session, err, unavailable = read_sessions()
    if unavailable then return nil, err end
    if (session and session.generation or 0) ~= self.generation
        or (session and encode_items(session.items) ~= self.signature) then
        return nil, "Restart Code to restore the SD session"
    end
    self.unread = nil
    return true
end

function Recovery:publish(items)
    local signature = encode_items(items)
    if not signature then return nil, "Session path too long" end
    if signature == self.signature then return true end
    local ready, err = ensure_directory()
    if not ready then return nil, err end
    local bank, generation = 1 - self.bank, self.generation + 1
    if generation > generation_limit then return nil, "Session generation exhausted" end
    local ok
    ok, err = write_record(session_path(bank), session_magic, string.pack("<I4", generation) .. signature)
    if not ok then return nil, err end
    self.generation, self.bank, self.signature = generation, bank, signature
    self.items, self.slots = items, {}
    for _, entry in ipairs(items) do self.slots[entry.slot] = entry end
    return true
end

function Recovery:discard_entry(entry)
    self:drop(entry)
    local ready, err = self:check_storage()
    if not ready then return nil, err end
    local items = {}
    for _, current in ipairs(self.items) do
        if current.slot ~= entry.slot then
            items[#items + 1] = current
        elseif current.path then
            local clean = {}
            for key, value in pairs(current) do clean[key] = value end
            clean.draft, clean.older = 0, 0
            items[#items + 1] = clean
        end
    end
    local ok
    ok, err = self:publish(items)
    local cleanup_error = self:clean_slots(ok and self.slots or {})
    if not ok then return nil, err end
    if cleanup_error then return nil, "Draft cleanup failed: " .. cleanup_error end
    return true
end

function Recovery:flush(tabs, time, drafts, discarded)
    local ready, err = self:check_storage()
    if not ready then return nil, err end
    local items, slots, records, due = {}, {}, {}, {}
    local generation = self.generation + 1
    for _, tab in ipairs(tabs.items) do
        local record = self:observe(tab, time)
        if record.slot then slots[record.slot] = true end
    end
    for _, tab in ipairs(tabs.items) do
        local record = tab.recovery
        local discard = discarded and discarded[tab]
        if not discard or tab.path then
            local slot = record.slot
            if not slot then
                for candidate = 1, Tabs.limit do
                    if not slots[candidate] then slot = candidate; break end
                end
                slots[slot] = true
            end
            local entry = {slot = slot, older = record.older, draft = record.draft,
                bank = record.bank, path = tab.path, number = tab.untitled or 0}
            items[#items + 1], records[entry] = entry, record
            if not discard and record.pending and drafts
                and (drafts == "all" or time - record.edited >= idle or time - record.pending >= interval) then
                due[#due + 1] = entry
            end
        end
    end
    if #due > 0 then
        if generation > generation_limit then return nil, "Session generation exhausted" end
        ready, err = ensure_directory()
        if not ready then return nil, err end
    end
    local failure, written = nil, {}
    for _, entry in ipairs(due) do
        local record, current = records[entry], self.slots[entry.slot]
        -- Write away from the last complete draft, including a recovered older copy.
        local bank = 1 - (record.draft > 0 and record.bank or current and current.bank or 1)
        local old_draft, old_bank, old_older = entry.draft, entry.bank, entry.older
        entry.draft, entry.bank, entry.older = generation, bank, old_draft
        local ok, detail = write_draft(entry, record.document)
        if ok then
            written[entry] = true
        else
            entry.draft, entry.bank, entry.older = old_draft, old_bank, old_older
            failure = detail or "Draft write failed"
        end
    end
    local saved
    saved, err = self:publish(items)
    if not saved then
        -- A confirmed Save or Discard still retires its draft if unlink works.
        self:clean_slots({})
        return nil, err
    end
    for _, entry in ipairs(items) do
        local record = records[entry]
        record.slot, record.older, record.draft, record.bank = entry.slot, entry.older, entry.draft, entry.bank
        if written[entry] then record.pending = nil end
    end
    local cleanup_error = self:clean_slots(self.slots)
    if failure then return nil, failure end
    if cleanup_error then return nil, "Draft cleanup failed: " .. cleanup_error end
    return true
end

function Recovery:checkpoint(tabs, time)
    local ok, err = self:flush(tabs, time, "all")
    if not ok then return nil, err end
    local session, read_error, unavailable = read_sessions()
    if unavailable or (session and session.generation or 0) ~= self.generation
        or (session and encode_items(session.items) ~= self.signature) then
        return nil, read_error or "SD session changed or is missing"
    end
    for index, entry in ipairs(self.items) do
        if entry.draft > 0 then
            local tab = tabs.items[index]
            local doc = tab.document
            local draft = read_draft(entry, entry.bank)
            if not draft or draft.bytes ~= doc:serialize() or draft.saved ~= doc.saved or draft.eol ~= doc.eol then
                local older = entry.older > 0 and read_draft(entry, 1 - entry.bank)
                if older then self:attach(tab, entry, older) end
                tab.recovery.edited, tab.recovery.pending = time, time
                return nil, "Draft changed or is missing: " .. (tab.path or tab.name)
            end
        end
    end
    return true
end

function Recovery:update(tabs, time)
    local due = time >= self.next_metadata
    for _, tab in ipairs(tabs.items) do
        local record = self:observe(tab, time)
        if record.pending and (time - record.edited >= idle or time - record.pending >= interval) then due = true end
    end
    if not due or time < self.retry_at then return end
    self.next_metadata = time + idle
    local ok, err = self:flush(tabs, time, true)
    self.retry_at = ok and 0 or time + idle
    return ok, err
end

return Recovery
