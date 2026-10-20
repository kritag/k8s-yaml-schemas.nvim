-- List the schema files a source offers, so they can be searched in a picker.
-- Only sources hosted on raw.githubusercontent.com can be listed (via the GitHub trees API).
local curl = require("plenary.curl")
local M = {}

local cache = {}

-- Split a raw.githubusercontent.com template into repo, ref and the directory before the first {{variable}}
local function parse_github_raw(url_template)
	local owner, repo, rest = url_template:match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/(.+)$")
	if not owner then
		return nil
	end
	local ref_part, path = rest:gsub("^refs/heads/", ""):match("^([^/]+)/(.*)$")
	if not ref_part then
		return nil
	end
	local static = path:match("^(.-)%{%{") or path
	local dir = static:match("^(.*/)[^/]*$") or ""
	local raw_ref = rest:match("^(refs/heads/[^/]+)/") or ref_part
	return {
		owner = owner,
		repo = repo,
		ref = ref_part,
		dir = dir,
		raw_base = ("https://raw.githubusercontent.com/%s/%s/%s/%s"):format(owner, repo, raw_ref, dir),
	}
end

-- Returns { { path = "group/kind_v1.json", url = "https://raw…" }, … }, or nil plus a reason
M.list = function(source, headers)
	local gh = parse_github_raw(source.url_template)
	if not gh then
		return nil, "listing is only supported for GitHub (raw.githubusercontent.com) sources"
	end
	local key = source.url_template
	if cache[key] then
		return cache[key]
	end

	local tree = gh.ref .. (gh.dir ~= "" and (":" .. gh.dir:gsub("/$", "")) or "")
	local api = ("https://api.github.com/repos/%s/%s/git/trees/%s?recursive=1"):format(gh.owner, gh.repo, tree)
	headers = vim.tbl_extend("force", headers or {}, vim.env.GITHUB_TOKEN and { Authorization = "Bearer " .. vim.env.GITHUB_TOKEN } or {})
	local resp = curl.get(api, { headers = headers, timeout = 15000 })
	if not resp or resp.status ~= 200 then
		local hint = resp and resp.status == 403 and " (GitHub rate limit: set GITHUB_TOKEN)" or ""
		return nil, ("GitHub returned %s for the file listing%s"):format(resp and resp.status or "no response", hint)
	end

	local ok, data = pcall(vim.json.decode, resp.body)
	if not ok or type(data.tree) ~= "table" then
		return nil, "unexpected GitHub response"
	end
	local files = {}
	for _, e in ipairs(data.tree) do
		if e.type == "blob" and e.path:match("%.json$") then
			files[#files + 1] = { path = e.path, url = gh.raw_base .. e.path }
		end
	end
	if data.truncated then
		vim.notify("k8s-yaml-schemas: GitHub truncated the file listing, some schemas are missing", vim.log.levels.WARN)
	end
	cache[key] = files
	return files
end

-- Directory of a template before its first {{variable}}, e.g. "https://host/schemas/"
M.static_base = function(url_template)
	local static = url_template:match("^(.-)%{%{") or url_template
	return static:match("^(.*/)[^/]*$")
end

-- Entries of a web server directory listing (nginx/apache autoindex): { { name = "group/", dir = true, url = … }, … }
M.index = function(url)
	local resp = curl.get(url, { timeout = 15000 })
	if not resp or resp.status ~= 200 then
		return nil, ("HTTP %s for the directory listing"):format(resp and resp.status or "no response")
	end
	local entries = {}
	for href in resp.body:gmatch('href="([^"?#]+)"') do
		if not href:match("^/") and not href:match("^%.%./?$") and not href:match("^https?:") then
			local dir = href:sub(-1) == "/"
			if dir or href:match("%.json$") then
				entries[#entries + 1] = { name = href, dir = dir, url = url .. href }
			end
		end
	end
	if #entries == 0 then
		return nil, "no entries in the directory listing"
	end
	return entries
end

return M
