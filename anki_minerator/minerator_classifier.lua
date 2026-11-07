-- minerator_classifier.lua
-- Classificação de termos e geração de string formatada em ASS para o mpv

local cleaner = require("minerator_cleaner")
local stopwords = require("minerator_stopwords")

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

-- Gera a linha da legenda com formatação ASS e cores palavra por palavra
function M.format_ass_line(cleaned_text, font_size)
    if not cleaned_text or cleaned_text == "" then
        return ""
    end

    local size = font_size or 28
    local prefix = string.format("{\\an2\\fs%d\\b1\\bord2.5\\3c&H000000&\\shad1\\4c&H000000&}", size)
    local parts = {}
    local pos = 1
    local total_len = #cleaned_text

    while pos <= total_len do
        local w_start, w_end = cleaned_text:find("[%w']+", pos)
        if not w_start then
            local rest = cleaned_text:sub(pos)
            table.insert(parts, string.format("{\\1c%s}%s", M.colors.neutral, rest))
            break
        end

        if w_start > pos then
            local punct = cleaned_text:sub(pos, w_start - 1)
            table.insert(parts, string.format("{\\1c%s}%s", M.colors.neutral, punct))
        end

        local word = cleaned_text:sub(w_start, w_end)
        local color = M.classify_word(word)
        table.insert(parts, string.format("{\\1c%s}%s", color, word))
        pos = w_end + 1
    end

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
