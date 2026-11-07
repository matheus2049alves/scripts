-- minerator_analyzer.lua
-- Analisador prévio de expressões e phrasal verbs na legenda com IA Gemini
-- Baseado no expressionDetector do AnkiMinerator

local utils = require("mp.utils")
local gemini = require("minerator_gemini")
local cleaner = require("minerator_cleaner")

local M = {}

M.active_expressions = {} -- Mapa de expressões por texto/frase
M.is_analyzing = false

-- Gera o caminho do arquivo de cache de expressões para o vídeo atual
function M.get_cache_filepath(video_path)
    if not video_path then return nil end
    local clean_path = video_path:gsub("%.[^.]+$", "")
    return clean_path .. "_expressions.json"
end

-- Carrega o cache de expressões previamente analisadas para este vídeo
function M.load_cached_expressions(video_path)
    local cache_file = M.get_cache_filepath(video_path)
    if not cache_file then return {} end

    local f = io.open(cache_file, "r")
    if not f then return {} end
    local content = f:read("*all")
    f:close()

    local data = utils.parse_json(content)
    if data and type(data) == "table" then
        M.active_expressions = data
        return data
    end
    return {}
end

-- Salva as expressões detectadas no cache do vídeo
function M.save_cached_expressions(video_path, expressions_list)
    local cache_file = M.get_cache_filepath(video_path)
    if not cache_file or not expressions_list then return false end

    local f = io.open(cache_file, "w")
    if not f then return false end
    local json_str = utils.format_json(expressions_list)
    f:write(json_str or "[]")
    f:close()
    return true
end

-- Monta o prompt de detecção em lote conforme especificação do AnkiMinerator
local function build_batch_prompt(lines_chunk)
    local formatted = {}
    for i, line in ipairs(lines_chunk) do
        table.insert(formatted, string.format("[%d] %s", i, line))
    end

    return string.format([[You are an expert English linguist specialized in Second Language Acquisition (SLA).
Analyze the following numbered transcript lines and identify all Phrasal Verbs (including separable forms like "figure it out", "wear out"), Idioms (e.g. "at the end of the day", "make sense"), and high-value Collocations (e.g. "prior to", "go high").

Lines to analyze:
%s

OUTPUT INSTRUCTIONS:
1. Return ONLY a valid JSON array of objects, with no markdown code blocks (```json) and no explanation.
2. Each object must have:
   - "canonical": canonical base form (e.g. "go high", "figure out", "day off")
   - "matchedText": EXACT verbatim phrase as it appears in the line
   - "type": "phrasal_verb" or "idiom" or "collocation"
   - "line": integer index of the line
3. Do NOT include single words. Only multi-word expressions.]], table.concat(formatted, "\n"))
end

-- Executa a requisição de detecção para um lote de falas
local function analyze_chunk(lines_chunk, api_key, model_name)
    local prompt = build_batch_prompt(lines_chunk)
    local payload = {
        contents = { { parts = { { text = prompt } } } },
        generationConfig = { temperature = 0.1, responseMimeType = "application/json" }
    }
    local json_body = utils.format_json(payload)

    local temp_dir = os.getenv("TEMP") or "C:\\Windows\\Temp"
    local temp_json = utils.join_path(temp_dir, string.format("minerator_chunk_%d.json", os.time()))
    local f = io.open(temp_json, "w")
    if not f then return {} end
    f:write(json_body)
    f:close()

    local url = string.format("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s", model_name or "gemini-3.5-flash-lite", api_key)
    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = { "curl.exe", "-s", "--max-time", "20", "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "@" .. temp_json, url }
    })
    os.remove(temp_json)

    if res.status ~= 0 or not res.stdout or res.stdout == "" then return {} end

    local data = utils.parse_json(res.stdout)
    if not data or not data.candidates or #data.candidates == 0 then return {} end

    local text = data.candidates[1].content and data.candidates[1].content.parts and data.candidates[1].content.parts[1].text
    if not text then return {} end

    local clean_json = text:gsub("^```[a-z]*\r?\n", ""):gsub("\r?\n```$", "")
    local list = utils.parse_json(clean_json)
    if list and type(list) == "table" then return list end
    return {}
end

-- Lê todas as falas de um arquivo de legenda SRT
function M.read_srt_subtitles(srt_path)
    local f = io.open(srt_path, "r")
    if not f then return {} end
    local cues = {}

    for line in f:lines() do
        -- Ignora números de índice e timestamps
        if not line:match("^%d+$") and not line:match("%-%->") and line:match("%S") then
            local clean = cleaner.clean_cue_text(line)
            if clean ~= "" and #clean > 3 and not cues[clean] then
                cues[clean] = true
                table.insert(cues, clean)
            end
        end
    end
    f:close()
    return cues
end

-- Varre a legenda do vídeo atual com IA em segundo plano
function M.analyze_video_subtitles(video_path, srt_path, api_key, model_name, on_progress, on_complete)
    if M.is_analyzing then return false, "Analise ja em andamento" end
    M.is_analyzing = true

    local resolved_key = gemini.resolve_api_key(api_key)
    if resolved_key == "" then
        M.is_analyzing = false
        return false, "Chave Gemini ausente"
    end

    -- Determina o arquivo SRT
    local target_srt = srt_path
    if not target_srt or target_srt == "" then
        local guess_srt = video_path:gsub("%.[^.]+$", ".srt")
        local f = io.open(guess_srt, "r")
        if f then f:close(); target_srt = guess_srt end
    end

    if not target_srt then
        M.is_analyzing = false
        return false, "Nenhum arquivo de legenda .srt encontrado ao lado do video"
    end

    local cues = M.read_srt_subtitles(target_srt)
    if #cues == 0 then
        M.is_analyzing = false
        return false, "Nenhuma fala legivel no arquivo .srt"
    end

    local chunk_size = 50
    local total_chunks = math.ceil(#cues / chunk_size)
    local all_detected = {}

    for chunk_idx = 1, total_chunks do
        local chunk = {}
        local start_i = (chunk_idx - 1) * chunk_size + 1
        local end_i = math.min(chunk_idx * chunk_size, #cues)
        for i = start_i, end_i do table.insert(chunk, cues[i]) end

        if on_progress then on_progress(chunk_idx, total_chunks) end

        local detected = analyze_chunk(chunk, resolved_key, model_name)
        for _, item in ipairs(detected) do
            table.insert(all_detected, item)
        end
    end

    M.active_expressions = all_detected
    M.save_cached_expressions(video_path, all_detected)
    M.is_analyzing = false

    if on_complete then on_complete(#all_detected) end
    return true, nil
end

-- Encontra expressões detectadas para a frase atual
function M.find_expressions_in_sentence(sentence)
    local found = {}
    if not sentence or not M.active_expressions or #M.active_expressions == 0 then
        return found
    end

    local lower_sentence = " " .. sentence:lower() .. " "
    local seen = {}

    for _, expr in ipairs(M.active_expressions) do
        local target = (expr.matchedText or expr.canonical or ""):lower():match("^%s*(.-)%s*$")
        if target and #target > 2 and not seen[target] then
            if lower_sentence:find("%f[%a]" .. target .. "%f[%A]") or lower_sentence:find(target, 1, true) then
                seen[target] = true
                table.insert(found, expr)
            end
        end
    end
    return found
end

return M

