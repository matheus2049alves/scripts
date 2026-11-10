-- minerator_selector.lua
-- Menu interativo OSD para seleção do termo específico a minerar

local cleaner = require("minerator_cleaner")
local stopwords = require("minerator_stopwords")

local M = {}

M.active = false
M.menu_overlay = mp.create_osd_overlay("ass-events")

-- Destaca a palavra ou expressão escolhida dentro da frase com tag HTML
function M.highlight_term(sentence, term, color)
    if not sentence or not term or term == "" or term == sentence or term == "Frase inteira" then
        return sentence
    end
    local highlight_color = color or "rgb(0, 255, 127)"
    local escaped_term = term:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    local pattern = "([%s%p]?)(" .. escaped_term .. ")([%s%p]?)"

    local replaced, count = sentence:gsub(pattern, function(pre, matched, post)
        return string.format('%s<span style="color: %s; font-weight: bold;">%s</span>%s', pre, highlight_color, matched, post)
    end, 1)

    if count > 0 then return replaced end
    return sentence .. string.format(' <span style="color: %s; font-weight: bold;">[%s]</span>', highlight_color, term)
end

-- Extrai todos os termos desconhecidos candidatos da frase de forma concisa
function M.extract_candidates(sentence, known_words, detected_expressions, mode)
    local candidates = {}
    local seen = {}
    local is_known_mode = (mode == "known")

    -- 1. Inclui expressões multi-palavra detectadas que não sejam totalmente conhecidas
    if detected_expressions then
        for _, expr in ipairs(detected_expressions) do
            local text = expr.matchedText or expr.canonical
            local norm = cleaner.normalize_item(text)
            local can_norm = cleaner.normalize_item(expr.canonical or "")
            local is_known = (norm ~= "" and known_words[norm]) or (can_norm ~= "" and known_words[can_norm])
            if norm ~= "" and not seen[norm] and not is_known then
                seen[norm] = true
                table.insert(candidates, {
                    text = text,
                    canonical = expr.canonical or text,
                    type = expr.type or "expression"
                })
            end
        end
    end

    -- 2. Inclui palavras simples que são novas (e não pertencem a expressões já listadas)
    local words = cleaner.extract_words(sentence)
    for _, w in ipairs(words) do
        if not stopwords.is_function_word(w) and not known_words[w] and not seen[w] then
            local in_expression = false
            for _, expr in ipairs(candidates) do
                if expr.type ~= "sentence" and expr.type ~= "all" and expr.canonical:lower():find("%f[%a]" .. w .. "%f[%A]") then
                    in_expression = true
                    break
                end
            end

            if not in_expression then
                seen[w] = true
                table.insert(candidates, {
                    text = w,
                    canonical = w,
                    type = "word"
                })
            end
        end
    end

    -- 3. Adiciona a opção de lote (todas as palavras no modo known ou frase inteira no mining)
    if is_known_mode then
        table.insert(candidates, {
            text = "Todas as palavras da frase",
            canonical = sentence,
            type = "all"
        })
    else
        table.insert(candidates, {
            text = "Frase inteira",
            canonical = sentence,
            type = "sentence"
        })
    end

    return candidates
end

-- Desativa o menu OSD e remove os binds temporários
function M.close_menu()
    M.active = false
    M.menu_overlay:remove()
    for i = 1, 9 do
        mp.remove_key_binding("minerator-choice-" .. i)
    end
    mp.remove_key_binding("minerator-cancel-esc")
    mp.remove_key_binding("minerator-cancel-q")
end

-- Exibe o menu OSD e captura a tecla numérica do usuário
function M.open_menu(candidates, on_select, on_cancel, opts_menu)
    if M.active then M.close_menu() end
    M.active = true

    opts_menu = opts_menu or {}
    local border = opts_menu.border_color or "&H0B9EF5&"
    local cancel_col = opts_menu.cancel_color or "&H4444EF&"
    local title = opts_menu.title_text or "  {\\1c&H4444EF&}MINERAR NO ANKI{\\1c&HFFFFFF&} — Escolha a palavra ou expressao em foco:\\N"

    local lines = {
        "{\\an5\\fs22\\b1\\bord2\\3c&H000000&\\shad1\\1c&HFFFFFF&}",
        string.format("{\\1c%s}═══════════════════════════════════════════════{\\1c&HFFFFFF&}\\N", border),
        title,
        string.format("{\\1c%s}───────────────────────────────────────────────{\\1c&HFFFFFF&}\\N", border)
    }

    local max_items = math.min(#candidates, 9)
    for i = 1, max_items do
        local cand = candidates[i]
        local label = cand.text
        local tag = (cand.type == "word") and "{\\1c&H4444EF&}[Palavra]{\\1c&HFFFFFF&}"
            or (cand.type == "sentence") and "{\\1c&HAFA39C&}[Sentenca]{\\1c&HFFFFFF&}"
            or (cand.type == "all") and "{\\1c&H0B9EF5&}[Todas]{\\1c&HFFFFFF&}"
            or "{\\1c&H0B9EF5&}[Expressao]{\\1c&HFFFFFF&}"

        table.insert(lines, string.format("   {\\1c&H7FFF00&}[%d]{\\1c&HFFFFFF&}  %s  %s\\N", i, label, tag))

        local idx = i
        mp.add_forced_key_binding(tostring(idx), "minerator-choice-" .. idx, function()
            M.close_menu()
            if on_select then on_select(candidates[idx]) end
        end)
    end

    table.insert(lines, string.format("{\\1c%s}───────────────────────────────────────────────{\\1c&HFFFFFF&}\\N", border))
    table.insert(lines, string.format("  Pressione {\\1c&H7FFF00&}[1-%d]{\\1c&HFFFFFF&} para escolher | {\\1c%s}[ESC/Q]{\\1c&HFFFFFF&} Cancelar\\N", max_items, cancel_col))
    table.insert(lines, string.format("{\\1c%s}═══════════════════════════════════════════════{\\1c&HFFFFFF&}", border))

    local cancel_fn = function()
        M.close_menu()
        if on_cancel then on_cancel() end
    end
    mp.add_forced_key_binding("ESC", "minerator-cancel-esc", cancel_fn)
    mp.add_forced_key_binding("q", "minerator-cancel-q", cancel_fn)

    M.menu_overlay.data = table.concat(lines, "")
    M.menu_overlay:update()
end

-- Abre menu interativo para marcar palavra ou expressão como "Já Sabia" (Âmbar)
function M.open_known_menu(sentence, classifier, analyzer, manual_cache_file, on_complete)
    local exprs = analyzer and analyzer.find_expressions_in_sentence(sentence) or {}
    local all_known = {}
    for k, v in pairs(classifier.known_words or {}) do all_known[k] = v end
    for k, v in pairs(classifier.manual_known or {}) do all_known[k] = v end

    local candidates = M.extract_candidates(sentence, all_known, exprs, "known")
    if #candidates <= 1 then
        mp.osd_message("[AnkiMinerator] Todas as palavras da frase ja sao conhecidas!", 2.5)
        return
    end

    mp.set_property_bool("pause", true)
    local menu_opts = {
        title_text = "  {\\1c&H0B9EF5&}JÁ SABIA (ÂMBAR){\\1c&HFFFFFF&} — Escolha o termo que você já conhece:\\N",
        border_color = "&H0B9EF5&",
        cancel_color = "&HAFA39C&"
    }

    M.open_menu(candidates, function(selected)
        mp.set_property_bool("pause", false)
        if selected.type == "all" then
            classifier.mark_sentence_as_known(sentence)
            mp.osd_message("[AnkiMinerator] Frase inteira marcada como 'Já Sabia' (Âmbar)!", 2.5)
        else
            classifier.mark_term_as_known(selected.text)
            mp.osd_message(string.format("[AnkiMinerator] '%s' marcado como 'Já Sabia' (Âmbar)!", selected.text), 2.5)
        end
        if manual_cache_file then classifier.save_manual_cache(manual_cache_file) end
        if on_complete then on_complete() end
    end, function()
        mp.set_property_bool("pause", false)
    end, menu_opts)
end

return M
