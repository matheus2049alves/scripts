-- minerator_classifier.lua
-- Classificação de termos e geração de string formatada em ASS para o mpv

local cleaner = require("minerator_cleaner")
local stopwords = require("minerator_stopwords")
local matcher = require("minerator_matcher")
local utils = require("mp.utils")

local M = {}

M.known_words = {}    -- Verde: presente em alguma frente do deck
M.manual_known = {}   -- Âmbar: lista "já sabia"
M.postponed = {}      -- Cinza: adiados nesta sessão

-- Cores padrão em formato ASS (BGR: &HBBGGRR&)
M.colors = {
    new = "&H4444EF&",       -- Vermelho (#ef4444)
    known = "&H7FFF00&",     -- Verde (rgb 0, 255, 127)
    manual = "&H0B9EF5&",    -- Âmbar / Laranja (#f59e0b)
    postponed = "&HAFA39C&", -- Cinza (#9ca3af)
    neutral = "&HFFFFFF&"    -- Branco / Neutro
}

-- Classifica uma única palavra e devolve a cor ASS
function M.classify_word(raw_word)
    local norm = cleaner.normalize_word(raw_word)
    if norm == "" or norm:match("^%d+$") or stopwords.is_function_word(norm) then
        return M.colors.neutral, "neutral"
    end
    if M.postponed[norm] then
        return M.colors.postponed, "postponed"
    end
    if M.manual_known[norm] then
        return M.colors.manual, "manual_known"
    end
    if M.known_words[norm] then
        return M.colors.known, "known"
    end
    return M.colors.new, "new"
end

-- Determina a cor de uma expressão baseada no status atômico dela (espelhando AnkiMinerator)
local function classify_expression(expr, known_words, manual_known, postponed)
    local canonical = cleaner.normalize_item(expr.canonical or "")
    local matched = cleaner.normalize_item(expr.matchedText or "")

    if (canonical ~= "" and postponed and postponed[canonical]) or (matched ~= "" and postponed and postponed[matched]) then
        return M.colors.postponed
    end
    if (canonical ~= "" and manual_known and manual_known[canonical]) or (matched ~= "" and manual_known and manual_known[matched]) then
        return M.colors.manual
    end
    if (canonical ~= "" and known_words and known_words[canonical]) or (matched ~= "" and known_words and known_words[matched]) then
        return M.colors.known
    end
    return M.colors.new
end

-- Identifica os intervalos de caracteres das expressões presentes no texto
local function find_expression_ranges(cleaned_text, expressions, known_words, manual_known, postponed)
    local ranges = {}
    if not expressions or #expressions == 0 then return ranges end

    for _, expr in ipairs(expressions) do
        local s, e = expr.start_pos, expr.end_pos
        if not (s and e) then
            s, e = matcher.find_expression_in_text(cleaned_text, expr)
        end
        if s and e then
            local color = classify_expression(expr, known_words, manual_known, postponed)
            table.insert(ranges, { start_pos = s, end_pos = e, color = color })
        end
    end
    return ranges
end

-- Retorna a expressão ativa para a posição atual de caractere
local function get_active_range(pos, ranges)
    for _, r in ipairs(ranges) do
        if pos >= r.start_pos and pos <= r.end_pos then return r end
    end
    return nil
end

-- Gera a linha da legenda com formatação ASS, cores e sublinhado em expressões
function M.format_ass_line(cleaned_text, font_size, expressions)
    if not cleaned_text or cleaned_text == "" then return "" end

    local size = font_size or 28
    local prefix = string.format("{\\an2\\fs%d\\b1\\bord2.5\\3c&H000000&\\shad1\\4c&H000000&}", size)
    local ranges = find_expression_ranges(cleaned_text, expressions, M.known_words, M.manual_known, M.postponed)
    local parts, pos, total_len = {}, 1, #cleaned_text
    local in_underline = false

    while pos <= total_len do
        local w_start, w_end = cleaned_text:find("[%w']+", pos)
        if not w_start then
            if in_underline then table.insert(parts, "{\\u0}"); in_underline = false end
            table.insert(parts, string.format("{\\1c%s}%s", M.colors.neutral, cleaned_text:sub(pos)))
            break
        end

        if w_start > pos then
            local punct = cleaned_text:sub(pos, w_start - 1)
            local range = get_active_range(pos, ranges)
            if range and in_underline then
                table.insert(parts, punct)
            else
                if in_underline then table.insert(parts, "{\\u0}"); in_underline = false end
                table.insert(parts, string.format("{\\1c%s}%s", M.colors.neutral, punct))
            end
        end

        local word = cleaned_text:sub(w_start, w_end)
        local range = get_active_range(w_start, ranges)

        if range then
            if not in_underline then
                table.insert(parts, string.format("{\\1c%s\\u1}%s", range.color, word))
                in_underline = true
            else
                table.insert(parts, string.format("{\\1c%s}%s", range.color, word))
            end
            if w_end >= range.end_pos then
                table.insert(parts, "{\\u0}")
                in_underline = false
            end
        else
            if in_underline then table.insert(parts, "{\\u0}"); in_underline = false end
            local color = M.classify_word(word)
            table.insert(parts, string.format("{\\1c%s}%s", color, word))
        end

        pos = w_end + 1
    end

    if in_underline then table.insert(parts, "{\\u0}") end
    return prefix .. table.concat(parts, "")
end

-- Marca palavras da frase como "já sabia"
function M.mark_sentence_as_known(text)
    local words = cleaner.extract_words(text)
    for _, w in ipairs(words) do
        if not stopwords.is_function_word(w) then
            M.manual_known[w] = true
        end
    end
end

-- Marca um termo específico (palavra ou expressão) como "já sabia"
function M.mark_term_as_known(term)
    if not term or term == "" then return end
    local norm = cleaner.normalize_item(term)
    if norm ~= "" then M.manual_known[norm] = true end
    local words = cleaner.extract_words(term)
    for _, w in ipairs(words) do
        if not stopwords.is_function_word(w) then
            M.manual_known[w] = true
        end
    end
end

-- Salva a lista manual "já sabia" em arquivo JSON
function M.save_manual_cache(path)
    if not path or path == "" then return false end
    local list = {}
    for w, _ in pairs(M.manual_known) do
        table.insert(list, w)
    end
    local json_str = utils.format_json(list)
    if not json_str then return false end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(json_str)
    f:close()
    return true
end

-- Carrega a lista manual "já sabia" do arquivo JSON
function M.load_manual_cache(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if not f then return false end
    local content = f:read("*all")
    f:close()
    local list, err = utils.parse_json(content)
    if not list or type(list) ~= "table" then return false end
    for _, w in ipairs(list) do
        local norm = cleaner.normalize_word(w)
        if norm ~= "" then M.manual_known[norm] = true end
    end
    return true
end

-- Marca palavras da frase como "adiado"
function M.mark_sentence_as_postponed(text)
    local words = cleaner.extract_words(text)
    for _, w in ipairs(words) do
        if not stopwords.is_function_word(w) then
            M.postponed[w] = true
        end
    end
end

return M
