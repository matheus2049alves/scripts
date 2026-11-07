-- main.lua
-- AnkiMinerator para mpv (Windows)
-- Mineração de vocabulário com legenda colorida, seletor de termos e IA Gemini

local mp = require("mp")
local utils = require("mp.utils")
local options = require("mp.options")

local script_dir = mp.get_script_directory() or "c:/mpv/portable_config/scripts/anki_minerator"
package.path = script_dir .. "/?.lua;" .. package.path

local cleaner = require("minerator_cleaner")
local classifier = require("minerator_classifier")
local anki = require("minerator_anki")
local media = require("minerator_media")
local gemini = require("minerator_gemini")
local selector = require("minerator_selector")
local analyzer = require("minerator_analyzer")

local opts = {
    anki_url = "http://127.0.0.1:8765",
    deck_name = "CIMV",
    model_name = "Basic",
    front_field = "Front",
    back_field = "Back",
    tsv_fallback_path = "C:\\Dev\\anki-minerator\\CIMV.txt",
    cache_path = "",
    color_enabled = true,
    font_size = 28,
    audio_padding_start = 0.15,
    audio_padding_end = 0.20,
    ffmpeg_path = "",
    gemini_api_key = "",
    gemini_model = "gemini-3.5-flash-lite"
}

options.read_options(opts, "anki_minerator")

local function load_local_conf(conf_path)
    local f = io.open(conf_path, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v and not line:match("^#") then
            if v == "yes" or v == "true" then opts[k] = true
            elseif v == "no" or v == "false" then opts[k] = false
            elseif tonumber(v) then opts[k] = tonumber(v)
            else opts[k] = v end
        end
    end
    f:close()
end
load_local_conf(utils.join_path(script_dir, "anki_minerator.conf"))

anki.anki_url = opts.anki_url
media.ffmpeg_path = opts.ffmpeg_path
media.audio_padding_start = opts.audio_padding_start
media.audio_padding_end = opts.audio_padding_end
analyzer.ffmpeg_path = opts.ffmpeg_path

local default_cache = utils.join_path(script_dir, "vocab_cache.json")
local cache_file = (opts.cache_path ~= "") and opts.cache_path or default_cache
local manual_cache_file = utils.join_path(script_dir, "manual_known_cache.json")

local overlay = mp.create_osd_overlay("ass-events")
local last_cue = nil

local function init_vocabulary()
    classifier.load_manual_cache(manual_cache_file)
    local cached_words = anki.load_cache(cache_file)
    if cached_words then
        classifier.known_words = cached_words
        return
    end
    if opts.tsv_fallback_path and opts.tsv_fallback_path ~= "" then
        local tsv_words = anki.load_from_tsv(opts.tsv_fallback_path)
        if tsv_words then
            classifier.known_words = tsv_words
            anki.save_cache(cache_file, tsv_words)
        end
    end
end

local function update_sub_overlay(raw_sub)
    if not opts.color_enabled or not raw_sub or raw_sub == "" then
        overlay:remove()
        if not opts.color_enabled then mp.set_property_bool("sub-visibility", true) end
        return
    end

    local clean_text = cleaner.clean_cue_text(raw_sub)
    if clean_text == "" then overlay:remove(); return end

    local start_time = mp.get_property_number("sub-start")
    local end_time = mp.get_property_number("sub-end")
    local cur_time = mp.get_property_number("time-pos") or 0

    last_cue = {
        text = clean_text,
        start = start_time or math.max(0, cur_time - 1.5),
        finish = end_time or (cur_time + 1.5),
        time = cur_time
    }

    mp.set_property_bool("sub-visibility", false)
    overlay.data = classifier.format_ass_line(clean_text, opts.font_size)
    overlay:update()
end

-- Minera o termo escolhido para o Anki
local function mine_target(target_term)
    if not last_cue or not last_cue.text or last_cue.text == "" then
        mp.osd_message("[AnkiMinerator] Nenhuma legenda ativa para minerar", 2.5)
        return
    end
    local video_path = mp.get_property("path")
    if not video_path then
        mp.osd_message("[AnkiMinerator] Nenhum video aberto", 2.5)
        return
    end

    mp.osd_message("[AnkiMinerator] 1/3: Capturando audio e screenshot...", 1.5)
    local temp_snap, snap_filename = media.get_temp_filepath("jpg")
    media.take_screenshot(temp_snap)

    local temp_audio, audio_filename = media.get_temp_filepath("mp3")
    local audio_ok, audio_err = media.extract_audio(video_path, last_cue.start, last_cue.finish, temp_audio)
    if not audio_ok then
        os.remove(temp_snap)
        mp.osd_message("[AnkiMinerator] Erro ao extrair audio: " .. tostring(audio_err), 4)
        return
    end

    local title = mp.get_property("media-title") or "Video"
    local time_pos = mp.get_property_osd("time-pos") or "00:00"

    mp.osd_message(string.format("[AnkiMinerator] 2/3: Consultando Gemini IA para '%s'...", target_term), 10)
    local api_key = gemini.resolve_api_key(opts.gemini_api_key)
    local ai_text, ai_err, used_model = gemini.generate_card_back(target_term, last_cue.text, api_key, opts.gemini_model)

    local back_html = ai_text and gemini.format_back_html(ai_text, title, time_pos)
        or gemini.get_blank_template(target_term, last_cue.text, title, time_pos)

    anki.store_media(audio_filename, temp_audio)
    anki.store_media(snap_filename, temp_snap)

    local highlighted_sentence = selector.highlight_term(last_cue.text, target_term)
    local front_html = string.format(
        '<div style="font-size: 22px; line-height: 1.4; margin-bottom: 8px;">%s</div><br>[sound:%s]<br><img src="%s">',
        highlighted_sentence, audio_filename, snap_filename
    )

    local fields = {}
    fields[opts.front_field] = front_html
    fields[opts.back_field] = back_html

    local note_id, anki_err = anki.add_card(opts.deck_name, opts.model_name, fields, { "anki-minerator", "mpv-mining" })
    os.remove(temp_audio)
    os.remove(temp_snap)

    if not note_id then
        mp.osd_message("[AnkiMinerator] Erro Anki: " .. tostring(anki_err), 5)
        return
    end

    local norm = cleaner.normalize_word(target_term)
    if norm ~= "" then classifier.known_words[norm] = true end
    anki.save_cache(cache_file, classifier.known_words)

    if ai_text then
        mp.osd_message(string.format("[AnkiMinerator] Card #%s criado com Gemini [%s]!", tostring(note_id), target_term), 3.5)
    else
        mp.osd_message(string.format("[AnkiMinerator] Card #%s criado, MAS IA FALHOU:\n%s\n(Log: gemini_last_response.json)", tostring(note_id), tostring(ai_err)), 7)
    end
    update_sub_overlay(last_cue.text)
end

-- Abre o menu de seleção de termos ou minera direto
local function open_mining_selector()
    if not last_cue or not last_cue.text then
        mp.osd_message("[AnkiMinerator] Nenhuma legenda ativa para minerar", 2)
        return
    end

    local exprs = analyzer.find_expressions_in_sentence(last_cue.text)
    local candidates = selector.extract_candidates(last_cue.text, classifier.known_words, exprs)

    -- Se só tiver 1 termo novo além da frase completa, minera direto
    if #candidates == 2 and candidates[1].type == "word" then
        mine_target(candidates[1].text)
        return
    end

    mp.set_property_bool("pause", true)
    selector.open_menu(candidates, function(selected)
        mp.set_property_bool("pause", false)
        mine_target(selected.text)
    end, function()
        mp.set_property_bool("pause", false)
    end)
end

-- Abre o menu de seleção para marcar termo como "Já Sabia" (Âmbar)
local function open_known_selector()
    if not last_cue or not last_cue.text then
        mp.osd_message("[AnkiMinerator] Nenhuma legenda ativa", 2)
        return
    end
    selector.open_known_menu(last_cue.text, classifier, analyzer, manual_cache_file, function()
        update_sub_overlay(last_cue.text)
    end)
end

-- Dispara a análise prévia de expressões da legenda do vídeo com IA
local function trigger_expression_analysis()
    local video_path = mp.get_property("path")
    if not video_path then
        mp.osd_message("[AnkiMinerator] Nenhum video aberto", 3)
        return
    end

    mp.osd_message("[AnkiMinerator] Localizando legenda do video...", 2)
    local ok, err = analyzer.analyze_video_subtitles(video_path, nil, opts.gemini_api_key, opts.gemini_model,
        function(current, total, items_found)
            mp.osd_message(string.format("[AnkiMinerator] Analisando expressoes na legenda: lote %d/%d (%d detectadas)...", current, total, items_found or 0), 15)
        end,
        function(total_found, error_count)
            if total_found > 0 then
                mp.osd_message(string.format("[AnkiMinerator] Analise concluida com sucesso!\n%d expressoes detectadas e salvas em cache.", total_found), 6)
            else
                mp.osd_message(string.format("[AnkiMinerator] Analise finalizada, mas nenhuma expressao foi encontrada.\n(Erros em lotes: %d - Veja: gemini_last_response.json)", error_count or 0), 6)
            end
            if last_cue then update_sub_overlay(last_cue.text) end
        end
    )

    if not ok then
        mp.osd_message(string.format("[AnkiMinerator] Nao foi possivel analisar:\n%s", tostring(err)), 6)
    end
end

-- Alterna a exibição da legenda colorida
local function toggle_color_overlay()
    opts.color_enabled = not opts.color_enabled
    local state = opts.color_enabled and "Ativada" or "Desativada"
    mp.osd_message("[AnkiMinerator] Legenda Colorida: " .. state, 2)
    local cur_sub = mp.get_property("sub-text")
    update_sub_overlay(cur_sub)
end

-- Sincroniza o vocabulário com o AnkiConnect
local function reload_vocabulary()
    mp.osd_message("[AnkiMinerator] Sincronizando com AnkiConnect...", 1.5)
    local words, err = anki.fetch_deck_vocabulary(opts.deck_name)
    if words then
        classifier.known_words = words
        anki.save_cache(cache_file, words)
        local count = 0; for _ in pairs(words) do count = count + 1 end
        mp.osd_message(string.format("[AnkiMinerator] Vocabulario atualizado: %d palavras!", count), 3)
    else
        init_vocabulary()
        mp.osd_message("[AnkiMinerator] Anki offline. Vocabulario recarregado do arquivo local", 3)
    end
    if last_cue then update_sub_overlay(last_cue.text) end
end

-- Eventos e inicialização
init_vocabulary()

mp.register_event("file-loaded", function()
    local video_path = mp.get_property("path")
    if video_path then
        analyzer.load_cached_expressions(video_path)
    end
end)

mp.observe_property("sub-text", "string", function(_, val)
    update_sub_overlay(val)
end)

-- Teclas de atalho
mp.add_key_binding("m", "minerator-open-menu", open_mining_selector)
mp.add_key_binding("Ctrl+m", "minerator-mine-direct", open_mining_selector)
mp.add_key_binding("Alt+a", "minerator-analyze-subtitles", trigger_expression_analysis)
mp.add_key_binding("c", "minerator-toggle-color", toggle_color_overlay)
mp.add_key_binding("Ctrl+Shift+r", "minerator-reload-vocab", reload_vocabulary)
mp.add_key_binding("Ctrl+Shift+k", "minerator-mark-known", open_known_selector)
mp.add_key_binding("Ctrl+Shift+p", "minerator-mark-postponed", function()
    if last_cue then classifier.mark_sentence_as_postponed(last_cue.text); update_sub_overlay(last_cue.text) end
end)
