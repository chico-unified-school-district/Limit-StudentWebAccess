--
-- Try to only update newer entries
UPDATE DSD SET DY = @days
WHERE
ID = @id
AND DS = @pbType
AND DTS > DATEADD(day,-5,getdate());
--
