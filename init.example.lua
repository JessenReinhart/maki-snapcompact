local ok, snapcompact = pcall(require, "snapcompact.init")
if ok and snapcompact then
  pcall(snapcompact.setup)
end