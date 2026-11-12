-- minerator_matcher.lua
-- Reconhecimento inteligente de expressões, phrasal verbs, tempos verbais e particípios

local M = {}

-- Partículas mais comuns de phrasal verbs em inglês
M.PARTICLES = {
    ["up"] = true, ["down"] = true, ["in"] = true, ["out"] = true,
    ["off"] = true, ["on"] = true, ["over"] = true, ["under"] = true,
    ["away"] = true, ["back"] = true, ["about"] = true, ["around"] = true,
    ["across"] = true, ["through"] = true, ["along"] = true, ["by"] = true,
    ["forward"] = true, ["ahead"] = true, ["apart"] = true, ["together"] = true,
    ["into"] = true, ["onto"] = true
}

-- Mapeamento de verbos irregulares comuns em phrasal verbs
M.IRREGULAR_FORMS = {
    ["go"] = { "goes", "went", "gone", "going" },
    ["get"] = { "gets", "got", "gotten", "getting" },
    ["give"] = { "gives", "gave", "given", "giving" },
    ["take"] = { "takes", "took", "taken", "taking" },
    ["make"] = { "makes", "made", "making" },
    ["come"] = { "comes", "came", "coming" },
    ["run"] = { "runs", "ran", "running" },
    ["put"] = { "puts", "putting" },
    ["set"] = { "sets", "setting" },
    ["bring"] = { "brings", "brought", "bringing" },
    ["stand"] = { "stands", "stood", "standing" },
    ["grow"] = { "grows", "grew", "grown", "growing" },
    ["break"] = { "breaks", "broke", "broken", "breaking" },
    ["keep"] = { "keeps", "kept", "keeping" },
    ["hold"] = { "holds", "held", "holding" },
    ["find"] = { "finds", "found", "finding" },
    ["fall"] = { "falls", "fell", "fallen", "falling" },
    ["cut"] = { "cuts", "cutting" },
    ["blow"] = { "blows", "blew", "blown", "blowing" },
    ["catch"] = { "catches", "caught", "catching" },
    ["hang"] = { "hangs", "hung", "hanging" },
    ["show"] = { "shows", "showed", "shown", "showing" },
    ["throw"] = { "throws", "threw", "thrown", "throwing" },
    ["wake"] = { "wakes", "woke", "woken", "waking" },
    ["write"] = { "writes", "wrote", "written", "writing" },
    ["speak"] = { "speaks", "spoke", "spoken", "speaking" },
    ["tear"] = { "tears", "tore", "torn", "tearing" },
    ["wear"] = { "wears", "wore", "worn", "wearing" },
    ["pay"] = { "pays", "paid", "paying" },
    ["send"] = { "sends", "sent", "sending" },
    ["leave"] = { "leaves", "left", "leaving" },
    ["tell"] = { "tells", "told", "telling" },
    ["build"] = { "builds", "built", "building" },
    ["stick"] = { "sticks", "stuck", "sticking" },
    ["shut"] = { "shuts", "shutting" },
    ["let"] = { "lets", "letting" },
    ["see"] = { "sees", "saw", "seen", "seeing" },
    ["hear"] = { "hears", "heard", "hearing" },
    ["feel"] = { "feels", "felt", "feeling" },
    ["drive"] = { "drives", "drove", "driven", "driving" },
    ["draw"] = { "draws", "drew", "drawn", "drawing" },
    ["shake"] = { "shakes", "shook", "shaken", "shaking" },
    ["lead"] = { "leads", "led", "leading" },
    ["light"] = { "lights", "lit", "lighted", "lighting" }
}

M.REVERSE_IRREGULAR = {}
for base, forms in pairs(M.IRREGULAR_FORMS) do
    for _, form in ipairs(forms) do
        M.REVERSE_IRREGULAR[form] = base
    end
end

-- Gera lista de flexões temporais de um verbo (regular ou irregular)
function M.get_verb_forms(verb)
    if not verb or verb == "" then return {} end
    local v = verb:lower()
    local set = { [v] = true }

    if M.IRREGULAR_FORMS[v] then
        for _, f in ipairs(M.IRREGULAR_FORMS[v]) do set[f] = true end
    elseif M.REVERSE_IRREGULAR[v] then
        local base = M.REVERSE_IRREGULAR[v]
        set[base] = true
        if M.IRREGULAR_FORMS[base] then
            for _, f in ipairs(M.IRREGULAR_FORMS[base]) do set[f] = true end
        end
    else
        -- Regras de derivação regular (passado, gerúndio, 3ª pessoa)
        if v:match("e$") then
            local stem = v:sub(1, -2)
            set[v .. "s"] = true; set[v .. "d"] = true; set[stem .. "ing"] = true
        elseif v:match("[^aeiou]y$") then
            local stem = v:sub(1, -2)
            set[stem .. "ies"] = true; set[stem .. "ied"] = true; set[v .. "ing"] = true
        elseif v:match("ed$") then
            local stem = v:sub(1, -3)
            set[stem] = true; set[stem .. "s"] = true; set[stem .. "ing"] = true
            set[stem .. "e"] = true; set[stem .. "es"] = true
        elseif v:match("ing$") then
            local stem = v:sub(1, -4)
            set[stem] = true; set[stem .. "s"] = true; set[stem .. "ed"] = true
            set[stem .. "e"] = true
        else
            set[v .. "s"] = true; set[v .. "es"] = true; set[v .. "ed"] = true; set[v .. "ing"] = true
            if v:match("[aeiou][b-df-hj-np-tv-z]$") and #v <= 5 then
                local last = v:sub(-1)
                set[v .. last .. "ed"] = true; set[v .. last .. "ing"] = true
            end
        end
    end

    local list = {}
    for f, _ in pairs(set) do table.insert(list, f) end
    return list
end

-- Busca flexão de phrasal verb na sentença (ex: "look up" casa com "looked up" ou "looked it up")
local function match_phrasal_verb(lower_text, text, words)
    local verb, particle = words[1], words[2]
    if not M.PARTICLES[particle] then return nil end

    local verb_forms = M.get_verb_forms(verb)
    local esc_part = particle:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")

    -- 1. Forma contígua flexionada (ex: looked up, looking up, looks up)
    for _, vform in ipairs(verb_forms) do
        local esc_v = vform:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        local s, e = lower_text:find("%f[%a]" .. esc_v .. "%s+" .. esc_part .. "%f[%A]")
        if s and e then return s, e, text:sub(s, e) end
    end

    -- 2. Forma separável com pronome/objeto curto no meio (ex: looked it up, turn them off)
    for _, vform in ipairs(verb_forms) do
        local esc_v = vform:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        local s, e = lower_text:find("%f[%a]" .. esc_v .. "%s+[%w']+%s+" .. esc_part .. "%f[%A]")
        if s and e then return s, e, text:sub(s, e) end
    end

    return nil
end

-- Localiza a ocorrência de uma expressão na linha da legenda
function M.find_expression_in_text(text, expr_or_str)
    if not text or text == "" or not expr_or_str then return nil end
    local lower_text = text:lower()

    local canonical, matched = "", ""
    if type(expr_or_str) == "table" then
        canonical = (expr_or_str.canonical or ""):lower():match("^%s*(.-)%s*$") or ""
        matched = (expr_or_str.matchedText or ""):lower():match("^%s*(.-)%s*$") or ""
    else
        canonical = tostring(expr_or_str):lower():match("^%s*(.-)%s*$") or ""
    end

    -- 1. Casamento exato por matchedText
    if matched ~= "" and #matched > 2 then
        local s, e = lower_text:find("%f[%a]" .. matched:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "%f[%A]")
        if s and e then return s, e, text:sub(s, e) end
    end

    -- 2. Casamento exato por canonical
    if canonical ~= "" and #canonical > 2 then
        local s, e = lower_text:find("%f[%a]" .. canonical:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "%f[%A]")
        if s and e then return s, e, text:sub(s, e) end
    end

    -- 3. Casamento flexionado de verbos
    local words = {}
    for w in canonical:gmatch("[%w']+") do table.insert(words, w) end
    if #words >= 2 then
        local s, e, m = match_phrasal_verb(lower_text, text, words)
        if s and e then return s, e, m end
    end

    return nil
end

-- Verifica se uma palavra faz parte da expressão (literal ou como flexão verbal)
function M.is_word_in_expression(word, expr_text)
    if not word or not expr_text then return false end
    local w = word:lower()
    local lower_expr = expr_text:lower()

    if lower_expr:find("%f[%a]" .. w .. "%f[%A]") then return true end

    for token in lower_expr:gmatch("[%w']+") do
        local forms = M.get_verb_forms(token)
        for _, f in ipairs(forms) do
            if f == w then return true end
        end
    end
    return false
end

return M

