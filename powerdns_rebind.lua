-- Drop private addresses from public answers, like Unbound's private-address
private = newNMG()
private:addMasks({"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fd00::/8", "fe80::/10"})

function postresolve(dq)
  local records = dq:getRecords()
  local kept = {}
  local changed = false
  for _, r in ipairs(records) do
    if (r.type == pdns.A or r.type == pdns.AAAA) and private:match(newCA(r:getContent())) then
      changed = true
    else
      table.insert(kept, r)
    end
  end
  if changed then
    dq:setRecords(kept)
  end
  return changed
end
