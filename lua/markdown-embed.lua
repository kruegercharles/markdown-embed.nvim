vim.api.nvim_set_hl(0, "EmbedMdContent", {
    fg = "gray",
})

vim.api.nvim_set_hl(0, "EmbedMdBold", {
    fg = "gray",
    bold = true,
})

vim.api.nvim_set_hl(0, "EmbedMdItalic", {
    fg = "gray",
    italic = true,
})

vim.api.nvim_set_hl(0, "EmbedMdBoldItalic", {
    fg = "gray",
    bold = true,
    italic = true,
})

---@class MarkdownEmbedMappings
---@field add_embed string?
---@field open_embed string?

---@class MarkdownEmbedConfig
---@field base_path string?
---@field mappings MarkdownEmbedMappings

---@type MarkdownEmbedConfig
local config = {
    base_path = nil,
    mappings = {
        add_embed = "<Leader>ae",
        open_embed = "<Leader>oe",
    },
}

---Parses a line to extract the path and an optional heading.
---@param line string
---@return string? path
---@return string? heading
local function get_path_from_line(line)
    local full_link = line:match("!%b[]%b()")
    if not full_link then
        return nil, nil
    end

    local bracket_part = full_link:match("!%b[]")
    local link = full_link:sub(#bracket_part + 2, -2)

    -- Separate path and heading
    local path, heading = link:match("([^#]+)#?(.*)")
    if not path then
        path = link
    end

    -- Only process files that end with .md
    if not path:match("%.md$") then
        return nil, nil
    end

    if heading == "" then
        heading = nil
    end

    -- Decode URL-encoded spaces
    path = path:gsub("%%20", " ")
    if heading then
        heading = heading:gsub("%%20", " ")
    end

    return path, heading
end

---Reads the content of a file given a path, optionally starting from a specific heading.
---@param path string
---@param heading string?
---@return string[]? content
---@return string? error
local function read_file_content(path, heading)
    -- Just search in the current working directory first
    local file = io.open(path, "r")

    -- Search from current buffer's directory
    if not file then
        local current_file_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":h")
        local relative_path = current_file_dir .. "/" .. path
        file = io.open(relative_path, "r")
    end

    -- Try with base_path if it's configured
    if not file and config.base_path then
        local full_path = vim.fn.findfile(path, config.base_path .. ";")
        file = io.open(full_path, "r")
    end

    if not file then
        return nil, "Error: Could not read file " .. path
    end

    local file_lines = {}
    for file_line in file:lines() do
        table.insert(file_lines, file_line)
    end
    file:close()

    local content_to_embed = {}
    -- If no heading is specified, embed the entire file
    if not heading then
        content_to_embed = file_lines
    else
        -- Heading is specified, extract the section
        local in_section = false
        local heading_level = nil

        for _, file_line in ipairs(file_lines) do
            -- Not exactly sure why, but I have to include the following normalization to match headings correctly
            local normalized_line = string.gsub(file_line, "\194\160", " ")
            local normalized_heading = string.gsub(heading, "\194\160", " ")

            -- Ignore ":" in lines, because that is how Obsidian handles it
            normalized_line = string.gsub(normalized_line, ":", "")
            normalized_heading = string.gsub(normalized_heading, ":", "")

            local found = string.find(normalized_line, normalized_heading, 1, true)
            local isHeading = vim.fn.count(file_line, "# ") > 0

            -- Add the heading itself
            if found and found > 0 and isHeading then
                heading_level = vim.fn.count(file_line, "#")
                in_section = true
                goto continue
            end

            -- Add every other line within the section
            if in_section then
                local current_level = 0
                if isHeading then
                    current_level = vim.fn.count(file_line, "#")
                end
                if current_level > 0 and current_level <= heading_level then
                    -- Stop if a heading of same or higher level is found
                    break
                else
                    table.insert(content_to_embed, file_line)
                end
            end
            ::continue::
        end

        if not in_section then
            return nil, "Error: Heading not found: " .. heading
        end
    end

    -- Remove trailing empty lines from the final content
    while #content_to_embed > 0 and content_to_embed[#content_to_embed]:match("^%s*$") do
        table.remove(content_to_embed)
    end

    return content_to_embed, nil
end

---Removes markdown formatting characters from text
---@param text string
---@return string
local function strip_markdown(text)
    -- Remove bold and italic markers
    text = text:gsub("%*%*(.-)%*%*", "%1")
    text = text:gsub("%*([^*].-[^*])%*", "%1")
    return text
end

---Wraps a single line of text to a given width (without markdown characters).
---@param text string
---@param width number
---@return string[]
local function wrap_text(text, width)
    if not text or #text == 0 then
        return { "" }
    end
    if width <= 0 then
        return { text }
    end

    local lines = {}
    local current_pos = 1
    while current_pos <= #text do
        -- Find the end of the chunk that fits within the width
        local end_pos = current_pos + width - 1
        if end_pos > #text then
            end_pos = #text
        end

        -- Adjust end_pos to avoid splitting multi-byte characters
        while end_pos < #text and text:byte(end_pos + 1) >= 0x80 and text:byte(end_pos + 1) < 0xc0 do
            end_pos = end_pos - 1
        end

        local sub = text:sub(current_pos, end_pos)
        -- Recalculate width for the substring and adjust if necessary
        while vim.fn.strdisplaywidth(sub) > width do
            end_pos = end_pos - 1
            -- Adjust again for multi-byte characters
            while text:byte(end_pos + 1) >= 0x80 and text:byte(end_pos + 1) < 0xc0 do
                end_pos = end_pos - 1
            end
            sub = text:sub(current_pos, end_pos)
        end

        table.insert(lines, sub)
        current_pos = end_pos + 1
    end
    return lines
end

---Parses a line for bold and italic markdown and returns chunks for virtual text.
---@param line string
---@param default_hl string
---@param bold_hl string
---@param italic_hl string
---@return table[] chunks Chunks in the format {text, highlight_group}
local function parse_line_for_highlights(line, default_hl, bold_hl, italic_hl)
    -- Check for headings first
    local heading_level, heading_text = line:match("^(#+)%s+(.*)")
    if heading_level and heading_text then
        -- It's a heading. The entire line should be bold.
        -- We parse the rest of the line for other highlights, but make them bold as well.
        local bold_italic_hl = "EmbedMdBoldItalic"
        return parse_line_for_highlights(heading_text, bold_hl, bold_hl, bold_italic_hl)
    end

    local chunks = {}
    local current_pos = 1
    while current_pos <= #line do
        -- Find the next bold or italic marker, whichever comes first
        local bold_s, _, bold_content = line:find("%*%*(.-)%*%*", current_pos)
        local italic_s, _, italic_content = line:find("%*([^*].-[^*])%*", current_pos)

        -- Determine which marker to process next
        local s, e, content, hl
        if bold_s and (not italic_s or bold_s < italic_s) then
            s, e, content = line:find("%*%*(.-)%*%*", current_pos)
            hl = bold_hl
        elseif italic_s then
            s, e, content = line:find("%*([^*].-[^*])%*", current_pos)
            hl = italic_hl
        else
            -- No more markers found, add the rest of the line
            local remaining = line:sub(current_pos)
            if #remaining > 0 then
                table.insert(chunks, { remaining, default_hl })
            end
            break
        end

        -- Add the part before the marker
        local prefix = line:sub(current_pos, s - 1)
        if #prefix > 0 then
            table.insert(chunks, { prefix, default_hl })
        end

        -- Add the highlighted content
        table.insert(chunks, { content, hl })

        -- Update current position to continue searching after the marker
        current_pos = e + 1
    end

    -- If the line was empty or had no content, return a single empty chunk
    if #chunks == 0 then
        return { { "", default_hl } }
    end

    return chunks
end

---Creates the virtual lines for the extmark with a border.
---@param content string[]?
---@param indent string
---@param highlight_group string
---@return table[][] virtual_lines
local function create_virtual_lines(content, indent, highlight_group)
    if not content or #content == 0 then
        return {
            { { indent .. "┌" .. string.rep("─", 2) .. "┐", highlight_group } },
            { { indent .. "│" .. string.rep(" ", 2) .. "│", highlight_group } },
            { { indent .. "└" .. string.rep("─", 2) .. "┘", highlight_group } },
        }
    end

    local window_width = vim.api.nvim_win_get_width(0)
    local max_embed_width = math.floor(window_width * 0.8)

    -- Calculate max width based on stripped markdown
    local max_line_width = 0
    for _, line in ipairs(content) do
        local stripped = strip_markdown(line)
        if vim.fn.strdisplaywidth(stripped) > max_line_width then
            max_line_width = vim.fn.strdisplaywidth(stripped)
        end
    end

    local display_width = math.min(max_line_width, max_embed_width)

    -- Process lines: parse highlights first, then wrap if needed
    local processed_lines = {}
    for _, line in ipairs(content) do
        local stripped = strip_markdown(line)
        local line_width = vim.fn.strdisplaywidth(stripped)

        if line_width > display_width then
            -- Need to wrap this line
            local wrapped_lines = wrap_text(stripped, display_width)
            for _, wrapped_line in ipairs(wrapped_lines) do
                table.insert(processed_lines, wrapped_line)
            end
        else
            -- Line fits, keep original for markdown parsing
            table.insert(processed_lines, line)
        end
    end

    local virtual_lines = {}
    -- Top border
    table.insert(
        virtual_lines,
        { { indent .. "┌" .. string.rep("─", display_width + 2) .. "┐", highlight_group } }
    )

    -- Content lines with side borders
    for _, line in ipairs(processed_lines) do
        local line_chunks = parse_line_for_highlights(line, highlight_group, "EmbedMdBold", "EmbedMdItalic")

        -- Calculate actual display width after stripping markdown
        local actual_width = 0
        for _, chunk in ipairs(line_chunks) do
            actual_width = actual_width + vim.fn.strdisplaywidth(chunk[1])
        end

        local padding = string.rep(" ", display_width - actual_width)

        -- Prepend the border and indent to the first chunk
        line_chunks[1][1] = indent .. "│ " .. line_chunks[1][1]
        -- Append the padding and border to the last chunk
        line_chunks[#line_chunks][1] = line_chunks[#line_chunks][1] .. padding .. " │"

        table.insert(virtual_lines, line_chunks)
    end

    -- Bottom border
    table.insert(
        virtual_lines,
        { { indent .. "└" .. string.rep("─", display_width + 2) .. "┘", highlight_group } }
    )

    return virtual_lines
end

---Main function to update embedded Markdown content
local function update_embeds()
    -- Create a namespace for our extmarks
    local ns = vim.api.nvim_create_namespace("markdown-embed")

    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local indent = "  "

    for i, line in ipairs(lines) do
        local path, heading = get_path_from_line(line)
        if path then
            local content, err = read_file_content(path, heading)
            local embedded_lines
            if err then
                embedded_lines = create_virtual_lines({ err }, indent, "Error")
            else
                if heading and content then
                    -- Prepend the heading to the content to be displayed
                    table.insert(content, 1, "# " .. heading)
                end
                embedded_lines = create_virtual_lines(content, indent, "EmbedMdContent")
            end
            -- Add empty virtual line above the content
            table.insert(embedded_lines, 1, { { "" } })
            -- Add empty virtual line below the content
            table.insert(embedded_lines, { { "" } })

            vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, {
                virt_lines = embedded_lines,
            })
        end
    end
end

---@param str string?
---@return string?
local function urlencode(str)
    if not str then
        return nil
    end
    str = str:gsub(" ", "%%20")
    return str
end

---@param str string?
---@return string?
local function urldecode(str)
    if not str then
        return nil
    end
    str = str:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return str
end

---Opens an embedded file and optionally jumps to a heading.
local function open_embedded_file()
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local line_content = vim.api.nvim_buf_get_lines(bufnr, cursor_line - 1, cursor_line, false)[1]

    local path, heading = get_path_from_line(line_content)

    if not path then
        vim.notify("No embed link found on the current line.", vim.log.levels.WARN)
        return
    end

    -- Resolve the file path
    local resolved_path = nil
    -- 1. Try current directory
    if vim.fn.filereadable(path) == 1 then
        resolved_path = path
    else
        -- 2. Try path relative to current buffer's directory
        local current_file_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":h")
        local relative_path = current_file_dir .. "/" .. path
        if vim.fn.filereadable(relative_path) == 1 then
            resolved_path = relative_path
        else
            -- 3. Try with base_path if configured
            if config.base_path then
                local full_path = vim.fn.findfile(path, config.base_path .. ";")
                if full_path ~= "" then
                    resolved_path = full_path
                end
            end
        end
    end

    if not resolved_path then
        vim.notify("Embedded file not found: " .. path, vim.log.levels.ERROR)
        return
    end

    -- Open the file in a new buffer
    vim.cmd("edit " .. resolved_path)

    if heading then
        -- Schedule a search for the heading after the file is opened
        vim.schedule(function()
            local decoded_heading = urldecode(heading)
            -- Escape special characters in heading for search pattern
            local escaped_heading = vim.fn.escape(decoded_heading, [[\/.*^$[]])
            -- Search for the heading (case-insensitive)
            vim.cmd("/^#\\+.*" .. escaped_heading .. "/i")
            -- Move cursor to the beginning of the line
            vim.cmd("normal! ^")
        end)
    end
end

---Picks a file and optionally a heading to embed.
local function pick_file_and_heading()
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local function show_heading_picker(prompt_bufnr)
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        local file_path = selection.path

        -- Read the selected file
        local file = io.open(file_path, "r")
        if not file then
            vim.notify("Error: Could not read file " .. file_path, vim.log.levels.ERROR)
            return
        end

        local lines = {}
        for line in file:lines() do
            table.insert(lines, line)
        end
        file:close()

        -- Extract headings
        local headings = {}
        for _, line in ipairs(lines) do
            if line:match("^#") then
                table.insert(headings, line)
            end
        end

        -- Show heading picker
        require("telescope.pickers")
            .new({}, {
                prompt_title = "Select a Heading",
                finder = require("telescope.finders").new_table({
                    results = headings,
                    entry_maker = function(entry)
                        return {
                            value = entry,
                            display = entry,
                            ordinal = entry,
                        }
                    end,
                }),
                sorter = require("telescope.sorters").get_generic_fuzzy_sorter(),
                attach_mappings = function(prompt_bufnr, _)
                    actions.select_default:replace(function()
                        actions.close(prompt_bufnr)
                        local selection = action_state.get_selected_entry()
                        local heading_text = selection.value:match("^#+ (.*)")
                        local relative_path = vim.fn.fnamemodify(file_path, ":.")
                        local embed_link = string.format(
                            "![%s](%s#%s)",
                            heading_text,
                            urlencode(relative_path),
                            urlencode(heading_text)
                        )
                        vim.api.nvim_put({ embed_link }, "c", true, true)
                        update_embeds()
                    end)
                    return true
                end,
            })
            :find()
    end

    local find_files_opts = {
        attach_mappings = function(prompt_bufnr, map)
            -- Map '#' to open heading picker
            map("i", "#", function()
                show_heading_picker(prompt_bufnr)
            end)

            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                local file_path = selection.path
                local relative_path = vim.fn.fnamemodify(file_path, ":.")
                local file_name = vim.fn.fnamemodify(file_path, ":t:r")
                local embed_link = string.format("![%s](%s)", file_name, urlencode(relative_path))
                vim.api.nvim_put({ embed_link }, "c", true, true)
                update_embeds()
            end)
            return true
        end,
    }

    require("telescope.builtin").find_files(find_files_opts)
end

---@param opts MarkdownEmbedConfig?
local function setup(opts)
    config = vim.tbl_deep_extend("force", config, opts or {})

    -- Create a user command to trigger the update manually
    vim.api.nvim_create_user_command("UpdateEmbeds", update_embeds, {})
    vim.api.nvim_create_user_command("MarkdownAddEmbed", pick_file_and_heading, {})
    vim.api.nvim_create_user_command("MarkdownOpenEmbed", open_embedded_file, {})

    if config.mappings.add_embed then
        vim.keymap.set("n", config.mappings.add_embed, pick_file_and_heading, {
            desc = "Add embed",
        })
    end

    if config.mappings.open_embed then
        vim.keymap.set("n", config.mappings.open_embed, open_embedded_file, {
            desc = "Open embedded file",
        })
    end

    -- Create an augroup for managing autocommands
    local augroup = vim.api.nvim_create_augroup("EmbedMd", {
        clear = true,
    })

    -- Set up autocommand to run update_embeds on file open and write for .md files
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
        group = augroup,
        pattern = "*.md",
        callback = update_embeds,
    })

    -- Set up autocommand to run update_embeds on window resize
    vim.api.nvim_create_autocmd("VimResized", {
        group = augroup,
        callback = update_embeds,
    })
end

return {
    setup = setup,
    update_embeds = update_embeds,
    open_embedded_file = open_embedded_file,
    add_embed = pick_file_and_heading,
    open_embed = open_embedded_file,
}
