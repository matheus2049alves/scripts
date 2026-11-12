-- minerator_anki.lua
-- Comunicação com AnkiConnect via curl no mpv (Windows)

local utils = require("mp.utils")
local cleaner = require("minerator_cleaner")
local matcher = require("minerator_matcher")

local M = {}

M.anki_url = "http://127.0.0.1:8765"
M.known_senses = {}

-- Executa uma requisição síncrona ao AnkiConnect via curl
function M.request(action, params)
    local json_str = utils.format_json({ action = action, version = 6, params = params or {} })
    if not json_str then return nil, "Falha ao serializar JSON para AnkiConnect" end

    local res = mp.command_native({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { "curl.exe", "-s", "--max-time", "5", "-X", "POST", "-H", "Content-Type: application/json", "-d", json_str, M.anki_url }
    })

    if res.status ~= 0 or not res.stdout or res.stdout == "" then
        return nil, "AnkiConnect inacessivel em " .. M.anki_url
    end

    local data, parse_err = utils.parse_json(res.stdout)
    if parse_err or not data then return nil, "Resposta invalida do AnkiConnect: " .. tostring(parse_err) end
    if data.error then return nil, tostring(data.error) end
    return data.result, nil
end

-- Verifica se o AnkiConnect está respondendo
function M.check_status()
    local version, err = M.request("version")
    if err or not version then return false, err or "Desconectado" end
    return true, "AnkiConnect v" .. tostring(version)
end

-- Obtém lista de nomes dos campos do modelo
function M.get_model_fields(model_name)
    local fields, err = M.request("modelFieldNames", { modelName = model_name })
    return (fields and not err) and fields or { "Front", "Back" }
end

-- Envia arquivo de mídia para a collection.media do Anki usando caminho local
function M.store_media(filename, local_file_path)
    return M.request("storeMediaFile", { filename = filename, path = local_file_path })
end

-- Adiciona um cartão novo ao Anki
function M.add_card(deck_name, model_name, fields_table, tags_table)
    local note_params = {
        deckName = deck_name, modelName = model_name, fields = fields_table,
        tags = tags_table or { "anki-minerator", "mpv-mining" },
        options = { allowDuplicate = false, duplicateScope = "deck" }
    }
    return M.request("addNote", { note = note_params })
end

-- Extrai palavras e sentidos de um conjunto de notas do Anki
local function extract_words_from_notes(notes, known_words, front_field)
    local count = 0
    for _, note in ipairs(notes) do
        local fields = note.fields or {}
        local front_val = (front_field and fields[front_field] and fields[front_field].value)
            or (fields.Front and fields.Front.value) or (fields.Frente and fields.Frente.value)
        if not front_val then
            for _, f_data in pairs(fields) do front_val = f_data.value break end
        end

        local back_val = (fields.Back and fields.Back.value) or (fields.Verso and fields.Verso.value)
        local meaning = back_val and matcher.extract_meaning_from_back(back_val) or ""

        if front_val and front_val ~= "" then
            for hl in front_val:gmatch("<span[^>]*>(.-)</span>") do
                local hn = cleaner.normalize_item(cleaner.remove_html_and_tags(hl))
                if hn ~= "" then
                    known_words[hn] = true
                    if meaning ~= "" then
                        if not M.known_senses[hn] then M.known_senses[hn] = {} end
                        table.insert(M.known_senses[hn], meaning)
                    end
                end
            end
            for hl in front_val:gmatch("<b[^>]*>(.-)</b>") do
                local hn = cleaner.normalize_item(cleaner.remove_html_and_tags(hl))
                if hn ~= "" then
                    known_words[hn] = true
                    if meaning ~= "" then
                        if not M.known_senses[hn] then M.known_senses[hn] = {} end
                        table.insert(M.known_senses[hn], meaning)
                    end
                end
            end
            local clean_text = cleaner.remove_html_and_tags(front_val)
            local words = cleaner.extract_words(clean_text)
            for _, w in ipairs(words) do
                if not known_words[w] then
                    known_words[w] = true
                    count = count + 1
                end
            end
        end
    end
    return count
end

-- Executa busca de notas por query e extrai palavras das frentes
local function fetch_vocabulary_by_query(query, front_field)
    local note_ids, err = M.request("findNotes", { query = query })
    if err or not note_ids then
        return nil, err or "Nenhuma nota encontrada"
    end
    if #note_ids == 0 then
        return {}, nil
    end

    local words = {}
    local batch_size = 500
    for i = 1, #note_ids, batch_size do
        local batch = {}
        for j = i, math.min(i + batch_size - 1, #note_ids) do
            table.insert(batch, note_ids[j])
        end
        local notes_info = M.request("notesInfo", { notes = batch })
        if notes_info then
            extract_words_from_notes(notes_info, words, front_field)
        end
    end
    return words, nil
end

-- Sincroniza todo o vocabulário das frentes de um deck via AnkiConnect
function M.fetch_deck_vocabulary(deck_name, front_field)
    return fetch_vocabulary_by_query('deck:"' .. deck_name .. '"', front_field)
end

-- Busca vocabulário incremental de notas criadas ou modificadas recentemente
function M.fetch_incremental_vocabulary(deck_name, days_back, front_field)
    local days = tonumber(days_back) or 7
    local query = string.format('deck:"%s" (added:%d or edited:%d)', deck_name, days, days)
    return fetch_vocabulary_by_query(query, front_field)
end

-- Carrega vocabulário diretamente de um arquivo TSV exportado do Anki (ex: CIMV.txt)
function M.load_from_tsv(tsv_path)
    local f = io.open(tsv_path, "r")
    if not f then
        return nil, "Nao foi possivel abrir o arquivo TSV: " .. tostring(tsv_path)
    end

    local known_words = {}
    local lines_read = 0

    for line in f:lines() do
        if not line:match("^#") and line:match("%S") then
            -- Primeira coluna separada por tabulação é a frente
            local front = line:match("^([^\t]+)")
            if front then
                for hl in front:gmatch("<span[^>]*>(.-)</span>") do
                    local hn = cleaner.normalize_item(cleaner.remove_html_and_tags(hl))
                    if hn ~= "" then known_words[hn] = true end
                end
                for hl in front:gmatch("<b[^>]*>(.-)</b>") do
                    local hn = cleaner.normalize_item(cleaner.remove_html_and_tags(hl))
                    if hn ~= "" then known_words[hn] = true end
                end
                local clean = cleaner.remove_html_and_tags(front)
                local words = cleaner.extract_words(clean)
                for _, w in ipairs(words) do
                    known_words[w] = true
                end
                lines_read = lines_read + 1
            end
        end
    end
    f:close()
    return known_words, lines_read
end

-- Salva o vocabulário em cache JSON local para carregamento instantâneo
function M.save_cache(cache_path, known_words)
    local word_list = {}
    for w, _ in pairs(known_words) do table.insert(word_list, w) end
    local json_str = utils.format_json(word_list)
    if not json_str then return false end
    local f = io.open(cache_path, "w"); if not f then return false end
    f:write(json_str); f:close()
    return true
end

-- Carrega o vocabulário do cache JSON local
function M.load_cache(cache_path)
    local f = io.open(cache_path, "r"); if not f then return nil end
    local content = f:read("*all"); f:close()
    local list, err = utils.parse_json(content)
    if not list or type(list) ~= "table" then return nil end
    local known_words = {}
    for _, w in ipairs(list) do known_words[w] = true end
    return known_words
end

-- Salva o mapa de sentidos semânticos conhecidos do Anki
function M.save_senses_cache(cache_path, senses)
    if not cache_path or cache_path == "" then return false end
    local f = io.open(cache_path, "w"); if not f then return false end
    f:write(utils.format_json(senses or {}) or "{}"); f:close()
    return true
end

-- Carrega o mapa de sentidos semânticos do cache local
function M.load_senses_cache(cache_path)
    if not cache_path or cache_path == "" then return {} end
    local f = io.open(cache_path, "r"); if not f then return {} end
    local content = f:read("*all"); f:close()
    local data = utils.parse_json(content)
    return (data and type(data) == "table") and data or {}
end

-- Obtém a data do último sync registrada em arquivo JSON
function M.get_last_sync_date(meta_path)
    local f = io.open(meta_path, "r"); if not f then return nil end
    local content = f:read("*all"); f:close()
    local data = utils.parse_json(content)
    return (data and type(data) == "table") and data.last_sync_date or nil
end

-- Salva a data do último sync no arquivo de controle
function M.save_last_sync_date(meta_path, date_str)
    local f = io.open(meta_path, "w"); if not f then return false end
    f:write(utils.format_json({ last_sync_date = date_str or os.date("%Y-%m-%d"), timestamp = os.time() }) or "{}")
    f:close()
    return true
end

-- Verifica se já foi sincronizado hoje
function M.is_synced_today(meta_path)
    return M.get_last_sync_date(meta_path) == os.date("%Y-%m-%d")
end

-- Sincronização diária incremental: roda apenas se ainda não sincronizou hoje e o Anki estiver online
function M.sync_daily(deck_name, days_back, meta_path, known_words, cache_path, front_field, senses_path)
    if M.is_synced_today(meta_path) then return nil, "already_synced" end
    if not M.check_status() then return nil, "anki_offline" end

    local inc_words, err = M.fetch_incremental_vocabulary(deck_name, days_back, front_field)
    if not inc_words then return nil, err end

    local added = 0
    for w, _ in pairs(inc_words) do
        if not known_words[w] then
            known_words[w] = true
            added = added + 1
        end
    end

    M.save_last_sync_date(meta_path)
    if added > 0 then M.save_cache(cache_path, known_words) end
    if senses_path then M.save_senses_cache(senses_path, M.known_senses) end
    return added, nil
end

return M
