-- links.lua: a printed manual or man page cannot follow a link to another
-- file in the repository, so such a link becomes its text followed by the
-- file's path in the repository, such as "the conventions (docs/Conventions.md)".
function Link(el)
  local t = el.target
  if t:match('^%a[%w+.-]*:') or t:match('^#') then
    return nil
  end
  local path = t:gsub('#.*$', ''):gsub('^%.%./', 'docs/'):gsub('^%./', 'docs/manual/')
  local out = el.content
  table.insert(out, pandoc.Space())
  table.insert(out, pandoc.Str('(' .. path .. ')'))
  return out
end
