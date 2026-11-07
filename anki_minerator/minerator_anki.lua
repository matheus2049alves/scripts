-- minerator_anki.lua
-- Comunicação com AnkiConnect via curl no mpv (Windows)

local utils = require("mp.utils")
local cleaner = require("minerator_cleaner")

local M = {}

M.anki_url = "http://127.0.0.1:8765"

-- Executa uma requisição síncrona ao AnkiConnect via curl
function M.request(action, params)
    local payload = {
        action = action,
        version = 6,
        params = params or {}
    }
    local json_str = utils.format_json(payload)
    if not json_str then
        return nil, "Falha ao serializar JSON para AnkiConnect"
    end

    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "curl.exe",
            "-s",
            "--max-time", "5",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-d", json_str,
            M.anki_url
        }
    })

    if res.status ~= 0 or not res.stdout or res.stdout == "" then
        return nil, "AnkiConnect inacessivel em " .. M.anki_url
    end

    local data, parse_err = utils.parse_json(res.stdout)
    if parse_err or not data then
        return nil, "Resposta invalida do AnkiConnect: " .. tostring(parse_err)
    end

    if data.error then
        return nil, tostring(data.error)
    end

    return data.result, nil
end

-- Verifica se o AnkiConnect está respondendo
function M.check_status()
    local version, err = M.request("version")
    if err or not version then
        return false, err or "Desconectado"
    end
    return true, "AnkiConnect v" .. tostring(version)
end

-- Obtém lista de nomes dos campos do modelo
function M.get_model_fields(model_name)
    local fields, err = M.request("modelFieldNames", { modelName = model_name })
    if err or not fields then
        return { "Front", "Back" }
    end
    return fields
end

-- Envia arquivo de mídia para a collection.media do Anki usando caminho local
function M.store_media(filename, local_file_path)
    return M.request("storeMediaFile", {
        filename = filename,
        path = local_file_path
    })
end

-- Adiciona um cartão novo ao Anki
function M.add_card(deck_name, model_name, fields_table, tags_table)
    local note_params = {
        deckName = deck_name,
        modelName = model_name,
        fields = fields_table,
        tags = tags_table or { "anki-minerator", "mpv-mining" },
        options = {
            allowDuplicate = false,
            duplicateScope = "deck"
        }
    }
    return M.request("addNote", { note = note_params })
end

-- Extrai palavras de um conjunto de notas do Anki
local function extract_words_from_notes(notes, known_words)
    local count = 0
    for _, note in ipairs(notes) do
        local fields = note.fields or {}
        -- Procura campo de frente (Front, Frente, etc.) ou pega o primeiro
        local front_val = fields.Front and fields.Front.value
            or fields.Frente and fields.Frente.value
        if not front_val then
            for _, f_data in pairs(fields) do
                front_val = f_data.value
                break
            end
        end

        if front_val and front_val ~= "" then
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

-- Sincroniza todo o vocabulário das frentes de um deck via AnkiConnect
function M.fetch_deck_vocabulary(deck_name)
    local query = 'deck:"' .. deck_name .. '"'
    local note_ids, err = M.request("findNotes", { query = query })
    if err or not note_ids then
        return nil, err or "Nenhuma nota encontrada"
    end

    local known_words = {}
    local batch_size = 500
    local total_notes = #note_ids

    for i = 1, total_notes, batch_size do
        local batch = {}
        for j = i, math.min(i + batch_size - 1, total_notes) do
            table.insert(batch, note_ids[j])
        end
        local notes_info, info_err = M.request("notesInfo", { notes = batch })
        if notes_info then
            extract_words_from_notes(notes_info, known_words)
        end
    end

    return known_words, nil
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
    for w, _ in pairs(known_words) do
        table.insert(word_list, w)
    end
    local json_str = utils.format_json(word_list)
    if not json_str then return false end

    local f = io.open(cache_path, "w")
    if not f then return false end
    f:write(json_str)
    f:close()
    return true
end

-- Carrega o vocabulário do cache JSON local
function M.load_cache(cache_path)
    local f = io.open(cache_path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()

    local list, err = utils.parse_json(content)
    if not list or type(list) ~= "table" then return nil end

    local known_words = {}
    for _, w in ipairs(list) do
        known_words[w] = true
    end
    return known_words
end

return M
