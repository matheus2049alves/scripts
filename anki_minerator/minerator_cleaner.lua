-- minerator_cleaner.lua
-- Limpeza de legendas conforme regras normativas do AnkiMinerator

local M = {}

-- 1. Remove tags HTML e de formatação/posicionamento
function M.remove_html_and_tags(text)
    if not text then return "" end
    local clean = text:gsub("<[^>]+>", "")
    clean = clean:gsub("%{[^}]+%}", "")
    clean = clean:gsub("&nbsp;", " ")
    clean = clean:gsub("&amp;", "&")
    clean = clean:gsub("&quot;", '"')
    clean = clean:gsub("&#39;", "'")
    return clean
end

-- 2. Remove efeitos sonoros entre colchetes ou parênteses em maiúsculas
function M.remove_bracketed_sounds(text)
    if not text then return "" end
    local clean = text:gsub("%[[^%]]*%]", " ")
    clean = clean:gsub("%([%u%s]+%)", " ")
    return clean
end

-- 3. Remove nomes de falantes no início da linha (ex: "JOHN:", ">>")
function M.remove_speaker_names(text)
    if not text then return "" end
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do
        local l = line:gsub("^%s*>>%s*", "")
        -- Em Lua usamos padrão com + (sem {2,20})
        l = l:gsub("^%s*[%w_%- ]+:%s*", "")
        table.insert(lines, l)
    end
    local combined = table.concat(lines, " ")
    combined = combined:gsub("%s*>>%s*", " ")
    return combined
end

-- 4. Ajusta espaçamentos e pontuações
function M.adjust_spacing(text)
    if not text then return "" end
    local clean = text:gsub("[\r\n]+", " ")
    clean = clean:gsub("%s+", " ")
    -- Remove espaço antes de pontuações
    clean = clean:gsub("%s+([,.:;?!])", "%1")
    -- Ajusta contrações com espaços (ex: don ' t -> don't, it ' s -> it's)
    clean = clean:gsub("(%w)%s+['’]%s+(%w)", "%1'%2")
    return clean:match("^%s*(.-)%s*$") or ""
end

-- Função principal de limpeza de legenda
function M.clean_cue_text(raw_text)
    if not raw_text or raw_text == "" then
        return ""
    end
    local t = M.remove_html_and_tags(raw_text)
    t = M.remove_bracketed_sounds(t)
    t = M.remove_speaker_names(t)
    t = M.adjust_spacing(t)
    return t
end

-- Normaliza uma palavra para comparação no vocabulário
-- Regra AnkiMinerator: minúsculas, remove pontuação exceto apóstrofo
function M.normalize_word(raw_word)
    if not raw_word then return "" end
    local lower = string.lower(raw_word)
    local normalized = lower:gsub("[^a-z0-9']", "")
    return normalized:match("^%s*(.-)%s*$") or ""
end

-- Extrai lista de palavras normalizadas de um texto
function M.extract_words(text)
    local words = {}
    if not text then return words end
    for w in text:gmatch("[%w']+" ) do
        local norm = M.normalize_word(w)
        if norm ~= "" and not norm:match("^%d+$") then
            table.insert(words, norm)
        end
    end
    return words
end

return M
