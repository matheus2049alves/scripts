-- minerator_media.lua
-- Módulo de captura de áudio e imagem para mineração (baseado na abordagem do mpvacious)

local utils = require("mp.utils")

local M = {}

M.ffmpeg_path = ""
M.audio_padding_start = 0.15 -- 150ms antes do início da fala
M.audio_padding_end = 0.20   -- 200ms após o término da fala
M.mpv_path = "C:\\mpv\\mpv.com"

-- Detecta qual executável usar para extração de áudio
function M.get_encoder()
    -- 1. Verifica se ffmpeg_path explícito foi configurado
    if M.ffmpeg_path and M.ffmpeg_path ~= "" then
        return "ffmpeg", M.ffmpeg_path
    end

    -- 2. Tenta ffmpeg no PATH
    local check_res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = { "ffmpeg.exe", "-version" }
    })
    if check_res.status == 0 then
        return "ffmpeg", "ffmpeg.exe"
    end

    -- 3. Fallback: usa o próprio executável do mpv
    return "mpv", M.mpv_path
end

-- Gera um caminho temporário único no Windows
function M.get_temp_filepath(extension)
    local temp_dir = os.getenv("TEMP") or "C:\\Windows\\Temp"
    local timestamp = os.time()
    local random_id = math.random(1000, 9999)
    local filename = string.format("minerator_%d_%d.%s", timestamp, random_id, extension)
    local full_path = utils.join_path(temp_dir, filename)
    return full_path, filename
end

-- Captura screenshot do instante atual do vídeo (sem OSD/legendas)
function M.take_screenshot(output_path)
    if not output_path then
        output_path = M.get_temp_filepath("jpg")
    end
    -- "video" = captura apenas a imagem pura do vídeo na resolução original, sem legendas/OSD
    local success = mp.commandv("screenshot-to-file", output_path, "video")
    return success ~= false, output_path
end

-- Recorta o trecho de áudio exato da legenda
function M.extract_audio(video_path, start_time, end_time, output_path)
    if not video_path or not start_time or not end_time then
        return false, "Parametros invalidos para extracao de audio"
    end

    -- Aplica padding de segurança para não cortar início/fim de palavras
    local safe_start = math.max(0, start_time - M.audio_padding_start)
    local safe_end = end_time + M.audio_padding_end
    local duration = safe_end - safe_start
    if duration <= 0 then
        duration = 2.0
        safe_end = safe_start + duration
    end

    local encoder_type, encoder_bin = M.get_encoder()
    local cmd_args = {}

    if encoder_type == "ffmpeg" then
        cmd_args = {
            encoder_bin,
            "-y",
            "-ss", string.format("%.3f", safe_start),
            "-to", string.format("%.3f", safe_end),
            "-i", video_path,
            "-vn",
            "-ac", "2",
            "-c:a", "libmp3lame",
            "-q:a", "2",
            output_path
        }
    else
        -- Fallback: Codificação nativa via mpv
        cmd_args = {
            encoder_bin,
            video_path,
            string.format("--start=%.3f", safe_start),
            string.format("--end=%.3f", safe_end),
            "--no-video",
            "--audio-channels=stereo",
            "--o=" .. output_path
        }
    end

    local res = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = cmd_args
    })

    if res.status ~= 0 then
        local err_msg = res.stderr or res.error_string or "Erro desconhecido ao gerar audio"
        return false, err_msg
    end

    return true, output_path
end

return M
