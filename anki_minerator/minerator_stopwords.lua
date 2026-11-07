qua-- minerator_stopwords.lua
-- Lista de palavras de função neutras (function words) do AnkiMinerator
-- Não contam como candidatas e são exibidas com cor neutra

local M = {}

local STOPWORDS = {
    -- Articles
    ["a"] = true, ["an"] = true, ["the"] = true,

    -- Pronouns
    ["i"] = true, ["me"] = true, ["my"] = true, ["myself"] = true, ["mine"] = true,
    ["you"] = true, ["your"] = true, ["yours"] = true, ["yourself"] = true, ["yourselves"] = true,
    ["he"] = true, ["him"] = true, ["his"] = true, ["himself"] = true,
    ["she"] = true, ["her"] = true, ["hers"] = true, ["herself"] = true,
    ["it"] = true, ["its"] = true, ["itself"] = true,
    ["we"] = true, ["us"] = true, ["our"] = true, ["ours"] = true, ["ourselves"] = true,
    ["they"] = true, ["them"] = true, ["their"] = true, ["theirs"] = true, ["themselves"] = true,
    ["this"] = true, ["that"] = true, ["these"] = true, ["those"] = true,
    ["who"] = true, ["whom"] = true, ["whose"] = true, ["which"] = true,
    ["what"] = true, ["whatever"] = true, ["whoever"] = true,

    -- Prepositions & Adverbs
    ["in"] = true, ["on"] = true, ["at"] = true, ["to"] = true, ["for"] = true,
    ["with"] = true, ["by"] = true, ["about"] = true, ["against"] = true,
    ["between"] = true, ["into"] = true, ["through"] = true, ["during"] = true,
    ["before"] = true, ["after"] = true, ["above"] = true, ["below"] = true,
    ["from"] = true, ["up"] = true, ["down"] = true, ["of"] = true, ["off"] = true,
    ["over"] = true, ["under"] = true, ["again"] = true, ["further"] = true,
    ["then"] = true, ["once"] = true, ["here"] = true, ["there"] = true,
    ["where"] = true, ["why"] = true, ["how"] = true, ["all"] = true, ["any"] = true,
    ["both"] = true, ["each"] = true, ["few"] = true, ["more"] = true,
    ["most"] = true, ["other"] = true, ["some"] = true, ["such"] = true,
    ["than"] = true, ["too"] = true, ["very"] = true,

    -- Conjunctions
    ["and"] = true, ["but"] = true, ["if"] = true, ["or"] = true, ["because"] = true,
    ["as"] = true, ["until"] = true, ["while"] = true, ["so"] = true,
    ["though"] = true, ["although"] = true, ["since"] = true, ["unless"] = true,
    ["either"] = true, ["neither"] = true, ["nor"] = true,

    -- Auxiliary & Common Verbs
    ["be"] = true, ["been"] = true, ["being"] = true, ["am"] = true,
    ["is"] = true, ["are"] = true, ["was"] = true, ["were"] = true,
    ["have"] = true, ["has"] = true, ["had"] = true, ["having"] = true,
    ["do"] = true, ["does"] = true, ["did"] = true, ["doing"] = true,
    ["will"] = true, ["would"] = true, ["shall"] = true, ["should"] = true,
    ["can"] = true, ["could"] = true, ["may"] = true, ["might"] = true, ["must"] = true,

    -- Discourse markers / interjections
    ["oh"] = true, ["uh"] = true, ["um"] = true, ["ah"] = true, ["hey"] = true,
    ["okay"] = true, ["ok"] = true, ["yeah"] = true, ["yep"] = true, ["nope"] = true,
    ["well"] = true, ["yes"] = true, ["no"] = true, ["not"] = true
}

function M.is_function_word(word)
    if not word or word == "" then
        return true
    end
    local lower = string.lower(word)
    return STOPWORDS[lower] == true
end

return M
