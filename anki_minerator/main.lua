-- main.lua
-- AnkiMinerator para mpv (Windows)
-- Mineração de vocabulário com legenda colorida, captura de áudio, screenshot e IA Gemini

local mp = require("mp")
local utils = require("mp.utils")
local options = require("mp.options")

-- Adiciona a pasta do script ao package.path para carregar os submódulos
local script_dir = mp.get_script_directory() or "c:/mpv/portable_config/scripts/anki_minerator"
package.path = script_dir .. "/?.lua;" .. package.path

local cleaner = require("minerator_cleaner")
local classifier = require("minerator_classifier")
local anki = require("minerator_anki")
local media = require("minerator_media")
local gemini = require("minerator_gemini")

-- Opções padrão
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

-- 1. Lê de portable_config/script-opts/anki_minerator.conf
options.read_options(opts, "anki_minerator")

-- 2. Lê de anki_minerator/anki_minerator.conf se existir localmente
local function load_local_conf(conf_path)
    local f = io.open(conf_path, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v and not line:match("^#") then
            if v == "yes" or v == "true" then
                opts[k] = true
            elseif v == "no" or v == "false" then
                opts[k] = false
            elseif tonumber(v) then
                opts[k] = tonumber(v)
            else
                opts[k] = v
            end
        end
    end
    f:close()
end
load_local_conf(utils.join_path(script_dir, "anki_minerator.conf"))

-- Configura dependências nos submódulos
anki.anki_url = opts.anki_url
media.ffmpeg_path = opts.ffmpeg_path
media.audio_padding_start = opts.audio_padding_start
media.audio_padding_end = opts.audio_padding_end

local default_cache = utils.join_path(script_dir, "vocab_cache.json")
local cache_file = (opts.cache_path ~= "") and opts.cache_path or default_cache

local overlay = mp.create_osd_overlay("ass-events")
local last_cue = nil

-- Carrega o vocabulário inicial
local function init_vocabulary()
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

-- Atualiza a legenda colorida na tela do mpv
local function update_sub_overlay(raw_sub)
    if not opts.color_enabled or not raw_sub or raw_sub == "" then
        overlay:remove()
        if not opts.color_enabled then
            mp.set_property_bool("sub-visibility", true)
        end
        return
    end

    local clean_text = cleaner.clean_cue_text(raw_sub)
    if clean_text == "" then
        overlay:remove()
        return
    end

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

-- Detecta a palavra ou expressão-alvo em foco na frase (termos em vermelho)
local function get_target_expression(sentence)
    local words = cleaner.extract_words(sentence)
    local unknown = {}
    for _, w in ipairs(words) do
        local _, status = classifier.classify_word(w)
        if status == "new" then
            table.insert(unknown, w)
        end
    end

    if #unknown > 0 then
        return unknown[1]
    end
    return sentence
end

-- Gera o verso usando a IA Gemini ou template formatado
local function generate_card_back_content(sentence, video_title, time_formatted)
    local target = get_target_expression(sentence)
    local api_key = gemini.resolve_api_key(opts.gemini_api_key)

    if api_key == "" then
        local blank = gemini.get_blank_template(target, sentence, video_title, time_formatted)
        return blank, target, false, "Chave Gemini nao encontrada no conf ou no ambiente"
    end

    mp.osd_message(string.format("[AnkiMinerator] Consultando Gemini IA para '%s'...", target), 10)
    local ai_text, err = gemini.generate_card_back(target, sentence, api_key, opts.gemini_model)

    if not ai_text then
        local blank = gemini.get_blank_template(target, sentence, video_title, time_formatted)
        return blank, target, false, tostring(err)
    end

    local html = gemini.format_back_html(ai_text, video_title, time_formatted)
    return html, target, true, "OK"
end

-- Cria o cartão no Anki com áudio, screenshot e verso gerado
local function mine_current_sentence()
    if not last_cue or not last_cue.text or last_cue.text == "" then
        mp.osd_message("[AnkiMinerator] Nenhuma legenda ativa para minerar", 2.5)
        return
    end

    local video_path = mp.get_property("path")
    if not video_path then
        mp.osd_message("[AnkiMinerator] Nenhum arquivo de video aberto", 2.5)
        return
    end

    mp.osd_message("[AnkiMinerator] 1/3: Capturando audio e screenshot...", 1.5)

    -- 1. Captura screenshot
    local temp_snap, snap_filename = media.get_temp_filepath("jpg")
    local snap_ok = media.take_screenshot(temp_snap)
    if not snap_ok then
        mp.osd_message("[AnkiMinerator] Falha ao capturar screenshot", 3)
        return
    end

    -- 2. Extrai áudio
    local temp_audio, audio_filename = media.get_temp_filepath("mp3")
    local audio_ok, audio_err = media.extract_audio(video_path, last_cue.start, last_cue.finish, temp_audio)
    if not audio_ok then
        os.remove(temp_snap)
        mp.osd_message("[AnkiMinerator] Erro ao extrair audio: " .. tostring(audio_err), 4)
        return
    end

    -- 3. Gera o verso do cartão (via Gemini ou template)
    local title = mp.get_property("media-title") or "Video"
    local time_pos = mp.get_property_osd("time-pos") or "00:00"
    local back_html, target, is_ai_ok, ai_info = generate_card_back_content(last_cue.text, title, time_pos)

    -- 4. Envia mídia para o AnkiConnect
    anki.store_media(audio_filename, temp_audio)
    anki.store_media(snap_filename, temp_snap)

    -- 5. Monta campos e adiciona nota
    local front_html = string.format(
        '<div style="font-size: 22px; line-height: 1.4; margin-bottom: 8px;">%s</div><br>[sound:%s]<br><img src="%s">',
        last_cue.text, audio_filename, snap_filename
    )

    local fields = {}
    fields[opts.front_field] = front_html
    fields[opts.back_field] = back_html

    local note_id, anki_err = anki.add_card(opts.deck_name, opts.model_name, fields, { "anki-minerator", "mpv-mining" })

    -- Limpa arquivos temporários do disco
    os.remove(temp_audio)
    os.remove(temp_snap)

    if not note_id then
        mp.osd_message("[AnkiMinerator] Erro Anki: " .. tostring(anki_err), 5)
        return
    end

    -- 6. Atualiza palavras como conhecidas em tempo real
    local words = cleaner.extract_words(last_cue.text)
    for _, w in ipairs(words) do
        classifier.known_words[w] = true
    end
    anki.save_cache(cache_file, classifier.known_words)

    -- Notificação final ao usuário com feedback detalhado
    if is_ai_ok then
        mp.osd_message(string.format("[AnkiMinerator] Card #%s criado com IA Gemini [%s]!", tostring(note_id), target), 3.5)
    else
        mp.osd_message(string.format("[AnkiMinerator] Card #%s criado, MAS IA FALHOU:\n%s\n(Log detalhado salvo em: gemini_last_response.json)", tostring(note_id), ai_info), 7)
    end

    update_sub_overlay(last_cue.text)
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
        local count = 0
        for _ in pairs(words) do count = count + 1 end
        mp.osd_message(string.format("[AnkiMinerator] Vocabulario atualizado: %d palavras!", count), 3)
    else
        init_vocabulary()
        mp.osd_message("[AnkiMinerator] Anki offline. Vocabulario recarregado do arquivo local", 3)
    end
    local cur_sub = mp.get_property("sub-text")
    update_sub_overlay(cur_sub)
end

-- Marca frase como "Já sabia" (Âmbar)
local function mark_current_known()
    if last_cue and last_cue.text then
        classifier.mark_sentence_as_known(last_cue.text)
        mp.osd_message("[AnkiMinerator] Termos marcados como 'Ja Sabia' (Ambar)", 2)
        update_sub_overlay(last_cue.text)
    end
end

-- Marca frase como "Adiado" (Cinza)
local function mark_current_postponed()
    if last_cue and last_cue.text then
        classifier.mark_sentence_as_postponed(last_cue.text)
        mp.osd_message("[AnkiMinerator] Termos marcados como 'Adiado' (Cinza)", 2)
        update_sub_overlay(last_cue.text)
    end
end

-- Inicialização e hooks do mpv
init_vocabulary()

mp.observe_property("sub-text", "string", function(_, val)
    update_sub_overlay(val)
end)

-- Teclas de atalho registradas no mpv
mp.add_key_binding("Ctrl+m", "minerator-mine-card", mine_current_sentence)
mp.add_key_binding("c", "minerator-toggle-color", toggle_color_overlay)
mp.add_key_binding("Ctrl+Shift+r", "minerator-reload-vocab", reload_vocabulary)
mp.add_key_binding("Ctrl+Shift+k", "minerator-mark-known", mark_current_known)
mp.add_key_binding("Ctrl+Shift+p", "minerator-mark-postponed", mark_current_postponed)
