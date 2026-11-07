-- minerator_analyzer.lua
-- Analisador prévio de expressões e phrasal verbs na legenda com IA Gemini
-- Baseado no expressionDetector do AnkiMinerator com suporte a legendas embutidas

local utils = require("mp.utils")
local gemini = require("minerator_gemini")
local cleaner = require("minerator_cleaner")

local M = {}

M.active_expressions = {}
M.is_analyzing = false
M.ffmpeg_path = ""

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

-- Localiza o executável FFmpeg para extração de trilhas de texto
function M.find_ffmpeg()
    if M.ffmpeg_path and M.ffmpeg_path ~= "" then
        local f = io.open(M.ffmpeg_path, "r")
        if f then f:close(); return M.ffmpeg_path end
    end
    local local_mpv_ffmpeg = "C:\\mpv\\ffmpeg.exe"
    local f_mpv = io.open(local_mpv_ffmpeg, "r")
    if f_mpv then f_mpv:close(); return local_mpv_ffmpeg end

    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = { "ffmpeg.exe", "-version" }
    })
    if res.status == 0 then return "ffmpeg.exe" end
    return nil
end

-- Obtém o índice relativo da trilha de legenda selecionada no contêiner
function M.get_selected_sub_index()
    local tracks = mp.get_property_native("track-list") or {}
    local sub_counter = 0
    local target_idx = 0
    for _, track in ipairs(tracks) do
        if track.type == "sub" then
            if track.selected then target_idx = sub_counter break end
            sub_counter = sub_counter + 1
        end
    end
    return target_idx
end

-- Extrai a trilha de legenda de texto embutida no MKV/MP4 para um arquivo temporário
function M.extract_embedded_sub(video_path)
    local ffmpeg_bin = M.find_ffmpeg()
    if not ffmpeg_bin then return nil, "ffmpeg_missing" end

    local sub_idx = M.get_selected_sub_index()
    local temp_dir = os.getenv("TEMP") or "C:\\Windows\\Temp"
    local temp_srt = utils.join_path(temp_dir, string.format("minerator_extracted_%d.srt", os.time()))

    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = { ffmpeg_bin, "-y", "-i", video_path, "-map", "0:s:" .. tostring(sub_idx), "-c:s", "srt", temp_srt }
    })

    if res.status ~= 0 then
        return nil, "Falha na extracao da trilha com FFmpeg: " .. tostring(res.stderr or res.error_string)
    end

    local f = io.open(temp_srt, "r")
    if f then
        local content = f:read("*all")
        f:close()
        if content and #content > 20 then return temp_srt, nil end
    end
    return nil, "A trilha extraida esta vazia (pode ser legenda de imagem PGS/VobSub)"
end

-- Localiza a legenda ativa (externa ou extrai da embutida)
function M.find_subtitle_source(video_path)
    local tracks = mp.get_property_native("track-list") or {}
    for _, track in ipairs(tracks) do
        if track.type == "sub" and track["external-filename"] then
            local f = io.open(track["external-filename"], "r")
            if f then f:close(); return track["external-filename"] end
        end
    end
    if video_path then
        local base = video_path:gsub("%.[^.]+$", "")
        for _, ext in ipairs({ ".srt", ".en.srt", ".eng.srt", ".default.srt", ".pt.srt", ".vtt" }) do
            local cand = base .. ext
            local f = io.open(cand, "r")
            if f then f:close(); return cand end
        end
    end
    for _, track in ipairs(tracks) do
        if track.type == "sub" and not track["external-filename"] then
            local extracted, err = M.extract_embedded_sub(video_path)
            if extracted then return extracted, nil end
            return nil, err
        end
    end
    return nil, "not_found"
end

-- Lê todas as falas de um arquivo de legenda SRT ou VTT
function M.read_subtitles_from_file(srt_path)
    local f = io.open(srt_path, "r")
    if not f then return {} end
    local cues = {}

    for line in f:lines() do
        if not line:match("^%d+$") and not line:match("%-%->") and not line:match("^WEBVTT") and line:match("%S") then
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

local function build_batch_prompt(lines_chunk)
    local formatted = {}
    for i, line in ipairs(lines_chunk) do table.insert(formatted, string.format("[%d] %s", i, line)) end
    return string.format([[You are an expert English linguist specialized in Second Language Acquisition (SLA).
Analyze the transcript lines and identify Phrasal Verbs (e.g. "figure out"), Idioms (e.g. "at the end of the day"), and Collocations (e.g. "go high").
Lines:
%s
OUTPUT: Return ONLY a valid JSON array of objects (no markdown, no explanation).
Format: [{"canonical": "base form", "matchedText": "verbatim text in line", "type": "phrasal_verb|idiom|collocation", "line": 1}]. No single words.]], table.concat(formatted, "\n"))
end

local function save_analyzer_log(payload_str, response_str, err_msg)
    local script_dir = mp.get_script_directory() or "c:/mpv/portable_config/scripts/anki_minerator"
    local debug_path = utils.join_path(script_dir, "gemini_last_response.json")
    local f = io.open(debug_path, "w")
    if not f then return end
    f:write(utils.format_json({ action = "expression_analyzer", timestamp = os.date("%Y-%m-%d %H:%M:%S"), payload = payload_str, raw_response = response_str, error = err_msg }) or tostring(response_str))
    f:close()
end

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
    if not f then return nil, "Falha ao criar arquivo de payload temporario" end
    f:write(json_body); f:close()

    local models_to_try = { model_name or "gemini-3.5-flash-lite", "gemini-3.5-flash", "gemini-flash-latest" }
    local last_err = nil

    for _, mod in ipairs(models_to_try) do
        local url = string.format("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s", mod, api_key)
        local res = mp.command_native({
            name = "subprocess",
            playback_only = false,
            capture_stdout = true,
            capture_stderr = true,
            args = { "curl.exe", "-s", "--max-time", "20", "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "@" .. temp_json, url }
        })

        if res.status == 0 and res.stdout and res.stdout ~= "" then
            local data = utils.parse_json(res.stdout)
            if data and data.candidates and #data.candidates > 0 then
                local text = data.candidates[1].content and data.candidates[1].content.parts and data.candidates[1].content.parts[1].text
                if text then
                    os.remove(temp_json)
                    save_analyzer_log(json_body, res.stdout, nil)
                    local clean_json = text:gsub("^```[a-z]*\r?\n", ""):gsub("\r?\n```$", "")
                    return utils.parse_json(clean_json) or {}, nil
                end
            end
            if data and data.error then
                last_err = string.format("Gemini %s: %s", tostring(data.error.code), tostring(data.error.message))
                save_analyzer_log(json_body, res.stdout, last_err)
            end
        else
            last_err = res.stderr or "Sem resposta de rede"
        end
    end

    os.remove(temp_json)
    return nil, last_err or "Falha em todos os modelos"
end

-- Varre a legenda do vídeo atual com IA em lotes
function M.analyze_video_subtitles(video_path, srt_path, api_key, model_name, on_progress, on_complete)
    if M.is_analyzing then return false, "Analise ja em andamento" end
    local resolved_key = gemini.resolve_api_key(api_key)
    if resolved_key == "" then return false, "Chave Gemini ausente" end

    local target_srt, err_type = (srt_path and srt_path ~= "") and srt_path or M.find_subtitle_source(video_path)
    if not target_srt then
        if err_type == "ffmpeg_missing" then return false, "Legenda embutida, mas FFmpeg nao encontrado!" end
        return false, err_type or "Nenhum arquivo de legenda encontrado"
    end

    local cues = M.read_subtitles_from_file(target_srt)
    if #cues == 0 then return false, "Nenhuma linha legivel encontrada na legenda: " .. tostring(target_srt) end

    M.is_analyzing = true
    local chunk_size = 50
    local total_chunks = math.ceil(#cues / chunk_size)
    local all_detected = {}
    local error_count = 0

    for chunk_idx = 1, total_chunks do
        local chunk = {}
        local start_i = (chunk_idx - 1) * chunk_size + 1
        local end_i = math.min(chunk_idx * chunk_size, #cues)
        for i = start_i, end_i do table.insert(chunk, cues[i]) end

        if on_progress then on_progress(chunk_idx, total_chunks, #all_detected) end

        local detected, chunk_err = analyze_chunk(chunk, resolved_key, model_name)
        if detected then
            for _, item in ipairs(detected) do table.insert(all_detected, item) end
        else
            error_count = error_count + 1
        end
    end

    M.active_expressions = all_detected
    M.save_cached_expressions(video_path, all_detected)
    M.is_analyzing = false

    if on_complete then on_complete(#all_detected, error_count) end
    return true, nil
end

function M.find_expressions_in_sentence(sentence)
    local found = {}
    if not sentence or not M.active_expressions or #M.active_expressions == 0 then return found end
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
