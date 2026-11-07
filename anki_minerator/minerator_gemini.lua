-- minerator_gemini.lua
-- Gerador do verso de cartões em inglês com Google Gemini API
-- Segue estritamente as regras de prompt e formato do AnkiMinerator

local utils = require("mp.utils")

local M = {}

M.default_model = "gemini-3.5-flash-lite"
M.fallback_models = { "gemini-3.5-flash-lite", "gemini-3.5-flash", "gemini-flash-latest" }

-- Sanitiza chave de API removendo espaços e quebras de linha
function M.sanitize_api_key(raw_key)
    if not raw_key then return "" end
    return raw_key:gsub("[%s\r\n]", "")
end

-- Obtém a chave configurada, da variável de ambiente ou do Registro do Windows
function M.resolve_api_key(configured_key)
    local key = M.sanitize_api_key(configured_key)
    if key ~= "" then
        return key
    end

    -- 1. Variável de ambiente do processo
    local env_key = os.getenv("GEMINI_API_KEY")
    key = M.sanitize_api_key(env_key)
    if key ~= "" then
        return key
    end

    -- 2. Variável de ambiente do usuário no Windows (HKCU/Environment)
    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = {
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "[System.Environment]::GetEnvironmentVariable('GEMINI_API_KEY', 'User')"
        }
    })
    if res.status == 0 and res.stdout and res.stdout ~= "" then
        key = M.sanitize_api_key(res.stdout)
        if key ~= "" then
            return key
        end
    end

    return ""
end

-- Salva log de diagnóstico da última requisição para inspeção
local function save_debug_log(payload_str, response_str, error_info)
    local script_dir = mp.get_script_directory() or "c:/mpv/portable_config/scripts/anki_minerator"
    local debug_path = utils.join_path(script_dir, "gemini_last_response.json")
    local f = io.open(debug_path, "w")
    if not f then return end

    local log_data = {
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        payload = payload_str,
        raw_response = response_str,
        error = error_info
    }
    local formatted = utils.format_json(log_data)
    f:write(formatted or tostring(response_str))
    f:close()
end

-- Formata o texto plano da IA com HTML legível para o Anki
function M.format_back_html(raw_text, source_title, time_formatted)
    if not raw_text or raw_text == "" then
        return ""
    end

    local lines = {}
    for line in raw_text:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$") or ""
        if trimmed ~= "" then
            local formatted = trimmed:gsub("^(IPA:)", "<b>%1</b>")
            formatted = formatted:gsub("^(Meaning:)", "<b>%1</b>")
            formatted = formatted:gsub("^(Synonyms:)", "<b>%1</b>")
            formatted = formatted:gsub("^(Expression Breakdown:)", "<b>%1</b>")
            formatted = formatted:gsub("^(Sentence:)", "<b>%1</b>")
            formatted = formatted:gsub("^(• Meaning in Context:)", "<b>%1</b>")
            formatted = formatted:gsub("^(• Nuance.-:)", "<b>%1</b>")
            formatted = formatted:gsub("^(• Cultural.-:)", "<b>%1</b>")
            formatted = formatted:gsub("^(• Other.-:)", "<b>%1</b>")
            table.insert(lines, formatted)
        end
    end

    local body_html = table.concat(lines, "<br>")
    local footer = ""
    if source_title then
        footer = string.format('<br><br><small style="color: #6b7280;">Source: %s @ %s</small>', source_title, time_formatted or "00:00")
    end

    return string.format('<div style="text-align: left; line-height: 1.6; font-size: 16px;">%s%s</div>', body_html, footer)
end

-- Gera o template em branco de fallback
function M.get_blank_template(expression, sentence, source_title, time_formatted)
    local t = string.format([[<div style="text-align: left; line-height: 1.6; font-size: 16px;">
<b>%s</b><br>
<b>IPA:</b> /.../<br>
<b>Meaning:</b> [Enter definition]<br>
<b>Synonyms:</b> [Enter synonyms]<br><br>
<b>Expression Breakdown:</b><br>
<b>Sentence:</b> "%s"<br>
• <b>Meaning in Context:</b> <br>
• <b>Nuance (Tone & Register):</b> <br>
• <b>Cultural Implications:</b> <br>
• <b>Other Idioms / Phrasal Verbs in Sentence:</b> None<br><br>
<small style="color: #6b7280;">Source: %s @ %s</small>
</div>]], expression, sentence, source_title or "Local Video", time_formatted or "00:00")
    return t
end

-- Executa a requisição curl usando arquivo temporário para evitar quebra de aspas no Windows
local function execute_gemini_request(model, api_key, json_payload)
    local temp_dir = os.getenv("TEMP") or "C:\\Windows\\Temp"
    local temp_json = utils.join_path(temp_dir, string.format("minerator_payload_%d.json", os.time()))

    local f = io.open(temp_json, "w")
    if not f then
        return nil, "Nao foi possivel criar arquivo temporario para payload"
    end
    f:write(json_payload)
    f:close()

    local url = string.format("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s", model, api_key)

    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = {
            "curl.exe",
            "-s",
            "--max-time", "15",
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "--data-binary", "@" .. temp_json,
            url
        }
    })

    os.remove(temp_json)

    if res.status ~= 0 or not res.stdout or res.stdout == "" then
        local err_str = res.stderr or res.error_string or "Sem resposta"
        return nil, "Falha de conexao: " .. err_str
    end

    return res.stdout, nil
end

-- Chama a API do Gemini com fallback automático de modelos em caso de 503/404
function M.generate_card_back(expression, sentence, api_key, preferred_model)
    local clean_key = M.resolve_api_key(api_key)
    if clean_key == "" then
        return nil, "Chave Gemini vazia (adicione no anki_minerator.conf ou no GEMINI_API_KEY)"
    end

    local prompt = string.format([[You are an expert English lexicographer creating high-yield Anki flashcards for an advanced learner.
Create the back of an Anki flashcard for the following expression in context.

Target Expression: "%s"
Original Sentence: "%s"

STRICT NORMATIVE REQUIREMENTS:
1. STRICTLY MONOLINGUAL IN ENGLISH. DO NOT write or translate anything to Portuguese.
2. OUTPUT CLEAN HUMAN-READABLE PLAIN TEXT ONLY. DO NOT use any HTML tags (NO <div>, <p>, <strong>, <b>, <ul>, <li>).
3. Format with natural line breaks and the exact 5 sections:
%s
IPA: /phonetic_transcription/
Meaning: clear definition in English
Synonyms: comma-separated list of synonyms

Expression Breakdown:
• Meaning in Context: exact meaning in this specific sentence
• Nuance (Tone & Register): e.g., informal, colloquial, formal, literary
• Cultural Implications & Context: origins, real-world usage
• Other Idioms / Phrasal Verbs in Sentence: note any others present or "None"
4. Do NOT wrap in markdown backticks (```). Return plain text directly.]], expression, sentence, expression)

    local payload = {
        contents = { { parts = { { text = prompt } } } },
        generationConfig = { temperature = 0.2, maxOutputTokens = 1024 }
    }
    local json_body = utils.format_json(payload)

    -- Lista de modelos a tentar em ordem (preferido primeiro)
    local models_to_try = {}
    if preferred_model and preferred_model ~= "" then
        table.insert(models_to_try, preferred_model)
    end
    for _, m in ipairs(M.fallback_models) do
        if m ~= preferred_model then
            table.insert(models_to_try, m)
        end
    end

    local last_error = nil

    for _, model in ipairs(models_to_try) do
        local raw_out, req_err = execute_gemini_request(model, clean_key, json_body)
        if not raw_out then
            last_error = req_err
        else
            local data, parse_err = utils.parse_json(raw_out)
            if data and data.candidates and #data.candidates > 0 then
                local parts = data.candidates[1].content and data.candidates[1].content.parts
                if parts and #parts > 0 and parts[1].text then
                    save_debug_log(json_body, raw_out, nil)
                    local txt = parts[1].text:gsub("^```[a-z]*\r?\n", ""):gsub("\r?\n```$", "")
                    return txt, nil
                end
            end

            -- Se houve erro na API (ex: 503 ou 404), salva log e tenta o próximo modelo
            if data and data.error then
                local err_code = data.error.code or 400
                local err_msg = data.error.message or "Erro desconhecido"
                last_error = string.format("Gemini %d (%s): %s", err_code, model, err_msg)
                save_debug_log(json_body, raw_out, last_error)
            else
                last_error = parse_err or "Resposta sem conteudo"
                save_debug_log(json_body, raw_out, last_error)
            end
        end
    end

    return nil, last_error or "Nenhum modelo Gemini respondeu com sucesso"
end

return M
